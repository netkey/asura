-- demo_concurrent.lua  AI 对战模拟 harness（平衡回测 + 回归门禁）
--
-- AI 只产出客户端消息（op 3/4/5/6），全部经 handler.match_loop 处理，与生产同一条路径：
-- 挂起续接（弃牌/回合结束技能）、deadline 超时、托管都按真实逻辑运行。
-- AI 只读：自己的手牌/身份 + rules.spectator_view 的公开视图 + 公开伤害事件（op 20），不偷看隐藏身份。
-- 每局独立播种、串行执行，同 seed 结果逐字节一致（digest 可比对）。
--
-- Run:
--   lua5.4 demo_concurrent.lua                         -- 默认 200 局（PVP/身份局交替），CI 门禁
--   lua5.4 demo_concurrent.lua --games 1000            -- 平衡回测
--   lua5.4 demo_concurrent.lua --seed 1000 --game 37 -v  -- 单独复现第 37 局
-- Options: --games N  --seed S  --mode mix|pvp|identity  --game I  --max-unfinished R  -v

--------------------------------------------------------------------------------
-- Args
--------------------------------------------------------------------------------
local OPT = { games = 200, seed = 1000, mode = "mix", game = nil, max_unfinished = 0.05, verbose = false }
do
    local i = 1
    while arg and arg[i] do
        local a = arg[i]
        if a == "-v" then OPT.verbose = true
        elseif a == "--games" then i = i + 1; OPT.games = tonumber(arg[i])
        elseif a == "--seed" then i = i + 1; OPT.seed = tonumber(arg[i])
        elseif a == "--mode" then i = i + 1; OPT.mode = arg[i]
        elseif a == "--game" then i = i + 1; OPT.game = tonumber(arg[i])
        elseif a == "--max-unfinished" then i = i + 1; OPT.max_unfinished = tonumber(arg[i])
        else error("unknown option: " .. a) end
        i = i + 1
    end
end

--------------------------------------------------------------------------------
-- Mock Nakama（虚拟时钟：每 tick +1s，让 deadline/超时按生产逻辑触发且可复现）
--------------------------------------------------------------------------------
local CLOCK = 1000000
os.time = function() return CLOCK end

local nk = setmetatable({
    json_encode  = function(t) return t end,
    json_decode  = function(s) return type(s) == "table" and s or {} end,
    storage_read = function(reads)
        if reads and reads[1] and reads[1].collection == "season_config" then
            return {{ value = { season_id = "s1", leaderboard_id = "lb1" } }}
        end
        return {}
    end,
    storage_list             = function() return {} end,
    match_list               = function() return {} end,
    leaderboard_records_list = function() return {}, nil, nil end,
    account_get_id           = function() return { wallet = { gold = 500 } } end,
}, { __index = function() return function() end end })
package.loaded["nakama"] = nk

-- PUC Lua 5.4 每进程随机化字符串哈希种子，规则代码里的 pairs(state.players) 顺序随之漂移，
-- 同 seed 两次运行结果不同（发牌顺序、结算顺序）。harness 只要求可复现，不复现生产 VM 的遍历顺序，
-- 所以统一按 key 排序遍历。
do
    local raw_next = next
    local function key_lt(a, b)
        local ta, tb = type(a), type(b)
        if ta ~= tb then return ta < tb end
        if ta == "number" or ta == "string" then return a < b end
        return tostring(a) < tostring(b)
    end
    pairs = function(t)  -- luacheck: ignore 121 (刻意覆盖，见上方注释)
        local mt = getmetatable(t)
        if mt and mt.__pairs then return mt.__pairs(t) end
        local keys = {}
        for k in raw_next, t do keys[#keys + 1] = k end
        table.sort(keys, key_lt)
        local i = 0
        return function()
            i = i + 1
            local k = keys[i]
            if k ~= nil then return k, t[k] end
        end, t, nil
    end
end

local root = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
package.path = root .. "/?.lua;" .. package.path

local handler = require("match_handler")
local rules   = require("game_rules")
local catalog = require("hero_catalog")
local hero_mgr = require("hero_manager")

local STATUS_PLAYING, STATUS_HERO_SELECT = 1, 3
local MAX_TURNS = 300        -- 超过视为未分胜负（5 人局 = 60 轮）
local MAX_TICKS = 40000
local MAX_PLAYS_PER_TURN = 40
local IGNORED_AFTER = 3      -- 同一 pending 连续响应 N 次无变化 → 记为服务端忽略响应，改等 deadline

--------------------------------------------------------------------------------
-- 卡牌估值
--------------------------------------------------------------------------------
local VALUE = {
    HEAL = 10, DEFENSE = 9, ATTACK = 8, WINE = 7,
    INSTANT_TRICK = 6, WEAPON = 4, ARMOR = 4, HORSE = 4, DELAYED_TRICK = 3,
}
local function by_value_desc(cards)
    local t = {}
    for _, c in ipairs(cards) do t[#t + 1] = c end
    table.sort(t, function(a, b)
        local va, vb = VALUE[a.type] or 0, VALUE[b.type] or 0
        if va ~= vb then return va > vb end
        return a.id < b.id
    end)
    return t
end
local function find_card(hand, pred)
    for _, c in ipairs(hand) do if pred(c) then return c end end
end

--------------------------------------------------------------------------------
-- 公开信息：伤害记录 + 目标选择（只用 spectator_view 的公开视图）
--------------------------------------------------------------------------------
local function dmg(g, a, b) return (g.hostility[a] and g.hostility[a][b]) or 0 end

local function public_view(state, uid)
    return rules.spectator_view(state, uid).others
end

-- 对主公的敌意：打主公加分，打"打过主公的人"减分
local function suspicion(g, state, monarch_id, x)
    local s = dmg(g, x, monarch_id)
    for _, y in ipairs(state.presence_ids) do
        if y ~= x and y ~= monarch_id and dmg(g, y, monarch_id) > 0 then
            s = s - 0.5 * dmg(g, x, y)
        end
    end
    return s
end

-- 返回按优先级排序的敌方候选（只含存活者）
local function enemy_candidates(g, state, uid)
    local me = state.players[uid]
    local others = public_view(state, uid)
    local alive, rebels_dead = {}, 0
    for _, o in ipairs(others) do
        if o.hp > 0 then alive[#alive + 1] = o
        elseif o.role == "REBEL" then rebels_dead = rebels_dead + 1 end  -- 死者身份公开
    end
    table.sort(alive, function(a, b) return (a.seat_idx or 0) < (b.seat_idx or 0) end)

    if state.mode == "pvp" then return alive end

    local monarch_id
    for _, o in ipairs(alive) do if o.role == "MONARCH" then monarch_id = o.id end end

    if me.role == "REBEL" then
        local list = {}
        if monarch_id then list[1] = state.players[monarch_id] and { id = monarch_id } end
        -- 其次打对自己下过手的人
        local rest = {}
        for _, o in ipairs(alive) do
            if o.id ~= monarch_id and dmg(g, o.id, uid) > 0 then rest[#rest + 1] = o end
        end
        table.sort(rest, function(a, b) return dmg(g, a.id, uid) > dmg(g, b.id, uid) end)
        for _, o in ipairs(rest) do list[#list + 1] = o end
        return list
    end

    -- 内奸：反贼全灭后转为清场，先忠臣后主公
    if me.role == "TRAITOR" and rebels_dead >= 2 then
        local list = {}
        for _, o in ipairs(alive) do if o.id ~= monarch_id then list[#list + 1] = o end end
        if monarch_id then list[#list + 1] = { id = monarch_id } end
        return list
    end

    -- 主公 / 忠臣 / 前期内奸：打嫌疑最高的人
    local mid = me.role == "MONARCH" and uid or monarch_id
    local list = {}
    for _, o in ipairs(alive) do
        if o.id ~= mid and suspicion(g, state, mid, o.id) > 0 then list[#list + 1] = o end
    end
    table.sort(list, function(a, b)
        local sa, sb = suspicion(g, state, mid, a.id), suspicion(g, state, mid, b.id)
        if sa ~= sb then return sa > sb end
        return (a.seat_idx or 0) < (b.seat_idx or 0)
    end)
    -- 对局未结束且只剩一个非主公者 → 他必然是敌人
    if #list == 0 then
        local rest = {}
        for _, o in ipairs(alive) do if o.id ~= mid then rest[#rest + 1] = o end end
        if #rest == 1 and (me.role == "MONARCH" or #alive == 2) then list[1] = rest[1] end
    end
    return list
end

local function first_target(cands, pred)
    for _, o in ipairs(cands) do if not pred or pred(o.id) then return o.id end end
end

-- 救人：救自己；主公阵营（含内奸，内奸需要主公活到最后）救主公
local function wants_rescue(state, rescuer_id, dying_id)
    if rescuer_id == dying_id then return true end
    if state.mode == "pvp" then return false end
    local role = state.players[rescuer_id].role
    return dying_id == state.monarch_id and (role == "MINISTER" or role == "TRAITOR")
end

--------------------------------------------------------------------------------
-- AI：出牌阶段（返回 op 3 payload，nil = 结束回合）
--------------------------------------------------------------------------------
local function ai_play(g, state, uid, blocked)
    local p = state.players[uid]
    local function usable(c) return not blocked[c.id] and not blocked[c.type] end
    local cands = enemy_candidates(g, state, uid)
    local reach = first_target(cands, function(t) return rules.can_attack(state, uid, t) end)
    local foe = first_target(cands)

    local equip = find_card(p.hand, function(c)
        if not usable(c) then return false end
        if c.type == "WEAPON" then return not p.equipment.weapon end
        if c.type == "ARMOR" then return not p.equipment.armor end
        if c.type == "HORSE" then return not p.equipment.horse end
        return false
    end)
    if equip then return { card_id = equip.id } end

    if p.health < p.max_health then
        local heal = find_card(p.hand, function(c) return usable(c) and c.type == "HEAL" end)
        if heal then return { card_id = heal.id } end
    end

    local draw = find_card(p.hand, function(c)
        return usable(c) and c.type == "INSTANT_TRICK" and (c.subtype == "draw_two" or c.subtype == "mass_draw")
    end)
    if draw then return { card_id = draw.id } end

    if reach then
        local atk = find_card(p.hand, function(c) return usable(c) and c.type == "ATTACK" end)
        if atk then
            local wine = not p.wine_used_this_turn
                and find_card(p.hand, function(c) return usable(c) and c.type == "WINE" end)
            if wine then return { card_id = wine.id } end
            return { card_id = atk.id, target_id = reach }
        end
    end

    if foe then
        local trick = find_card(p.hand, function(c)
            return usable(c) and c.type == "INSTANT_TRICK" and (c.subtype == "duel"
                or c.subtype == "discard_one" or c.subtype == "steal_one" or c.subtype == "fire_attack")
        end)
        if trick then return { card_id = trick.id, target_id = foe } end
        local skip = find_card(p.hand, function(c) return usable(c) and c.subtype == "skip_play" end)
        if skip then return { card_id = skip.id, target_id = foe } end
    end

    -- 群体锦囊只在有明确敌人时打（避免主公阵营无差别伤害）
    if foe then
        local aoe = find_card(p.hand, function(c)
            return usable(c) and c.type == "INSTANT_TRICK" and (c.subtype == "aoe_attack" or c.subtype == "aoe_defense")
        end)
        if aoe then return { card_id = aoe.id } end
    end

    if p.health < p.max_health then
        local mh = find_card(p.hand, function(c) return usable(c) and c.subtype == "mass_heal" end)
        if mh then return { card_id = mh.id } end
    end

    local lightning = find_card(p.hand, function(c) return usable(c) and c.subtype == "lightning" end)
    if lightning then return { card_id = lightning.id, target_id = uid } end

    return nil
end

--------------------------------------------------------------------------------
-- AI：响应 pending_action（返回 {uid, payload} 列表；空表 = 无人可响应，等服务端 deadline）
--------------------------------------------------------------------------------
local function respond_cards(p, ctype)
    local c = find_card(p.hand, function(x) return x.type == ctype end)
    return { confirm = c ~= nil, card_id = c and c.id or nil }
end

local function ai_pending(g, state)
    local a = state.pending_action
    local t = a.type
    local P = state.players
    local function one(uid, payload) return { { uid = uid, payload = payload } } end

    if t == "WAITING_FOR_DEFENSE" then
        return one(a.target_id, respond_cards(P[a.target_id], "DEFENSE"))
    elseif t == "WAITING_FOR_AOE" then
        return one(a.current_target, respond_cards(P[a.current_target], a.required_response or "DEFENSE"))
    elseif t == "WAITING_FOR_DUEL" then
        local cur = a.is_attackers_turn and a.attacker_id or a.target_id
        return one(cur, respond_cards(P[cur], "ATTACK"))
    elseif t == "WAITING_FOR_TRICK_SELECT" then
        return one(a.source_id, { confirm = false })
    elseif t == "WAITING_FOR_RESCUE" then
        local rid = a.rescuers and a.rescuers[a.current_rescuer_idx]
        local r = rid and P[rid]
        if not r then return {} end
        -- 与 rules.handle_response 同口径：只有【桃】或英雄技能允许的牌能救人（酒不能）
        local c = wants_rescue(state, rid, a.dying_player_id) and find_card(r.hand, function(x)
            return x.type == "HEAL" or hero_mgr.can_rescue_with(r.hero, x)
        end)
        return one(rid, { confirm = c and true or false, card_id = c and c.id or nil })
    elseif t == "WAITING_FOR_COUNTER" then
        local list = {}
        for _, uid in ipairs(a.remaining_order or {}) do
            if not (a.responded or {})[uid] then list[#list + 1] = { uid = uid, payload = { confirm = false, round = a.round } } end
        end
        return list
    elseif t == "WAITING_FOR_BORROW_WEAPON" then
        return one(a.target_id, { confirm = false })
    elseif t == "WAITING_FOR_FIRE_GUESS" then
        local suits = { "HEART", "SPADE", "CLUB", "DIAMOND" }
        return one(a.caster_id, { confirm = true, guess = suits[math.random(#suits)] })
    elseif t == "WAITING_FOR_DISCARD" then
        local sorted = by_value_desc(P[a.player_id].hand)
        local ids = {}
        for i = #sorted, math.max(1, #sorted - a.discard_count + 1), -1 do ids[#ids + 1] = sorted[i].id end
        return one(a.player_id, { confirm = true, card_ids = ids })
    elseif t == "WEAPON_QINGLONG_DAO" then
        return one(a.player_id, respond_cards(P[a.player_id], "ATTACK"))
    elseif t == "WEAPON_CHUANGSHI_FU" then
        return one(a.player_id, { confirm = false })
    end

    -- 英雄技能（pending.player_id 为被询问者）
    local uid = a.player_id
    local p = uid and P[uid]
    if not p then
        g.unknown[t] = (g.unknown[t] or 0) + 1
        return {}
    end
    local function ids_of(cards, n)
        local out = {}
        for i = 1, math.min(n or #cards, #cards) do out[i] = cards[i].id end
        return out
    end

    if t == "ALIBABA_COUNTER" or t == "RUMI_XUANHUI" or t == "ENHEDUANNA_SONG_CI" then
        return one(uid, { confirm = true })
    elseif t == "HAKIM_XING_XIANG" then
        if not (a.cards and #a.cards > 0) then return one(uid, { confirm = false }) end
        return one(uid, { confirm = true, sorted_ids = ids_of(by_value_desc(a.cards)) })
    elseif t == "AL_KHWARIZMI_SUANFA" then
        if not (a.cards and #a.cards > 0) then return one(uid, { confirm = false }) end
        local s = by_value_desc(a.cards)
        return one(uid, { confirm = true, sorted_ids = ids_of(s), keep_ids = ids_of(s, 2) })
    elseif t == "AL_BIRUNI_CELIANG" then
        if not (a.cards and #a.cards > 0) then return one(uid, { confirm = false }) end
        return one(uid, { confirm = true, keep_ids = ids_of(by_value_desc(a.cards), 2) })
    elseif t == "SCHEHERAZADE_QIANYE" then
        if #p.hand == 0 or not (a.shown_cards and #a.shown_cards > 0) then return one(uid, { confirm = false }) end
        local s = by_value_desc(p.hand)
        return one(uid, { confirm = true, own_card_id = s[#s].id, target_card_id = a.shown_cards[1].id })
    elseif t == "HARUN_CHOOSE" then
        return one(uid, { confirm = true, choose_discard = false })
    elseif t == "IBN_BATTUTA_YUAN_XING" then
        if #p.hand == 0 then return one(uid, { confirm = false }) end
        local s = by_value_desc(p.hand)
        return one(uid, { confirm = true, card_ids = { s[#s].id } })
    elseif t == "GILGAMESH_BU_XIU" then
        if not (a.cards and #a.cards > 0) then return one(uid, { confirm = false }) end
        return one(uid, { confirm = true, card_id = a.cards[1].id })
    elseif t == "AVICENNA_ZHEN" then
        if not (a.heart_cards and #a.heart_cards > 0) then return one(uid, { confirm = false }) end
        return one(uid, { confirm = true, card_id = a.heart_cards[1].id })
    elseif t == "SULEIMAN_CHI_LING" or t == "HARUN_SELECT_TARGET" then
        local cands = enemy_candidates(g, state, uid)
        local legal = {}
        for _, x in ipairs(a.targets or {}) do legal[x.id] = true end
        local tid = first_target(cands, function(id) return legal[id] end)
        if not tid then return one(uid, { confirm = false }) end
        local payload = { confirm = true, target_id = tid }
        if t == "SULEIMAN_CHI_LING" then payload.block_type = "ATTACK" end
        return one(uid, payload)
    elseif t == "ENHEDUANNA_SONG_CI_GIVE" then
        if a.hand_cards and #a.hand_cards > 0 and a.targets and #a.targets > 0 then
            return one(uid, { confirm = true, card_id = a.hand_cards[1].id, target_id = a.targets[1].id })
        end
        return one(uid, { confirm = true })
    elseif t == "DHUL_SKILL_CHOICE" then
        -- 技能要弃牌作代价，手牌少时发动会把自己耗空、拖成僵局
        if #p.hand < 3 then return one(uid, { confirm = false }) end
        local s = by_value_desc(p.hand)
        local skill = a.can_west and "westward" or (a.can_east and "eastward" or "wall")
        return one(uid, { confirm = true, card_id = s[#s].id, skill = skill })
    elseif t == "DHUL_WEST_EXTRA" or t == "DHUL_EAST_EXTRA" then
        local tid = first_target(enemy_candidates(g, state, uid))
        if not tid then return one(uid, { confirm = false }) end
        return one(uid, { confirm = true, target_id = tid })
    end

    g.unknown[t] = (g.unknown[t] or 0) + 1
    return one(uid, { confirm = false })
end

--------------------------------------------------------------------------------
-- 单局驱动
--------------------------------------------------------------------------------
local function make_dispatcher(g)
    return {
        broadcast_message = function(op, data)
            if type(data) ~= "table" then return end
            if op == 20 and data.event == "damage" and data.source and data.target then
                g.hostility[data.source] = g.hostility[data.source] or {}
                g.hostility[data.source][data.target] = (g.hostility[data.source][data.target] or 0) + (data.amount or 0)
            elseif op == 30 then
                g.winner = data.winner
            end
            if data.hero and data.skill then
                g.triggers[data.hero] = g.triggers[data.hero] or {}
                g.triggers[data.hero][data.skill] = (g.triggers[data.hero][data.skill] or 0) + 1
            end
        end,
        match_label_update = function() end,
    }
end

-- AOE/决斗/求桃在同一张表上原地推进，需按可变字段判断"是否有进展"
local function pending_sig(pa)
    local keys = {}
    for k, v in pairs(pa) do
        local tv = type(v)
        if tv == "string" or tv == "number" or tv == "boolean" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(pa[k]) end
    local responded = 0
    for _ in pairs(pa.responded or {}) do responded = responded + 1 end
    return table.concat(parts, ";") .. ";responded=" .. responded
end

local function in_hand(p, card_id)
    for _, c in ipairs(p.hand) do if c.id == card_id then return true end end
    return false
end

local function run_game(cfg)
    math.randomseed(cfg.seed)
    CLOCK = 1000000
    local g = { hostility = {}, triggers = {}, unknown = {}, ignored = {}, turns = 0, plays = 0, ticks = 0 }
    local disp = make_dispatcher(g)
    local ctx = { match_id = "sim-" .. cfg.seed }
    local state = handler.match_init(ctx, { max_players = #cfg.heroes })
    for i = 1, #cfg.heroes do
        local pr = { user_id = "u" .. i, username = "u" .. i, session_id = "s" .. i, node = "sim" }
        local ok
        state, ok = handler.match_join_attempt(ctx, disp, 0, state, pr, {})
        assert(ok, "join rejected")
        state = handler.match_join(ctx, disp, 0, state, { pr })
    end
    state._demo_mode = true
    g.state = state

    local last_turn, blocked, plays_this_turn = nil, {}, 0
    local last_pending, same_pending = nil, 0

    for tick = 1, MAX_TICKS do
        g.ticks = tick
        CLOCK = CLOCK + 1
        local msgs, played = {}, nil
        -- match_loop 在这些续接 tick 里先 return、不读消息；此时发消息会被丢弃，等续接完成再出手
        local resuming = state.pending_discard_continuation or state.pending_turn_end
            or state.pending_turn_continuation or state.pending_draw_continuation

        if state.status == STATUS_HERO_SELECT then
            for i, uid in ipairs(state.presence_ids) do
                local p = state.players[uid]
                if not p.hero and (state.hero_select_monarch_done or uid == state.monarch_id) then
                    msgs[#msgs + 1] = { op_code = 6, sender = { user_id = uid }, data = { hero_id = cfg.heroes[i] } }
                end
            end
        elseif state.status == STATUS_PLAYING then
            local pa = state.pending_action
            if pa then
                local sig = pending_sig(pa)
                if sig ~= last_pending then same_pending = 0 end
                last_pending = sig
                if same_pending < IGNORED_AFTER then
                    local ok, res = pcall(ai_pending, g, state)
                    if not ok then g.crash = "harness ai_pending: " .. tostring(res); break end
                    for _, r in ipairs(res) do
                        msgs[#msgs + 1] = { op_code = 5, sender = { user_id = r.uid }, data = r.payload }
                    end
                    -- 只有真正发出响应却无进展才算"服务端忽略"
                    if #msgs > 0 then
                        same_pending = same_pending + 1
                        if same_pending == IGNORED_AFTER then
                            g.ignored[pa.type] = (g.ignored[pa.type] or 0) + 1
                        end
                    end
                end
            elseif not resuming then
                last_pending, same_pending = nil, 0
                local uid = state.current_turn_id
                local p = uid and state.players[uid]
                if p and p.health > 0 then
                    -- 用生产回合计数区分回合，同一玩家连续两回合也会重置
                    local turn_key = uid .. "#" .. tostring(state.turns)
                    if turn_key ~= last_turn then
                        last_turn, blocked, plays_this_turn = turn_key, {}, 0
                    end
                    local play = false
                    if plays_this_turn < MAX_PLAYS_PER_TURN then
                        local ok, res = pcall(ai_play, g, state, uid, blocked)
                        if not ok then g.crash = "harness ai_play: " .. tostring(res); break end
                        play = res
                    end
                    if play then
                        plays_this_turn = plays_this_turn + 1
                        played = { uid = uid, card = play.card_id }
                        msgs[1] = { op_code = 3, sender = { user_id = uid }, data = play }
                    else
                        msgs[1] = { op_code = 4, sender = { user_id = uid }, data = {} }
                    end
                end
            end
        end

        local ok, ret = pcall(handler.match_loop, ctx, disp, tick, state, msgs)
        g.turns = state.turns or 0
        if not ok then g.crash = tostring(ret); break end
        if ret == nil then g.ended = true; break end

        -- 牌还在手上且没有进入结算 = 被规则拒绝；同类型牌本回合不再尝试（如【杀】次数用完）
        if played and not state.pending_action and in_hand(state.players[played.uid], played.card) then
            blocked[played.card] = true
            for _, c in ipairs(state.players[played.uid].hand) do
                if c.id == played.card and c.type == "ATTACK" then blocked.ATTACK = true end
            end
        elseif played then
            g.plays = g.plays + 1
        end
        if g.turns > MAX_TURNS then break end
    end
    g.finished = g.winner ~= nil
    g.draw = g.ended and not g.finished  -- 例：PVP 双方同时阵亡，check_victory 返回 winner=nil
    return g
end

--------------------------------------------------------------------------------
-- 对局配置：每局独立 seed，英雄随机且不重复
--------------------------------------------------------------------------------
local ALL_HEROES = {}
for hid in pairs(catalog.HEROES) do ALL_HEROES[#ALL_HEROES + 1] = hid end
table.sort(ALL_HEROES)

local function game_config(i)
    local seed = OPT.seed + i
    local mode = OPT.mode
    if mode == "mix" then mode = (i % 2 == 1) and "pvp" or "identity" end
    math.randomseed(seed * 7919)
    local pool = {}
    for k, h in ipairs(ALL_HEROES) do pool[k] = h end
    for k = #pool, 2, -1 do
        local j = math.random(k)
        pool[k], pool[j] = pool[j], pool[k]
    end
    local n = mode == "pvp" and 2 or 5
    local heroes = {}
    for k = 1, n do heroes[k] = pool[k] end
    return { seed = seed, mode = mode, heroes = heroes }
end

--------------------------------------------------------------------------------
-- 统计
--------------------------------------------------------------------------------
local function wilson(w, n)
    if n == 0 then return 0, 0 end
    local z, p = 1.96, w / n
    local d = 1 + z * z / n
    local c = (p + z * z / (2 * n)) / d
    local h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return math.max(0, c - h), math.min(1, c + h)
end

-- FNV-1a，给结果序列算摘要，用于确定性比对
local function fnv(h, s)
    for k = 1, #s do h = ((h ~ s:byte(k)) * 16777619) & 0xffffffff end
    return h
end

local FACTION_OF_WIN = { MONARCH_WIN = { MONARCH = true, MINISTER = true }, REBEL_WIN = { REBEL = true }, TRAITOR_WIN = { TRAITOR = true } }

local S = {
    games = 0, finished = 0, draws = 0, crashes = {}, turns = 0, plays = 0,
    by_mode = { pvp = { n = 0, fin = 0 }, identity = { n = 0, fin = 0 } },
    faction = {}, hero = {}, triggers = {}, played = {}, unknown = {}, ignored = {},
}
local digest = 2166136261

local first, last = 1, OPT.games
if OPT.game then first, last = OPT.game, OPT.game end

for i = first, last do
    local cfg = game_config(i)
    local g = run_game(cfg)
    local st = g.state
    S.games = S.games + 1
    S.by_mode[cfg.mode].n = S.by_mode[cfg.mode].n + 1
    S.turns = S.turns + g.turns
    S.plays = S.plays + g.plays
    for t, c in pairs(g.unknown) do S.unknown[t] = (S.unknown[t] or 0) + c end
    for t, c in pairs(g.ignored) do S.ignored[t] = (S.ignored[t] or 0) + c end
    if g.draw then S.draws = S.draws + 1 end
    if g.crash then S.crashes[#S.crashes + 1] = string.format("game %d (seed %d): %s", i, cfg.seed, g.crash) end

    for _, h in ipairs(cfg.heroes) do S.played[h] = true end
    for h, skills in pairs(g.triggers) do
        S.triggers[h] = S.triggers[h] or 0
        for _, c in pairs(skills) do S.triggers[h] = S.triggers[h] + c end
    end

    if g.finished then
        S.finished = S.finished + 1
        S.by_mode[cfg.mode].fin = S.by_mode[cfg.mode].fin + 1
        local winners = {}
        if cfg.mode == "pvp" then
            winners[g.winner] = true
        else
            S.faction[g.winner] = (S.faction[g.winner] or 0) + 1
            local roles = FACTION_OF_WIN[g.winner] or {}
            for _, uid in ipairs(st.presence_ids) do
                if roles[st.players[uid].role] then winners[uid] = true end
            end
        end
        for k, uid in ipairs(st.presence_ids) do
            local h = st.players[uid].hero or cfg.heroes[k]
            local key = cfg.mode .. ":" .. h
            S.hero[key] = S.hero[key] or { w = 0, n = 0 }
            S.hero[key].n = S.hero[key].n + 1
            if winners[uid] then S.hero[key].w = S.hero[key].w + 1 end
        end
    end

    local trig = {}
    for h, skills in pairs(g.triggers) do  -- pairs 已按 key 排序，顺序稳定
        local n = 0
        for _, c in pairs(skills) do n = n + c end
        trig[#trig + 1] = h .. ":" .. n
    end
    local line = string.format("%d|%s|%s|%d|%d|%d|%s", i, cfg.mode, tostring(g.winner), g.turns, g.plays, g.ticks, table.concat(trig, ","))
    digest = fnv(digest, line)
    if OPT.verbose or OPT.games <= 20 then
        print(string.format("  game %-4d seed=%-6d %-8s %-12s turns=%-4d plays=%-4d %s",
            i, cfg.seed, cfg.mode, g.crash and "CRASH" or tostring(g.winner or (g.draw and "draw" or "unfinished")),
            g.turns, g.plays, table.concat(cfg.heroes, ",")))
    end
end

--------------------------------------------------------------------------------
-- 报告 + 门禁
--------------------------------------------------------------------------------
local function sorted_keys(t)
    local k = {}
    for key in pairs(t) do k[#k + 1] = key end
    table.sort(k)
    return k
end

local unfinished = S.games - S.finished - S.draws - #S.crashes
local unfinished_rate = S.games > 0 and unfinished / S.games or 0
print(string.rep("─", 72))
print(string.format("games=%d finished=%d draws=%d unfinished=%d (%.1f%%) crashes=%d avg_turns=%.1f plays=%d",
    S.games, S.finished, S.draws, unfinished, unfinished_rate * 100, #S.crashes, S.turns / math.max(S.games, 1), S.plays))
for _, m in ipairs({ "pvp", "identity" }) do
    local b = S.by_mode[m]
    if b.n > 0 then print(string.format("  %-8s %d/%d finished", m, b.fin, b.n)) end
end

if S.by_mode.identity.fin > 0 then
    local parts = {}
    for _, f in ipairs({ "MONARCH_WIN", "REBEL_WIN", "TRAITOR_WIN" }) do
        local w = S.faction[f] or 0
        local lo, hi = wilson(w, S.by_mode.identity.fin)
        parts[#parts + 1] = string.format("%s %.0f%% [%.0f-%.0f]", f, 100 * w / S.by_mode.identity.fin, lo * 100, hi * 100)
    end
    print("  faction  " .. table.concat(parts, "  "))
end

if S.games >= 100 then
    print("\nhero win rate (95% Wilson CI; * = CI excludes 50% in pvp)")
    for _, key in ipairs(sorted_keys(S.hero)) do
        local r = S.hero[key]
        local lo, hi = wilson(r.w, r.n)
        local flag = (key:match("^pvp:") and (lo > 0.5 or hi < 0.5)) and "*" or " "
        print(string.format("  %s %-28s %3d/%-4d %5.1f%%  [%4.1f-%4.1f]", flag, key, r.w, r.n, 100 * r.w / r.n, lo * 100, hi * 100))
    end
end

local played_n, triggered_n, silent = 0, 0, {}
for _, h in ipairs(sorted_keys(S.played)) do
    played_n = played_n + 1
    if (S.triggers[h] or 0) > 0 then triggered_n = triggered_n + 1 else silent[#silent + 1] = h end
end
print(string.format("\nskill coverage: %d/%d heroes triggered%s", triggered_n, played_n,
    #silent > 0 and ("  never: " .. table.concat(silent, ",")) or ""))

for _, t in ipairs(sorted_keys(S.ignored)) do
    print(string.format("FAIL server ignored AI response to %s ×%d (resolved by deadline)", t, S.ignored[t]))
end
for _, t in ipairs(sorted_keys(S.unknown)) do
    print(string.format("FAIL unknown pending_action %s ×%d (AI 无对应响应)", t, S.unknown[t]))
end
for _, c in ipairs(S.crashes) do print("FAIL crash " .. c) end
print(string.format("digest=%08x", digest))

-- 服务端静默丢弃客户端响应（濒死自救、武器询问都曾如此）也算失败
local failed = #S.crashes > 0 or next(S.unknown) ~= nil or next(S.ignored) ~= nil
    or unfinished_rate > OPT.max_unfinished
if unfinished_rate > OPT.max_unfinished then
    print(string.format("FAIL unfinished rate %.1f%% > %.1f%%", unfinished_rate * 100, OPT.max_unfinished * 100))
end
os.exit(failed and 1 or 0)

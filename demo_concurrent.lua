-- demo_concurrent.lua  全英雄并发验证 Demo
-- 15 局对局 Round-Robin 推进，覆盖全部 30 个英雄
-- Run: lua5.4 demo_concurrent.lua

--------------------------------------------------------------------------------
-- Mock Setup
--------------------------------------------------------------------------------
local nk = {
    json_encode              = function(t) return type(t) == "table" and t or tostring(t) end,
    json_decode              = function(s) return type(s) == "table" and s or {} end,
    logger_info              = function() end,
    logger_warn              = function() end,
    storage_read             = function(reads)
        if reads and reads[1] and reads[1].collection == "season_config" then
            return {{ value = { season_id = "s1", leaderboard_id = "lb1" } }}
        end
        return {}
    end,
    storage_write            = function() end,
    storage_list             = function() return {} end,
    storage_delete           = function() end,
    wallet_update            = function() end,
    notifications_send       = function() end,
    status_update            = function() end,
    http_request             = function() return 200, {}, '{"status":0,"receipt":{"in_app":[{"transaction_id":"txn_test","product_id":"com.asura.gold_60","purchase_date_ms":"1000000"}]}}' end,
    account_get_id           = function() return { wallet = { gold = 500 } } end,
    register_rpc             = function() end,
    leaderboard_create       = function() end,
    leaderboard_record_write = function() end,
    leaderboard_records_list = function() return {}, nil, nil end,
}
package.loaded["nakama"] = nk
os.time = function() return 1000000 end

package.path = package.path .. ";/Users/yalla/work/mycode/asura/?.lua"

local handler  = require("match_handler")
local rules    = require("game_rules")
local hero_mgr = require("hero_manager")

--------------------------------------------------------------------------------
-- 技能触发统计（每个英雄触发过的技能及次数）
--------------------------------------------------------------------------------
local TRIGGERS = {}   -- hero_id -> {skill_name -> count}

local function make_dispatcher(prefix)
    return {
        broadcast_message = function(op, data, _)
            if op ~= 11 then return end
            local _    = type(data) == "table" and (data.content or "") or ""
            local hero  = type(data) == "table" and data.hero
            local skill = type(data) == "table" and data.skill
            if hero and skill then
                TRIGGERS[hero] = TRIGGERS[hero] or {}
                TRIGGERS[hero][skill] = (TRIGGERS[hero][skill] or 0) + 1
            end
        end,
        match_label_update = function() end,
    }
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local CN = {
    ATTACK="攻击", DEFENSE="防御", HEAL="治疗", WINE="酒",
    WEAPON="武器", ARMOR="防具", HORSE="马匹",
    DELAYED_TRICK="延时", INSTANT_TRICK="锦囊",
}
local function hand_str(hand)
    local t = {}
    for _, c in ipairs(hand) do
        local label = CN[c.type] or c.type
        if c.type == "INSTANT_TRICK" and c.subtype then
            local st_map = { draw_two="无中生有", aoe_attack="南蛮", aoe_defense="万箭",
                duel="决斗", discard_one="拆", steal_one="顺", mass_heal="桃园", mass_draw="五谷" }
            label = st_map[c.subtype] or c.subtype
        elseif c.type == "DELAYED_TRICK" and c.subtype then
            local st_map = { skip_play="乐", skip_draw="兵", lightning="闪电" }
            label = st_map[c.subtype] or c.subtype
        end
        table.insert(t, label)
    end
    return #t > 0 and table.concat(t, "/") or "空"
end

-- 卡牌优先级（越低越优先丢弃/越不重要）
local DISCARD_PRIORITY = {
    ATTACK = 1, DEFENSE = 1, HEAL = 0, WINE = 1,
    INSTANT_TRICK = 2, DELAYED_TRICK = 3,
    WEAPON = 4, ARMOR = 4, HORSE = 4,
}
-- 卡牌价值（越高越值得保留）
local VALUE_PRIORITY = {
    HEAL = 10, DEFENSE = 9, ATTACK = 8, WINE = 7,
    INSTANT_TRICK = 6, DELAYED_TRICK = 3,
    WEAPON = 4, ARMOR = 4, HORSE = 4,
}

--------------------------------------------------------------------------------
-- AI：解决所有 pending_action（覆盖全部 30 个英雄的技能响应）
--------------------------------------------------------------------------------
local function ai_handle_pending(state)
    for _ = 1, 40 do
        local action = state.pending_action
        if not action then break end

        -- ---- 防御/AOE 响应 ----
        if action.type == "WAITING_FOR_DEFENSE" then
            local p = state.players[action.target_id]
            if not p then state.pending_action = nil; break end
            local dmg = action.damage or 1
            if dmg >= p.health then
                local def_card
                for _, c in ipairs(p.hand) do if c.type == "DEFENSE" then def_card = c; break end end
                rules.handle_response(state._dispatcher, state, action.target_id,
                    {confirm = def_card ~= nil, card_id = def_card and def_card.id or nil})
            else
                rules.handle_response(state._dispatcher, state, action.target_id, {confirm=false})
            end

        elseif action.type == "WAITING_FOR_AOE" then
            local p = state.players[action.current_target]
            if not p then state.pending_action = nil; break end
            local required = action.required_response or "DEFENSE"
            if 1 >= p.health then
                local found_card
                for _, c in ipairs(p.hand) do
                    if c.type == required then found_card = c; break end
                end
                rules.handle_response(state._dispatcher, state, action.current_target,
                    {confirm = found_card ~= nil, card_id = found_card and found_card.id or nil})
            else
                rules.handle_response(state._dispatcher, state, action.current_target, {confirm=false})
            end

        -- ---- 决斗 ----
        elseif action.type == "WAITING_FOR_DUEL" then
            local current = action.is_attackers_turn and action.attacker_id or action.target_id
            local p = state.players[current]
            local atk_card
            if p then
                for _, c in ipairs(p.hand) do
                    if c.type == "ATTACK" then atk_card = c; break end
                end
            end
            rules.handle_response(state._dispatcher, state, current,
                {confirm = atk_card ~= nil, card_id = atk_card and atk_card.id or nil})

        -- ---- 锦囊选择（过河拆桥/顺手牵羊） ----
        elseif action.type == "WAITING_FOR_TRICK_SELECT" then
            -- 让 fallback 随机选
            rules.handle_response(state._dispatcher, state, action.source_id, {confirm=false})

        -- ---- 英雄技能响应 ----

        elseif action.type == "ALIBABA_COUNTER" then
            hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=true})

        elseif action.type == "HAKIM_XING_XIANG" then
            if action.cards and #action.cards > 0 then
                local sorted = {}
                for _, c in ipairs(action.cards) do table.insert(sorted, c) end
                table.sort(sorted, function(a, b)
                    return (VALUE_PRIORITY[a.type] or 0) > (VALUE_PRIORITY[b.type] or 0)
                end)
                local sorted_ids = {}
                for _, c in ipairs(sorted) do table.insert(sorted_ids, c.id) end
                hero_mgr.handle_response(state._dispatcher, state, action.player_id,
                    {confirm=true, sorted_ids=sorted_ids})
            else
                hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=false})
            end

        elseif action.type == "SCHEHERAZADE_QIANYE" then
            local p = state.players[action.player_id]
            if p and #p.hand >= 1 and action.shown_cards and #action.shown_cards > 0 then
                -- 弃掉最不重要的牌
                local worst_idx = 1
                local worst_score = 0
                for i, c in ipairs(p.hand) do
                    local s = DISCARD_PRIORITY[c.type] or 0
                    if s > worst_score then worst_score = s; worst_idx = i end
                end
                hero_mgr.handle_response(state._dispatcher, state, action.player_id,
                    {confirm=true, own_card_id=p.hand[worst_idx].id, target_card_id=action.shown_cards[1].id})
            else
                hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=false})
            end

        elseif action.type == "HARUN_CHOOSE" then
            hero_mgr.handle_response(state._dispatcher, state, action.player_id,
                {confirm=true, choose_discard=false})

        elseif action.type == "RUMI_XUANHUI" then
            hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=true})

        elseif action.type == "IBN_BATTUTA_YUAN_XING" then
            local p = state.players[action.player_id]
            if #p.hand >= 1 then
                hero_mgr.handle_response(state._dispatcher, state, action.player_id,
                    {confirm=true, card_ids={p.hand[1].id}})
            else
                hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=false})
            end

        elseif action.type == "AL_KHWARIZMI_SUANFA" then
            if action.cards and #action.cards > 0 then
                local sorted = {}
                for _, c in ipairs(action.cards) do table.insert(sorted, c) end
                table.sort(sorted, function(a, b)
                    return (VALUE_PRIORITY[a.type] or 0) > (VALUE_PRIORITY[b.type] or 0)
                end)
                local sorted_ids, keep_ids = {}, {}
                for _, c in ipairs(sorted) do table.insert(sorted_ids, c.id) end
                for i = 1, math.min(2, #sorted) do table.insert(keep_ids, sorted[i].id) end
                hero_mgr.handle_response(state._dispatcher, state, action.player_id,
                    {confirm=true, sorted_ids=sorted_ids, keep_ids=keep_ids})
            else
                hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=false})
            end

        elseif action.type == "AL_BIRUNI_CELIANG" then
            if action.cards and #action.cards > 0 then
                local sorted = {}
                for _, c in ipairs(action.cards) do table.insert(sorted, c) end
                table.sort(sorted, function(a, b)
                    return (VALUE_PRIORITY[a.type] or 0) > (VALUE_PRIORITY[b.type] or 0)
                end)
                local keep = {}
                for i = 1, math.min(2, #sorted) do table.insert(keep, sorted[i].id) end
                hero_mgr.handle_response(state._dispatcher, state, action.player_id,
                    {confirm=true, keep_ids=keep})
            else
                hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=false})
            end

        elseif action.type == "GILGAMESH_BU_XIU" then
            if action.cards and #action.cards > 0 then
                hero_mgr.handle_response(state._dispatcher, state, action.player_id,
                    {confirm=true, card_id=action.cards[1].id})
            else
                hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=false})
            end

        elseif action.type == "SULEIMAN_CHI_LING" then
            if action.targets and #action.targets > 0 then
                local block_types = {"ATTACK", "DEFENSE", "HEAL"}
                hero_mgr.handle_response(state._dispatcher, state, action.player_id,
                    {confirm=true, target_id=action.targets[1].id, block_type=block_types[math.random(#block_types)]})
            else
                hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=false})
            end

        elseif action.type == "HARUN_SELECT_TARGET" then
            if action.targets and #action.targets > 0 then
                hero_mgr.handle_response(state._dispatcher, state, action.player_id,
                    {confirm=true, target_id=action.targets[1].id})
            else
                hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=false})
            end

        elseif action.type == "ENHEDUANNA_SONG_CI" then
            hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=true})

        elseif action.type == "ENHEDUANNA_SONG_CI_GIVE" then
            if action.hand_cards and #action.hand_cards > 0 and action.targets and #action.targets > 0 then
                hero_mgr.handle_response(state._dispatcher, state, action.player_id,
                    {confirm=true, card_id=action.hand_cards[1].id, target_id=action.targets[1].id})
            else
                hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=true})
            end

        elseif action.type == "AVICENNA_ZHEN" then
            if action.heart_cards and #action.heart_cards > 0 then
                hero_mgr.handle_response(state._dispatcher, state, action.player_id,
                    {confirm=true, card_id=action.heart_cards[1].id})
            else
                hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=false})
            end

        elseif action.type == "WAITING_FOR_RESCUE" then
            local rescuer_id = action.rescuers and action.rescuers[action.current_rescuer_idx]
            local rescuer = state.players[rescuer_id]
            if rescuer then
                local dying_id = action.dying_player_id
                local is_self = (rescuer_id == dying_id)
                local rescue_idx
                for i, c in ipairs(rescuer.hand) do
                    -- 自救可用桃/酒；救他人只能用桃
                    if c.type == "HEAL" or (is_self and c.type == "WINE")
                        or (c.suit == "HEART" and rescuer.hero == "avicenna") then
                        rescue_idx = i; break
                    end
                end
                if rescue_idx then
                    local card = rescuer.hand[rescue_idx]
                    rules.handle_response(state._dispatcher, state, rescuer_id, {confirm=true, card_id=card.id})
                else
                    rules.handle_response(state._dispatcher, state, rescuer_id, {confirm=false})
                end
            else
                state.pending_action = nil
                break
            end

        elseif action.type == "WAITING_FOR_COUNTER" then
            -- 并行模式：找第一个未 pass 的玩家代为 pass
            local target_id
            for _, uid in ipairs(action.remaining_order) do
                if not action.responded[uid] then
                    target_id = uid
                    break
                end
            end
            if not target_id then
                state.pending_action = nil
                break
            end
            rules.handle_response(state._dispatcher, state, target_id, {confirm=false, round=action.round})

        elseif action.type == "WAITING_FOR_BORROW_WEAPON" then
            rules.handle_response(state._dispatcher, state, action.target_id, {confirm=false})

        elseif action.type == "WAITING_FOR_FIRE_GUESS" then
            local suits = {"HEART", "SPADE", "CLUB", "DIAMOND"}
            rules.handle_response(state._dispatcher, state, action.caster_id,
                {confirm=true, guess=suits[math.random(#suits)]})

        else
            io.stderr:write("[WARN] 未知 pending_action: " .. tostring(action.type) .. "\n")
            state.pending_action = nil
            break
        end
    end
end

--------------------------------------------------------------------------------
-- AI：出牌策略（覆盖全牌型，最大化技能触发概率）
--------------------------------------------------------------------------------
local function ai_choose(state, uid)
    local p = state.players[uid]

    -- ── 目标选择 ─────────────────────────────────────────────────────────
    local target_id

    if p.role == "NONE" then
        for oid, op in pairs(state.players) do
            if oid ~= uid and op.health > 0 then
                if not target_id or op.health < state.players[target_id].health then
                    target_id = oid
                end
            end
        end
    else
        local monarch_id
        local rebel_count, minister_count = 0, 0
        for oid, op in pairs(state.players) do
            if op.health > 0 then
                if op.role == "MONARCH"  then monarch_id     = oid end
                if op.role == "REBEL"    then rebel_count    = rebel_count    + 1 end
                if op.role == "MINISTER" then minister_count = minister_count + 1 end
            end
        end

        if p.role == "REBEL" then
            target_id = monarch_id
        elseif p.role == "TRAITOR" then
            if rebel_count > 0 then
                for oid, op in pairs(state.players) do
                    if oid ~= uid and op.health > 0 and op.role == "REBEL" then
                        if not target_id or op.health < state.players[target_id].health then
                            target_id = oid
                        end
                    end
                end
            elseif minister_count > 0 then
                for oid, op in pairs(state.players) do
                    if oid ~= uid and op.health > 0 and op.role == "MINISTER" then
                        target_id = oid; break
                    end
                end
            else
                target_id = monarch_id
            end
        else
            for oid, op in pairs(state.players) do
                if oid ~= uid and op.health > 0
                   and (op.role == "REBEL" or op.role == "TRAITOR") then
                    if not target_id or op.health < state.players[target_id].health then
                        target_id = oid
                    end
                end
            end
        end

        if not target_id then
            for oid, op in pairs(state.players) do
                if oid ~= uid and op.health > 0 then target_id = oid; break end
            end
        end
    end

    -- ── 出牌优先级 ───────────────────────────────────────────────────────
    local function find_trick(subtypes)
        for _, c in ipairs(p.hand) do
            if c.type == "INSTANT_TRICK" then
                for _, s in ipairs(subtypes) do
                    if c.subtype == s then return c end
                end
            end
        end
    end

    -- 1. 装备（武器/防具/马）
    for _, c in ipairs(p.hand) do
        if c.type == "WEAPON" or c.type == "ARMOR" or c.type == "HORSE" then
            return {card_id=c.id}
        end
    end
    -- 2. 濒死才回血（HP≤2）
    if p.health <= 2 then
        for _, c in ipairs(p.hand) do
            if c.type == "HEAL" then return {card_id=c.id} end
        end
    end
    -- 3. AOE（南蛮/万箭）
    local aoe = find_trick({"aoe_attack", "aoe_defense"})
    if aoe then return {card_id=aoe.id} end
    -- 4. 酒牌
    if not p.weapon_buff then
        for _, c in ipairs(p.hand) do
            if c.type == "WINE" then return {card_id=c.id} end
        end
    end
    -- 5. 攻击
    if target_id then
        for _, c in ipairs(p.hand) do
            if c.type == "ATTACK" then return {card_id=c.id, target_id=target_id} end
        end
    end
    -- 6. 延时锦囊
    if target_id then
        for _, c in ipairs(p.hand) do
            if c.type == "DELAYED_TRICK" then return {card_id=c.id, target_id=target_id} end
        end
    end
    -- 7. 即时锦囊（需目标的：决斗/拆/顺/借刀杀人/火攻）
    if target_id then
        local targeted = find_trick({"duel", "discard_one", "steal_one", "borrow_weapon", "fire_attack"})
        if targeted then return {card_id=targeted.id, target_id=target_id} end
    end
    -- 8. 不需要目标的锦囊（无中生有/桃园结义/五谷丰登/铁索连环重铸）
    local self_trick = find_trick({"draw_two", "mass_heal", "mass_draw", "iron_chain"})
    if self_trick then return {card_id=self_trick.id} end

    return nil
end

--------------------------------------------------------------------------------
-- 推进一个回合，返回 true=继续，false=结束
--------------------------------------------------------------------------------
local function tick_match(m)
    if m.state.status ~= 1 then return false end

    local uid = m.state.current_turn_id
    local p   = m.state.players[uid]
    if not p or p.health <= 0 then
        handler.next_turn(m.dispatcher, m.state)
        ai_handle_pending(m.state)
        return true
    end

    if m.state.pending_action then
        ai_handle_pending(m.state)
        return true
    end

    local action = ai_choose(m.state, uid)
    if action then
        rules.handle_play_card(m.dispatcher, m.state, uid, action)
        ai_handle_pending(m.state)
    end

    local over, winner = rules.check_victory(m.dispatcher, m.state)
    if over then
        m.state.status = 2
        m.winner = winner
        return false
    end

    handler.next_turn(m.dispatcher, m.state)
    ai_handle_pending(m.state)
    return true
end

--------------------------------------------------------------------------------
-- 15 局对局配置（覆盖全部 30 英雄）
--------------------------------------------------------------------------------
local ALL_HEROES_LIST = {
    "aladdin","alibaba","saladin","hakim","scheherazade","jafar",
    "ibn_battuta","al_khwarizmi","avicenna","sinbad","hulagu","rumi",
    "zubaydah","al_biruni","tamerlane","dunyazad","antar","nefertiti",
    "harun_al_rashid","suleiman","khayyam","zenobia","muawiyah","nizamulmulk",
    "enheduanna","al_mansur","gilgamesh","imru_al_qais","basira","dhul_qarnayn",
}
local HERO_CN = {
    aladdin="阿拉丁", alibaba="阿里巴巴", saladin="萨拉丁", hakim="哈基姆",
    scheherazade="谢赫拉莎德", jafar="贾法尔", sinbad="辛巴达", hulagu="旭烈兀",
    nefertiti="纳芙蒂蒂", antar="安塔拉", khayyam="海亚姆", zenobia="芝诺比娅",
    harun_al_rashid="哈伦·拉希德", gilgamesh="吉尔伽美什", avicenna="阿维森纳",
    ibn_battuta="伊本·白图泰", al_khwarizmi="花剌子密", basira="巴希拉",
    imru_al_qais="乌姆鲁勒·盖斯", dunyazad="敦娅扎德", muawiyah="穆阿维叶",
    nizamulmulk="尼扎姆·穆勒克", enheduanna="恩赫杜安娜", al_mansur="曼苏尔",
    dhul_qarnayn="双角王", rumi="鲁米", tamerlane="帖木儿", zubaydah="祖拜达",
    al_biruni="比鲁尼", suleiman="苏莱曼大帝",
}

local function shuffled_heroes(seed)
    math.randomseed(seed)
    local t = {}
    for _, h in ipairs(ALL_HEROES_LIST) do table.insert(t, h) end
    for i = #t, 2, -1 do
        local j = math.random(i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

local MATCH_CONFIGS = {}
local gid = 0
for i = 1, 5 do
    local sh = shuffled_heroes(1000 + i)
    MATCH_CONFIGS[i] = { seed = 1000 + i, players = {
        {id="g"..(gid+1), name=HERO_CN[sh[1]], hero=sh[1]},
        {id="g"..(gid+2), name=HERO_CN[sh[2]], hero=sh[2]},
    }}
    gid = gid + 2
end
for i = 6, 10 do
    local sh = shuffled_heroes(2000 + i)
    MATCH_CONFIGS[i] = { seed = 2000 + i, players = {
        {id="g"..(gid+1), name=HERO_CN[sh[1]], hero=sh[1]},
        {id="g"..(gid+2), name=HERO_CN[sh[2]], hero=sh[2]},
        {id="g"..(gid+3), name=HERO_CN[sh[3]], hero=sh[3]},
        {id="g"..(gid+4), name=HERO_CN[sh[4]], hero=sh[4]},
        {id="g"..(gid+5), name=HERO_CN[sh[5]], hero=sh[5]},
    }}
    gid = gid + 5
end

--------------------------------------------------------------------------------
-- 初始化所有对局
--------------------------------------------------------------------------------
local matches = {}
for i, cfg in ipairs(MATCH_CONFIGS) do
    math.randomseed(cfg.seed)
    local label     = string.format("[对局%02d]", i)
    local disp      = make_dispatcher(label)
    local ctx       = {}
    local plist     = cfg.players
    local max_p     = #plist

    local state = handler.match_init(ctx, {max_players=max_p})
    state._dispatcher = disp

    for _, pc in ipairs(plist) do
        local pr = {user_id=pc.id, username=pc.name}
        state = handler.match_join(ctx, disp, 0, state, {pr})
        state._dispatcher = disp
    end

    for _, pc in ipairs(plist) do
        state.players[pc.id].hero = pc.hero
    end

    matches[i] = {state=state, dispatcher=disp, label=label, winner=nil, turns=0, crashed=false, plist=plist}
end

--------------------------------------------------------------------------------
-- Round-Robin：15 局交替推进
--------------------------------------------------------------------------------
print("╔════════════════════════════════════════════════════════════════╗")
print("║  阿苏拉 · 随机英雄测试（5局2人PVP+5局5人身份局）             ║")
print("╚════════════════════════════════════════════════════════════════╝")
for i, cfg in ipairs(MATCH_CONFIGS) do
    local parts = {}
    for _, pc in ipairs(cfg.players) do table.insert(parts, pc.name.."("..pc.hero..")") end
    local mode = #cfg.players == 2 and "2P" or "5P"
    print(string.format("  对局%02d  [%s]  %s  seed=%d", i, mode, table.concat(parts, " / "), cfg.seed))
end
print(string.rep("─", 64))

local MAX_TICKS = 50 * #matches
local global_tick = 0

while global_tick < MAX_TICKS do
    local all_done = true
    for _, m in ipairs(matches) do
        if m.state.status == 1 then
            all_done = false
            m.turns = m.turns + 1
            local ok, err = pcall(tick_match, m)
            if not ok then
                m.state.status = 2
                m.winner = "崩溃"
                m.crash_msg = tostring(err)
                m.crashed = true
            end
        end
    end
    global_tick = global_tick + 1
    if all_done then break end
end

--------------------------------------------------------------------------------
-- 对局结果汇总
--------------------------------------------------------------------------------
local WIN_CN = {MONARCH_WIN="主公阵营胜", REBEL_WIN="反贼阵营胜", TRAITOR_WIN="内奸胜", PVP_WIN="PVP对决胜"}
print("\n══════════════════ 对局结果汇总 ══════════════════")
local crashed_count = 0
for i, m in ipairs(matches) do
    local cfg    = MATCH_CONFIGS[i]
    local result = WIN_CN[m.winner] or m.winner or "未结束"
    local status = m.crashed and "✗ 崩溃" or "✓"
    local mode = #cfg.players == 2 and "2P" or "5P"
    print(string.format("  对局%02d  [%s]  %s  共%d回合  %s", i, mode, result, m.turns, status))
    if m.crashed then
        print("         错误: " .. m.crash_msg)
        crashed_count = crashed_count + 1
    end
    for _, pc in ipairs(m.plist) do
        local p = m.state.players[pc.id]
        if p then
            local role_display = (p.role == "NONE" or not p.role) and "PVP" or p.role
            print(string.format("         %-10s %-8s HP:%d/%d 手牌:%d [%s]",
                p.username, role_display, p.health, p.max_health, #p.hand, hand_str(p.hand)))
        end
    end
    print(string.rep("─", 64))
end

--------------------------------------------------------------------------------
-- 技能触发统计
--------------------------------------------------------------------------------
local ALL_HEROES = ALL_HEROES_LIST

print("\n══════════════════ 技能触发统计 ══════════════════")
local triggered_count = 0
for _, hero in ipairs(ALL_HEROES) do
    local skills = TRIGGERS[hero]
    if skills then
        triggered_count = triggered_count + 1
        local parts = {}
        for sk, cnt in pairs(skills) do
            table.insert(parts, sk .. "×" .. cnt)
        end
        table.sort(parts)
        print(string.format("  ✓ %-22s %s", hero, table.concat(parts, "  ")))
    else
        print(string.format("  ○ %-22s （未触发）", hero))
    end
end

print(string.rep("─", 64))
print(string.format("\n英雄技能触发: %d/30  崩溃对局: %d/%d\n",
    triggered_count, crashed_count, #MATCH_CONFIGS))

if crashed_count == 0 then
    print("随机英雄测试全部运行完毕，无崩溃 ✓")
else
    print(string.format("存在 %d 局崩溃，请检查上方错误信息", crashed_count))
    os.exit(1)
end

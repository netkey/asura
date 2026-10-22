-- 双角王【筑壁】主动铸壁：出牌阶段弃 1 张手牌，把壁垒公开放在任意一名角色身上；
-- 带壁垒者下次受伤 -1，壁垒消耗，双角王不摸牌；场上同时最多 2 枚；准备阶段不再免费回收。
-- 放壁经 hero_mgr.handle_response（DHUL_SKILL_CHOICE），伤害经 rules.apply_damage，可见性经 broadcast_update。
-- Run: lua5.4 tests/dhul_wall_test.lua
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
package.path = root .. "/?.lua;" .. package.path

local nk = setmetatable({
    json_encode = function(t) return t end,
    json_decode = function(s) return type(s) == "table" and s or {} end,
}, { __index = function() return function() end end })
package.loaded["nakama"] = nk
math.randomseed(1)

local rules = require("game_rules")
local hero_mgr = require("hero_manager")

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("  ok   " .. name)
    else
        failures = failures + 1
        print("  FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
    end
end

local sent = {}
local disp = {
    broadcast_message = function(op, data, presences)
        sent[#sent + 1] = { op = op, data = data, to = presences }
    end,
    match_label_update = function() end,
}

local function card(id, ctype)
    return { id = id, type = ctype, suit = "SPADE", number = 1, name = id }
end

local function player(id, role, hero)
    return { id = id, username = id, role = role, hero = hero or "test_vanilla", health = 4, max_health = 4,
             hand = {}, equipment = {}, delayed_effects = {}, seat_idx = 0 }
end

-- d = 双角王（反贼），r2 = 反贼队友，k = 主公，m = 忠臣
local function new_state()
    local state = { mode = "identity", players = {}, presences = {}, deck = {}, discard_pile = {}, status = 1,
                    current_turn_id = "d" }
    for i = 1, 30 do state.deck[i] = card("D" .. i, "DEFENSE") end
    state.players.d = player("d", "REBEL", "dhul_qarnayn")
    state.players.r2 = player("r2", "REBEL")
    state.players.k = player("k", "MONARCH")
    state.players.m = player("m", "MINISTER")
    for uid in pairs(state.players) do state.presences[uid] = { user_id = uid } end
    state.players.d.hand = { card("H1", "ATTACK"), card("H2", "ATTACK"), card("H3", "ATTACK"), card("H4", "ATTACK") }
    return state
end

local function offer(state)
    hero_mgr.trigger("on_play_phase_start", disp, state, "d")
    return state.pending_action
end

local function place(state, card_id, target_id)
    local pa = offer(state)
    assert(pa and pa.type == "DHUL_SKILL_CHOICE", "expected skill menu, got " .. tostring(pa and pa.type))
    hero_mgr.handle_response(disp, state, "d", { confirm = true, skill = "wall", card_id = card_id, target_id = target_id })
    state.pending_action = nil
end

local function hit(state, target)
    local hp0 = state.players[target].health
    rules.apply_damage(disp, state, target, 1, nil, "normal")
    state.pending_action = nil
    return hp0 - state.players[target].health
end

print("case 1: 给队友放壁 → 队友下次受伤 -1，壁垒消耗，双角王不摸牌")
do
    local state = new_state()
    place(state, "H1", "r2")
    check("弃掉 1 张手牌作代价", #state.players.d.hand == 3, "hand=" .. #state.players.d.hand)
    local hand_before = #state.players.d.hand
    check("队友受伤被挡", hit(state, "r2") == 0)
    check("双角王未摸牌", #state.players.d.hand == hand_before, "hand=" .. #state.players.d.hand)
    check("壁垒只挡一次", hit(state, "r2") == 1)
end

print("case 2: 未放壁的角色受伤 → 不被保护")
do
    local state = new_state()
    place(state, "H1", "r2")
    check("主公受伤不减", hit(state, "k") == 1)
    check("双角王自己（无壁垒）受伤不减", hit(state, "d") == 1)
end

print("case 3: 可放在敌方身上（玩家自选，用于伪装）")
do
    local state = new_state()
    place(state, "H1", "k")
    check("主公受伤被挡", hit(state, "k") == 0)
end

print("case 4: 场上最多 2 枚；同一角色不可叠两枚")
do
    local state = new_state()
    place(state, "H1", "d")
    place(state, "H2", "d")
    check("同一角色第二枚被拒，牌不扣", #state.players.d.hand == 3, "hand=" .. #state.players.d.hand)
    place(state, "H2", "r2")
    local pa = offer(state)
    check("已有 2 枚 → 菜单不再提供筑壁", not (pa and pa.can_wall), "can_wall=" .. tostring(pa and pa.can_wall))
    state.pending_action = nil
    hit(state, "d")
    pa = offer(state)
    check("消耗 1 枚后可再铸", pa and pa.can_wall == true)
end

print("case 5: 准备阶段不再免费回收壁垒")
do
    local state = new_state()
    state.discard_pile = { card("X1", "ATTACK") }
    hero_mgr.trigger("on_draw_phase_start", disp, state, "d")
    check("准备阶段后双角王受伤不被挡（没有凭空出现的壁垒）", hit(state, "d") == 1)
end

print("case 6: 壁垒公开可见")
do
    local state = new_state()
    place(state, "H1", "r2")
    sent = {}
    rules.broadcast_update(disp, state)
    local seen
    for _, s in ipairs(sent) do
        if s.op == 10 and s.to[1].user_id == "k" then
            for _, o in ipairs(s.data.others) do if o.id == "r2" then seen = o.wall end end
        end
    end
    check("主公视角看到 r2 有壁垒", seen == true, "wall=" .. tostring(seen))
end

print("case 7: 远疆西行/东行每回合各 1 次，重复请求不扣牌")
do
    local state = new_state()
    offer(state)
    hero_mgr.handle_response(disp, state, "d", { confirm = true, skill = "westward", card_id = "H1" })
    local pa = state.pending_action
    check("西行后菜单不再提供西行", pa and pa.can_west == false, "can_west=" .. tostring(pa and pa.can_west))
    hero_mgr.handle_response(disp, state, "d", { confirm = true, skill = "westward", card_id = "H2" })
    check("重复西行被拒，牌不扣", #state.players.d.hand == 3, "hand=" .. #state.players.d.hand)
    state.pending_action = nil
    hero_mgr.trigger("on_turn_end", disp, state, "d")
    pa = offer(state)
    check("下回合可再西行", pa and pa.can_west == true)
end

print("case 8: 未知技能名不扣牌")
do
    local state = new_state()
    offer(state)
    hero_mgr.handle_response(disp, state, "d", { confirm = true, skill = "bogus", card_id = "H1" })
    check("手牌未减少", #state.players.d.hand == 4, "hand=" .. #state.players.d.hand)
end

print("case 9: 断线重连快照含壁垒；阵亡者不显示壁垒")
do
    local state = new_state()
    local handler = require("match_handler")
    place(state, "H1", "r2")
    place(state, "H2", "m")
    state.players.m.health = 0
    sent = {}
    handler.send_full_state_to_player(disp, state, { user_id = "k" })
    local walls = {}
    for _, o in ipairs(sent[#sent].data.others) do walls[o.id] = o.wall end
    check("重连快照中 r2 有壁垒", walls.r2 == true, "wall=" .. tostring(walls.r2))
    check("阵亡的 m 不显示壁垒", walls.m ~= true, "wall=" .. tostring(walls.m))
    sent = {}
    handler.send_full_state_to_player(disp, state, { user_id = "r2" })
    check("重连快照 me.wall", sent[#sent].data.me.wall == true)
    sent = {}
    rules.broadcast_update(disp, state)
    local seen
    for _, x in ipairs(sent) do
        if x.op == 10 and x.to[1].user_id == "k" then
            for _, o in ipairs(x.data.others) do if o.id == "m" then seen = o.wall end end
        end
    end
    check("广播中阵亡的 m 不显示壁垒", seen ~= true, "wall=" .. tostring(seen))
end

if failures > 0 then
    print(string.format("\n%d check(s) failed", failures))
    os.exit(1)
end
print("\nall dhul wall checks passed")

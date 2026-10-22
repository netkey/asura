-- 阶段衔接 / 超时结算 tick 不得丢客户端消息：Nakama 不重投，match_loop 提前 return 会让该 tick 的消息永久丢失。
-- 全程经 handler.match_loop 驱动。
-- Run: lua5.4 tests/tick_message_drop_test.lua
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
package.path = root .. "/?.lua;" .. package.path

local CLOCK = 1000000
os.time = function() return CLOCK end
local nk = setmetatable({
    json_encode  = function(t) return t end,
    json_decode  = function(s) return type(s) == "table" and s or {} end,
    storage_read = function() return {} end,
    storage_list = function() return {} end,
    match_list   = function() return {} end,
}, { __index = function() return function() end end })
package.loaded["nakama"] = nk
math.randomseed(1)

local handler = require("match_handler")

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("  ok   " .. name)
    else
        failures = failures + 1
        print("  FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
    end
end

local disp = { broadcast_message = function() end, match_label_update = function() end }
local ctx = { match_id = "routing" }

-- match_loop 原地修改 state，对局结束时返回 nil；保留同一引用并标记 ended，便于断言"不该提前结束"
local function tick(state, msgs)
    CLOCK = CLOCK + 1
    if handler.match_loop(ctx, disp, 0, state, msgs or {}) == nil then state.ended = true end
end

local function op(uid, code, data)
    return { op_code = code, sender = { user_id = uid }, data = data }
end

local function card(id, ctype, subtype)
    return { id = id, type = ctype, subtype = subtype, suit = "SPADE", number = 7, name = id }
end

local function has(p, id)
    for _, c in ipairs(p.hand) do if c.id == id then return true end end
    return false
end

-- 2 人 PVP 进入出牌阶段；英雄换成无技能占位，避免被动技能干扰路由断言
local function new_pvp()
    local state = handler.match_init(ctx, { max_players = 2 })
    for i = 1, 2 do
        local pr = { user_id = "p" .. i, username = "p" .. i }
        state = select(1, handler.match_join_attempt(ctx, disp, 0, state, pr, {}))
        state = handler.match_join(ctx, disp, 0, state, { pr })
    end
    state._demo_mode = true
    tick(state, { op("p1", 6, { hero_id = "aladdin" }), op("p2", 6, { hero_id = "sinbad" }) })
    tick(state)  -- 选将完成后下一 tick 才切到 PLAYING
    assert(state.status == 1, "match did not start")
    for _ = 1, 5 do
        if state.pending_action or state.pending_draw_continuation or state.pending_turn_continuation then
            tick(state)
        end
    end
    for _, uid in ipairs({ "p1", "p2" }) do
        local p = state.players[uid]
        p.hero = "test_vanilla"
        p.hand = {}
        p.equipment = {}
        p.delayed_effects = {}
    end
    state.current_turn_id = "p1"
    state.pending_action = nil
    return state, state.players.p1, state.players.p2
end

print("case 1: 摸牌衔接 tick 内出【杀】— 当 tick 生效")
do
    local state, p1, p2 = new_pvp()
    p1.hand = { card("ATK1", "ATTACK") }
    state.pending_draw_continuation = true
    tick(state, { op("p1", 3, { card_id = "ATK1", target_id = "p2" }) })
    local pa = state.pending_action
    check("【杀】已打出", not has(p1, "ATK1"))
    check("目标进入防御询问", pa and pa.type == "WAITING_FOR_DEFENSE" and pa.target_id == "p2",
        pa and pa.type or "no pending")
end

print("case 2: 防御超时结算 tick 内结束回合 — 当 tick 生效")
do
    local state, p1, p2 = new_pvp()
    p1.hand = { card("ATK1", "ATTACK") }
    tick(state, { op("p1", 3, { card_id = "ATK1", target_id = "p2" }) })
    local pa = state.pending_action
    assert(pa and pa.type == "WAITING_FOR_DEFENSE", "setup: expected defense prompt")
    local hp0 = p2.health
    CLOCK = pa.deadline
    tick(state, { op("p1", 4, {}) })
    check("超时结算：目标受 1 点伤害", p2.health == hp0 - 1, string.format("hp %d -> %d", hp0, p2.health))
    check("同 tick 的结束回合生效", state.current_turn_id == "p2", "turn=" .. tostring(state.current_turn_id))
end

if failures > 0 then
    print(string.format("\n%d check(s) failed", failures))
    os.exit(1)
end
print("\nall tick message checks passed")

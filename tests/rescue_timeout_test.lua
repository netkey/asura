-- 濒死超时自动结算：超时代打必须与手动救援同规则——只有【桃】（及英雄技能牌）能救人，酒不能。
-- 回归：手牌 [酒, 桃] 时超时代打选中酒 → 规则层判定不能救 → 直接按放弃处决，桃没被尝试。
-- 全程经 handler.match_loop 驱动，deadline 由推进时钟触发。
-- Run: lua5.4 tests/rescue_timeout_test.lua
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

local function into_rescue(p2_hand)
    local state, p1, p2 = new_pvp()
    p1.hand = { card("ATK1", "ATTACK") }
    p2.health = 1
    p2.hand = p2_hand
    tick(state, { op("p1", 3, { card_id = "ATK1", target_id = "p2" }) })
    tick(state, { op("p2", 5, { confirm = false }) })
    local pa = state.pending_action
    assert(pa and pa.type == "WAITING_FOR_RESCUE" and pa.rescuers[pa.current_rescuer_idx] == "p2",
        "setup: expected self-rescue prompt, got " .. tostring(pa and pa.type))
    CLOCK = pa.deadline
    tick(state)
    return state, p2
end

print("case 1: 手牌 [酒, 桃] 超时 — 用桃自救")
do
    local state, p2 = into_rescue({ card("WINE1", "WINE"), card("HEAL1", "HEAL") })
    check("濒死者存活 hp=1", p2.health == 1, "hp=" .. tostring(p2.health))
    check("对局未结束", not state.ended)
    check("【桃】被消耗", not has(p2, "HEAL1"))
    check("【酒】仍在手", has(p2, "WINE1"))
end

print("case 2: 手牌只有 [酒] 超时 — 不能自救，酒不被消耗")
do
    local state, p2 = into_rescue({ card("WINE1", "WINE") })
    local pa = state.pending_action
    check("未被救回 hp=0", p2.health == 0, "hp=" .. tostring(p2.health))
    check("【酒】未被打出", has(p2, "WINE1"))
    check("救援轮到下一位 p1", pa and pa.type == "WAITING_FOR_RESCUE" and pa.rescuers[pa.current_rescuer_idx] == "p1",
        pa and (pa.type .. " rescuer=" .. tostring(pa.rescuers and pa.rescuers[pa.current_rescuer_idx])) or "no pending")
end

if failures > 0 then
    print(string.format("\n%d check(s) failed", failures))
    os.exit(1)
end
print("\nall rescue timeout checks passed")

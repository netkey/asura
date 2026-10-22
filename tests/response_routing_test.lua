-- 响应路由回归测试：客户端的 op 5 响应必须在发出的当个 tick 被处理，不能静默丢弃、拖到 deadline 超时。
-- 覆盖：濒死自救（发送者 hp<=0）、青龙偃月刀追击、贯石斧强制命中（pending 有 player_id 但无 hero_id）。
-- 全程经 handler.match_loop 驱动，与生产消息路径一致。
-- Run: lua5.4 tests/response_routing_test.lua
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

print("case 1: 濒死自救 — 濒死者(hp=0)出【桃】当 tick 生效")
do
    local state, p1, p2 = new_pvp()
    p1.hand = { card("ATK1", "ATTACK") }
    p2.health = 1
    p2.hand = { card("HEAL1", "HEAL") }
    tick(state, { op("p1", 3, { card_id = "ATK1", target_id = "p2" }) })
    tick(state, { op("p2", 5, { confirm = false }) })
    local pa = state.pending_action
    check("濒死求桃期间对局未提前结束", not state.ended)
    check("进入 WAITING_FOR_RESCUE 且轮到濒死者自救",
        pa and pa.type == "WAITING_FOR_RESCUE" and pa.rescuers[pa.current_rescuer_idx] == "p2",
        pa and (pa.type .. " rescuer=" .. tostring(pa.rescuers and pa.rescuers[pa.current_rescuer_idx])) or "no pending")
    local deadline = pa and pa.deadline or 0
    tick(state, { op("p2", 5, { confirm = true, card_id = "HEAL1" }) })
    check("自救后 hp=1", p2.health == 1, "hp=" .. tostring(p2.health))
    check("【桃】已从手牌移除", not has(p2, "HEAL1"))
    check("未等到 deadline", CLOCK < deadline, string.format("clock=%d deadline=%d", CLOCK, deadline))
end

print("case 2: 青龙偃月刀 — 杀被闪后选择追击当 tick 生效")
do
    local state, p1, p2 = new_pvp()
    p1.equipment.weapon = card("QL", "WEAPON", "reattempt_attack")
    p1.hand = { card("ATK1", "ATTACK"), card("ATK2", "ATTACK") }
    p2.hand = { card("DEF1", "DEFENSE") }
    tick(state, { op("p1", 3, { card_id = "ATK1", target_id = "p2" }) })
    tick(state, { op("p2", 5, { confirm = true, card_id = "DEF1" }) })
    local pa = state.pending_action
    check("出现 WEAPON_QINGLONG_DAO 询问", pa and pa.type == "WEAPON_QINGLONG_DAO", pa and pa.type or "no pending")
    tick(state, { op("p1", 5, { confirm = true, card_id = "ATK2" }) })
    pa = state.pending_action
    check("追击用掉第二张【杀】", not has(p1, "ATK2"))
    check("追击进入目标防御询问", pa and pa.type == "WAITING_FOR_DEFENSE" and pa.target_id == "p2",
        pa and pa.type or "no pending")
end

print("case 3: 贯石斧 — 杀被闪后弃 2 张强制命中当 tick 生效")
do
    local state, p1, p2 = new_pvp()
    p1.equipment.weapon = card("AXE", "WEAPON", "reattempt_discard2")
    p1.hand = { card("ATK1", "ATTACK"), card("X1", "DEFENSE"), card("X2", "DEFENSE") }
    p2.hand = { card("DEF1", "DEFENSE") }
    local hp0 = p2.health
    tick(state, { op("p1", 3, { card_id = "ATK1", target_id = "p2" }) })
    tick(state, { op("p2", 5, { confirm = true, card_id = "DEF1" }) })
    local pa = state.pending_action
    check("出现 WEAPON_CHUANGSHI_FU 询问", pa and pa.type == "WEAPON_CHUANGSHI_FU", pa and pa.type or "no pending")
    tick(state, { op("p1", 5, { confirm = true }) })
    check("目标受到 1 点伤害", p2.health == hp0 - 1, string.format("hp %d -> %d", hp0, p2.health))
    check("攻击者弃掉 2 张牌", #p1.hand == 0, "hand=" .. #p1.hand)
end

print("case 4: 濒死者不能借机结束回合 / 出牌")
do
    local state, _, p2 = new_pvp()
    state.current_turn_id = "p2"
    p2.health = 0
    p2.hand = { card("ATK9", "ATTACK") }
    state.pending_action = {
        type = "WAITING_FOR_RESCUE", dying_player_id = "p2", rescuers = { "p2", "p1" },
        current_rescuer_idx = 1, deadline = CLOCK + 10,
    }
    tick(state, { op("p2", 4, {}), op("p2", 3, { card_id = "ATK9", target_id = "p1" }) })
    check("回合未被切换", state.current_turn_id == "p2", "turn=" .. tostring(state.current_turn_id))
    check("求桃询问仍在", state.pending_action and state.pending_action.type == "WAITING_FOR_RESCUE")
    check("濒死者未能出牌", has(p2, "ATK9"))
end

if failures > 0 then
    print(string.format("\n%d check(s) failed", failures))
    os.exit(1)
end
print("\nall response routing checks passed")

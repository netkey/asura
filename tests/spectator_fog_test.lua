-- 观战迷雾回归测试：进行中的观战者只能拿到公开信息，否则小号观战对手即可场外报点。
-- Run: lua5.4 tests/spectator_fog_test.lua
local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "."
package.path = root .. "/?.lua;" .. package.path

local nk = setmetatable({
    json_encode  = function(t) return t end,
    json_decode  = function(s) return type(s) == "table" and s or {} end,
    storage_read = function() return {} end,
    match_list   = function() return {} end,
}, { __index = function() return function() end end })
package.loaded["nakama"] = nk
math.randomseed(1)

local handler = require("match_handler")
local rules   = require("game_rules")

local failures = 0
local function check(name, cond, detail)
    if cond then
        print("  ok   " .. name)
    else
        failures = failures + 1
        print("  FAIL " .. name .. (detail and ("  -- " .. detail) or ""))
    end
end

local inbox
local disp = {
    broadcast_message = function(op, data, presences)
        for _, pr in ipairs(presences or {}) do
            inbox[pr.user_id] = inbox[pr.user_id] or {}
            table.insert(inbox[pr.user_id], { op = op, data = data })
        end
    end,
    match_label_update = function() end,
}

local function last_state_msg(uid)
    local found
    for _, m in ipairs(inbox[uid] or {}) do
        if m.op == 10 then found = m.data end
    end
    return found
end

-- 5 人身份局开局，返回 state 和指定身份的玩家 id
local function new_match()
    inbox = {}
    local ctx = { match_id = "m1" }
    local state = handler.match_init(ctx, { max_players = 5 })
    local heroes = { "aladdin", "sinbad", "rumi", "hakim", "jafar" }
    for i = 1, 5 do
        state = handler.match_join(ctx, disp, 0, state, { { user_id = "p" .. i, username = "p" .. i } })
    end
    for i = 1, 5 do state.players["p" .. i].hero = heroes[i] end
    state.status = 1
    state.current_turn_id = state.monarch_id or "p1"
    rules.start_game(disp, state)
    return ctx, state
end

local function find_player(state, want_monarch)
    for i = 1, 5 do
        local uid = "p" .. i
        if (state.players[uid].role == "MONARCH") == want_monarch then return uid end
    end
end

local function join_spectator(ctx, state, target_id)
    local spec = { user_id = "spec", username = "spec" }
    local ok
    state, ok = handler.match_join_attempt(ctx, disp, 0, state, spec, { is_spectator = true, target_player_id = target_id })
    assert(ok, "spectator join_attempt rejected")
    inbox = {}
    state = handler.match_join(ctx, disp, 0, state, { spec })
    return state
end

local function others_fogged(view, state)
    for _, o in ipairs(view.others or {}) do
        local p = state.players[o.id]
        if p.role ~= "MONARCH" and p.health > 0 and o.role ~= "UNKNOWN" then return false, o.id end
    end
    return true
end

print("case 1: 进行中观战存活的非主公目标（加入时快照）")
do
    local ctx, state = new_match()
    local target = find_player(state, false)
    state = join_spectator(ctx, state, target)
    local v = last_state_msg("spec")
    check("收到 OpCode 10 快照", v ~= nil)
    v = v or { me = {} }
    check("不含目标手牌", v.me.hand == nil, v.me.hand and (#v.me.hand .. " cards leaked"))
    check("目标身份为 UNKNOWN", v.me.role == "UNKNOWN", "got " .. tostring(v.me.role))
    check("给出手牌数", v.me.hand_count == #state.players[target].hand, "got " .. tostring(v.me.hand_count))
    check("others 遵守迷雾", others_fogged(v, state))
end

print("case 2: 进行中观战存活的非主公目标（后续 broadcast_update）")
do
    local ctx, state = new_match()
    local target = find_player(state, false)
    state = join_spectator(ctx, state, target)
    inbox = {}
    rules.broadcast_update(disp, state)
    local v = last_state_msg("spec") or { me = {} }
    check("不含目标手牌", v.me.hand == nil, v.me.hand and (#v.me.hand .. " cards leaked"))
    check("目标身份为 UNKNOWN", v.me.role == "UNKNOWN", "got " .. tostring(v.me.role))
    check("给出手牌数", v.me.hand_count == #state.players[target].hand, "got " .. tostring(v.me.hand_count))
    check("others 遵守迷雾", others_fogged(v, state))
end

print("case 3: 观战存活的主公 — 身份公开，手牌仍隐藏")
do
    local ctx, state = new_match()
    local target = find_player(state, true)
    state = join_spectator(ctx, state, target)
    inbox = {}
    rules.broadcast_update(disp, state)
    local v = last_state_msg("spec") or { me = {} }
    check("身份为 MONARCH", v.me.role == "MONARCH", "got " .. tostring(v.me.role))
    check("不含目标手牌", v.me.hand == nil)
end

print("case 4: 目标阵亡后解锁完整视野")
do
    local ctx, state = new_match()
    local target = find_player(state, false)
    state = join_spectator(ctx, state, target)
    state.players[target].health = 0
    inbox = {}
    rules.broadcast_update(disp, state)
    local v = last_state_msg("spec") or { me = {} }
    check("身份可见", v.me.role == state.players[target].role, "got " .. tostring(v.me.role))
    check("手牌可见", type(v.me.hand) == "table" and #v.me.hand == #state.players[target].hand)
end

print("case 5: 对局结束后解锁完整视野")
do
    local ctx, state = new_match()
    local target = find_player(state, false)
    state = join_spectator(ctx, state, target)
    state.status = 2
    inbox = {}
    rules.broadcast_update(disp, state)
    local v = last_state_msg("spec") or { me = {} }
    check("身份可见", v.me.role == state.players[target].role, "got " .. tostring(v.me.role))
    check("手牌可见", type(v.me.hand) == "table" and #v.me.hand == #state.players[target].hand)
end

if failures > 0 then
    print(string.format("\n%d check(s) failed", failures))
    os.exit(1)
end
print("\nall spectator fog checks passed")

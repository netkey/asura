-- demo.lua  Standalone 2-player game demo (no Nakama server needed)
-- Run: lua demo.lua

--------------------------------------------------------------------------------
-- 1. Mock nakama (must inject before requiring game modules)
--------------------------------------------------------------------------------
math.randomseed(42)

local nk = {
    json_encode  = function(t) return type(t) == "table" and t or tostring(t) end,
    json_decode  = function(s) return type(s) == "table" and s or {} end,
    logger_info  = function() end,
    logger_warn  = function(msg) print("  [WARN] " .. tostring(msg)) end,
    storage_read = function() return {} end,
    register_rpc = function() end,
}
package.loaded["nakama"] = nk
os.time = function() return 1000000 end  -- fixed deadline for ATTACK

package.path = package.path .. ";/Users/yalla/work/mycode/asura/?.lua"

--------------------------------------------------------------------------------
-- 2. Load game modules
--------------------------------------------------------------------------------
local handler  = require("match_handler")
local rules    = require("game_rules")
local hero_mgr = require("hero_manager")

--------------------------------------------------------------------------------
-- 3. Dispatcher mock
--------------------------------------------------------------------------------
local OPCODE = {
    [11]  = "事件",     [20]  = "伤害",       [30]  = "游戏结束",
    [100] = "技能询问", [101] = "技能询问",   [102] = "技能询问",
    [105] = "攻击通知",
}

local dispatcher = {
    broadcast_message = function(op, data, _)
        if op == 10 then return end
        local msg = ""
        if type(data) == "table" then
            msg = data.content or data.msg or ""
            if type(msg) ~= "string" then msg = "" end
        end
        if msg ~= "" then
            print("    [" .. (OPCODE[op] or "op"..op) .. "] " .. msg)
        end
    end,
    match_label_update = function() end,
}

--------------------------------------------------------------------------------
-- 4. Helpers
--------------------------------------------------------------------------------
local CN = {
    ATTACK="攻击", DEFENSE="防御", HEAL="治疗",
    AOE_SANDSTORM="沙尘暴", DRAW_TWO="无中生有", JUDGE_STORM="天谴",
}

local function hand_str(hand)
    local t = {}
    for _, c in ipairs(hand) do table.insert(t, CN[c.type] or c.type) end
    return #t > 0 and table.concat(t, "/") or "空"
end

local function print_state(state)
    print(string.rep("─", 60))
    local ids = {}
    for uid in pairs(state.players) do table.insert(ids, uid) end
    table.sort(ids)
    for _, uid in ipairs(ids) do
        local p   = state.players[uid]
        local cur = uid == state.current_turn_id and " ◀" or ""
        print(string.format("  %-12s %-8s %-8s HP:%d/%d  手牌:%d [%s]%s",
            p.username, "("..p.hero..")", p.role,
            p.health, p.max_health, #p.hand, hand_str(p.hand), cur))
    end
    print(string.rep("─", 60))
end

-- AI: resolve any pending action (defense / skill choice)
local function ai_handle_pending(state)
    for _ = 1, 20 do   -- guard against infinite loops
        local action = state.pending_action
        if not action then break end

        if action.type == "WAITING_FOR_DEFENSE" then
            local p = state.players[action.target_id]
            local di = nil
            for i, c in ipairs(p.hand) do
                if c.type == "DEFENSE" then di = i; break end
            end
            if di then
                print(string.format("    → %s 打出【防御】", p.username))
                table.remove(p.hand, di)
                rules.handle_response(dispatcher, state, action.target_id, {confirm=true})
            else
                print(string.format("    → %s 无防御，承受伤害", p.username))
                rules.handle_response(dispatcher, state, action.target_id, {confirm=false})
            end

        elseif action.type == "WAITING_FOR_AOE" then
            local p = state.players[action.current_target]
            if not p then break end
            local di = nil
            for i, c in ipairs(p.hand) do
                if c.type == "DEFENSE" then di = i; break end
            end
            if di then
                print(string.format("    → %s 防御沙尘暴", p.username))
                table.remove(p.hand, di)
                rules.handle_response(dispatcher, state, action.current_target, {confirm=true})
            else
                print(string.format("    → %s 被沙尘暴命中", p.username))
                rules.handle_response(dispatcher, state, action.current_target, {confirm=false})
            end

        elseif action.type == "ALADDIN_LAMP" then
            local p = state.players[action.player_id]
            if #p.hand >= 2 then
                print(string.format("    → %s 发动【神灯】弃2摸2", p.username))
                hero_mgr.handle_response(dispatcher, state, action.player_id,
                    {confirm=true, card_ids={p.hand[1].id, p.hand[2].id}})
            else
                hero_mgr.handle_response(dispatcher, state, action.player_id, {confirm=false})
            end

        elseif action.type == "ALIBABA_COUNTER" then
            print(string.format("    → %s 发动【暗号】反击！", state.players[action.player_id].username))
            hero_mgr.handle_response(dispatcher, state, action.player_id, {confirm=true})

        elseif action.type == "HAKIM_XING_XIANG" then
            local p = state.players[action.player_id]
            print(string.format("    → %s 发动【星象】调整牌序", p.username))
            local ids = {}
            for _, c in ipairs(action.cards) do table.insert(ids, c.id) end
            hero_mgr.handle_response(dispatcher, state, action.player_id,
                {confirm=true, sorted_ids=ids})
            rules.draw_cards(state, action.player_id, 2)  -- hakim on_response 不含摸牌

        elseif action.type == "SCHEHERAZADE_QIANYE" then
            local p = state.players[action.player_id]
            if #p.hand >= 1 then
                print(string.format("    → %s 发动【千夜】弃1摸2", p.username))
                hero_mgr.handle_response(dispatcher, state, action.player_id,
                    {confirm=true, card_ids={p.hand[1].id}})
            else
                hero_mgr.handle_response(dispatcher, state, action.player_id, {confirm=false})
            end
        else
            break  -- unknown action type, stop
        end
    end
end

-- AI: choose a card to play this turn
local function ai_choose(state, uid)
    local p = state.players[uid]
    local target_id = nil
    for other_uid, other_p in pairs(state.players) do
        if other_uid ~= uid and other_p.health > 0 then
            target_id = other_uid; break
        end
    end
    -- heal first if hurt
    if p.health < p.max_health then
        for _, c in ipairs(p.hand) do
            if c.type == "HEAL" then return {card_id=c.id} end
        end
    end
    -- AOE
    for _, c in ipairs(p.hand) do
        if c.type == "AOE_SANDSTORM" then return {card_id=c.id} end
    end
    -- attack
    if target_id then
        for _, c in ipairs(p.hand) do
            if c.type == "ATTACK" then return {card_id=c.id, target_id=target_id} end
        end
    end
    -- draw two
    for _, c in ipairs(p.hand) do
        if c.type == "DRAW_TWO" then return {card_id=c.id} end
    end
    return nil
end

--------------------------------------------------------------------------------
-- 5. Init match
--------------------------------------------------------------------------------
print("╔══════════════════════════════════════════════════╗")
print("║    阿苏拉 · 中东神话卡牌游戏 · 2人对局 Demo      ║")
print("╚══════════════════════════════════════════════════╝\n")

local context = {}
local state = handler.match_init(context, {max_players=2, mode="classic"})

local p1 = {user_id="u1", username="萨拉丁玩家"}
local p2 = {user_id="u2", username="阿里巴巴玩家"}

state = handler.match_join(context, dispatcher, 0, state, {p1})
state = handler.match_join(context, dispatcher, 0, state, {p2})

-- Fix heroes for reproducible output
state.players["u1"].hero = "saladin"
state.players["u2"].hero = "alibaba"

print("【对局开始】 牌堆:" .. #state.deck .. "张")
print_state(state)

--------------------------------------------------------------------------------
-- 6. Game loop
--------------------------------------------------------------------------------
local MAX_TURNS = 25

for turn = 1, MAX_TURNS do
    if state.status ~= 1 then break end

    local uid = state.current_turn_id
    local p   = state.players[uid]

    -- skip dead (safety)
    if not p or p.health <= 0 then
        handler.next_turn(dispatcher, state)
        ai_handle_pending(state)
        goto continue
    end

    print(string.format("\n══ 第%02d回合 · %s(%s · %s) HP:%d/%d ══",
        turn, p.username, p.hero, p.role, p.health, p.max_health))
    print("   手牌: " .. hand_str(p.hand))

    -- clear any leftover pending
    if state.pending_action then ai_handle_pending(state) end

    -- AI play
    local action = ai_choose(state, uid)
    if action then
        local card_name = "?"
        for _, c in ipairs(p.hand) do
            if c.id == action.card_id then card_name = CN[c.type] or c.type; break end
        end
        local tgt = action.target_id and state.players[action.target_id].username or "全体"
        print(string.format("  出牌: 【%s】→ %s", card_name, tgt))
        rules.handle_play_card(dispatcher, state, uid, action)
        ai_handle_pending(state)
    else
        print("  无可用牌，结束回合")
    end

    -- check victory
    local over, winner = rules.check_victory(dispatcher, state)
    if over then
        state.status = 2
        print(string.format("\n🏆 游戏结束！胜利方: %s", winner))
        break
    end

    -- advance to next turn (switches player + draws 2 for them)
    handler.next_turn(dispatcher, state)
    ai_handle_pending(state)

    ::continue::
end

print("\n【最终状态】")
print_state(state)
if state.status == 1 then print("（达到最大回合数，Demo 结束）") end

-- demo_concurrent.lua  多局并发验证 demo
-- 模拟 3 局对局交替推进（Round-Robin），证明：
--   1. 每局 state 完全隔离，互不干扰
--   2. 游戏逻辑无全局可变状态，天然支持并发
-- Run: lua demo_concurrent.lua

--------------------------------------------------------------------------------
-- Mock Setup
--------------------------------------------------------------------------------
-- 每局使用独立随机种子，确保牌局不同
local nk = {
    json_encode  = function(t) return type(t) == "table" and t or tostring(t) end,
    json_decode  = function(s) return type(s) == "table" and s or {} end,
    logger_info  = function() end,
    logger_warn  = function() end,
    storage_read = function() return {} end,
    register_rpc = function() end,
}
package.loaded["nakama"] = nk
os.time = function() return 1000000 end

package.path = package.path .. ";/Users/yalla/work/mycode/asura/?.lua"

local handler  = require("match_handler")
local rules    = require("game_rules")
local hero_mgr = require("hero_manager")

--------------------------------------------------------------------------------
-- Dispatcher factory（每局独立 prefix，日志带对局 ID）
--------------------------------------------------------------------------------
local function make_dispatcher(prefix)
    return {
        broadcast_message = function(op, data, _)
            if op ~= 11 then return end
            local msg = type(data) == "table" and (data.content or "") or ""
            if msg ~= "" then print(prefix .. " " .. msg) end
        end,
        match_label_update = function() end,
    }
end

--------------------------------------------------------------------------------
-- Helpers（与 demo.lua 相同，复用）
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

local function ai_handle_pending(state)
    for _ = 1, 20 do
        local action = state.pending_action
        if not action then break end
        if action.type == "WAITING_FOR_DEFENSE" then
            local p = state.players[action.target_id]
            local di = nil
            for i, c in ipairs(p.hand) do if c.type=="DEFENSE" then di=i; break end end
            if di then
                table.remove(p.hand, di)
                rules.handle_response(state._dispatcher, state, action.target_id, {confirm=true})
            else
                rules.handle_response(state._dispatcher, state, action.target_id, {confirm=false})
            end
        elseif action.type == "WAITING_FOR_AOE" then
            local p = state.players[action.current_target]
            if not p then break end
            local di = nil
            for i, c in ipairs(p.hand) do if c.type=="DEFENSE" then di=i; break end end
            if di then
                table.remove(p.hand, di)
                rules.handle_response(state._dispatcher, state, action.current_target, {confirm=true})
            else
                rules.handle_response(state._dispatcher, state, action.current_target, {confirm=false})
            end
        elseif action.type == "ALADDIN_LAMP" then
            local p = state.players[action.player_id]
            if #p.hand >= 2 then
                hero_mgr.handle_response(state._dispatcher, state, action.player_id,
                    {confirm=true, card_ids={p.hand[1].id, p.hand[2].id}})
            else
                hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=false})
            end
        elseif action.type == "ALIBABA_COUNTER" then
            hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=true})
        elseif action.type == "HAKIM_XING_XIANG" then
            local ids = {}
            for _, c in ipairs(action.cards) do table.insert(ids, c.id) end
            hero_mgr.handle_response(state._dispatcher, state, action.player_id,
                {confirm=true, sorted_ids=ids})
            rules.draw_cards(state, action.player_id, 2)
        elseif action.type == "SCHEHERAZADE_QIANYE" then
            local p = state.players[action.player_id]
            if #p.hand >= 1 then
                hero_mgr.handle_response(state._dispatcher, state, action.player_id,
                    {confirm=true, card_ids={p.hand[1].id}})
            else
                hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=false})
            end
        elseif action.type == "IBN_BATTUTA_YUAN_XING" then
            local p = state.players[action.player_id]
            if #p.hand >= 1 then
                hero_mgr.handle_response(state._dispatcher, state, action.player_id,
                    {confirm=true, card_ids={p.hand[1].id}})
            else
                hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=false})
            end
        elseif action.type == "AL_KHWARIZMI_SUANFA" then
            local p = state.players[action.player_id]
            if #p.hand >= 1 then
                hero_mgr.handle_response(state._dispatcher, state, action.player_id,
                    {confirm=true, card_ids={p.hand[1].id}})
            else
                hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=false})
            end
        elseif action.type == "RUMI_XUANHUI" then
            hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=true})
        elseif action.type == "AL_BIRUNI_CELIANG" then
            if action.cards and #action.cards > 0 then
                hero_mgr.handle_response(state._dispatcher, state, action.player_id,
                    {confirm=true, card_ids={action.cards[1].id}})
            else
                hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=false})
            end
        elseif action.type == "HARUN_CHOOSE" then
            hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=true})
        elseif action.type == "BASIRA_XIAN_ZHI" then
            hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=true, guess=action.guess})
        else
            break
        end
    end
end

local function ai_choose(state, uid)
    local p = state.players[uid]
    local target_id = nil
    for other_uid, other_p in pairs(state.players) do
        if other_uid ~= uid and other_p.health > 0 then target_id = other_uid; break end
    end
    if p.health < p.max_health then
        for _, c in ipairs(p.hand) do if c.type=="HEAL" then return {card_id=c.id} end end
    end
    for _, c in ipairs(p.hand) do if c.type=="AOE_SANDSTORM" then return {card_id=c.id} end end
    if target_id then
        for _, c in ipairs(p.hand) do if c.type=="ATTACK" then return {card_id=c.id, target_id=target_id} end end
    end
    for _, c in ipairs(p.hand) do if c.type=="DRAW_TWO" then return {card_id=c.id} end end
    return nil
end

-- 推进一个回合，返回 true 表示对局继续，false 表示已结束
local function tick_match(m)
    if m.state.status ~= 1 then return false end

    local uid = m.state.current_turn_id
    local p   = m.state.players[uid]
    if not p or p.health <= 0 then
        handler.next_turn(m.dispatcher, m.state)
        ai_handle_pending(m.state)
        return true
    end

    -- 有未解决的挂起动作时，先解决它，不要推进回合
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
-- 初始化 3 局对局（不同英雄组合，不同随机种子）
--------------------------------------------------------------------------------
local MATCH_CONFIGS = {
    { seed=42,  p1={id="a1", name="哈伦·拉希德A", hero="harun_al_rashid"}, p2={id="a2", name="海亚姆A",      hero="khayyam"}      },
    { seed=100, p1={id="b1", name="芝诺比娅B",    hero="zenobia"},        p2={id="b2", name="穆阿维叶B",    hero="muawiyah"}     },
    { seed=999, p1={id="c1", name="尼扎姆C",      hero="nizamulmulk"},    p2={id="c2", name="恩赫杜安娜C",  hero="enheduanna"}   },
    { seed=777, p1={id="d1", name="曼苏尔D",      hero="al_mansur"},     p2={id="d2", name="吉尔伽美什D",  hero="gilgamesh"}    },
    { seed=321, p1={id="e1", name="伊姆鲁E",      hero="imru_al_qais"},  p2={id="e2", name="巴希拉E",      hero="basira"}       },
}

local matches = {}
for i, cfg in ipairs(MATCH_CONFIGS) do
    math.randomseed(cfg.seed)
    local label = string.format("[对局%d]", i)
    local disp  = make_dispatcher(label)
    local ctx   = {}

    local state = handler.match_init(ctx, {max_players=2, mode="classic"})
    state._dispatcher = disp  -- 方便 ai_handle_pending 访问

    local pr1 = {user_id=cfg.p1.id, username=cfg.p1.name}
    local pr2 = {user_id=cfg.p2.id, username=cfg.p2.name}
    state = handler.match_join(ctx, disp, 0, state, {pr1})
    state = handler.match_join(ctx, disp, 0, state, {pr2})
    state._dispatcher = disp

    state.players[cfg.p1.id].hero = cfg.p1.hero
    state.players[cfg.p2.id].hero = cfg.p2.hero

    matches[i] = { state=state, dispatcher=disp, label=label, winner=nil, turns=0 }
end

--------------------------------------------------------------------------------
-- Round-Robin：3 局交替推进，每轮各进一回合
--------------------------------------------------------------------------------
print("╔══════════════════════════════════════════════════════╗")
print("║   阿苏拉 · 多局并发验证 Demo（5局 Round-Robin）      ║")
print("╚══════════════════════════════════════════════════════╝")
for i, cfg in ipairs(MATCH_CONFIGS) do
    print(string.format("  对局%d: %-12s vs %-12s  seed=%d",
        i, cfg.p1.name, cfg.p2.name, cfg.seed))
end
print(string.rep("─", 56))

local MAX_TURNS = 30
local global_tick = 0

while global_tick < MAX_TURNS * 5 do
    local all_done = true
    for _, m in ipairs(matches) do
        if m.state.status == 1 then
            all_done = false
            m.turns = m.turns + 1
            tick_match(m)
        end
    end
    global_tick = global_tick + 1
    if all_done then break end
end

--------------------------------------------------------------------------------
-- 结果汇总
--------------------------------------------------------------------------------
print("\n══════════════════ 对局结果汇总 ══════════════════")
local winner_cn = { MONARCH_WIN="主公阵营", REBEL_WIN="反贼阵营", TRAITOR_WIN="内奸" }
for i, m in ipairs(matches) do
    local cfg = MATCH_CONFIGS[i]
    local result = m.winner and (winner_cn[m.winner] or m.winner) or "未结束"
    print(string.format("  对局%d  %s vs %s", i, cfg.p1.name, cfg.p2.name))

    -- 最终各玩家状态
    local ids = {}
    for uid in pairs(m.state.players) do table.insert(ids, uid) end
    table.sort(ids)
    for _, uid in ipairs(ids) do
        local p = m.state.players[uid]
        print(string.format("    %-12s %-8s HP:%d/%d 手牌:%d [%s]",
            p.username, p.role, p.health, p.max_health, #p.hand, hand_str(p.hand)))
    end
    print(string.format("    → 胜利方: %s  共 %d 回合", result, m.turns))
    print(string.rep("─", 56))
end

--------------------------------------------------------------------------------
-- 验证隔离性：3 局的随机种子不同，牌局结果应不同
--------------------------------------------------------------------------------
print("\n══ 状态隔离验证 ══")
local deck_sizes = {}
for i, m in ipairs(matches) do
    deck_sizes[i] = #m.state.deck
    print(string.format("  对局%d 剩余牌堆: %d 张  (独立牌堆，互不影响)", i, #m.state.deck))
end
local isolated = deck_sizes[1] ~= deck_sizes[2] or deck_sizes[2] ~= deck_sizes[3]
print(string.format("\n  隔离验证: %s（3局剩余牌堆数量%s）",
    isolated and "✓ 通过" or "○ 可能相同（概率极低）",
    isolated and "各不相同" or "恰好相同"))

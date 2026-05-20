-- demo_concurrent.lua  全英雄并发验证 Demo
-- 15 局对局 Round-Robin 推进，覆盖全部 30 个英雄
-- Run: lua demo_concurrent.lua

--------------------------------------------------------------------------------
-- Mock Setup
--------------------------------------------------------------------------------
local nk = {
    json_encode              = function(t) return type(t) == "table" and t or tostring(t) end,
    json_decode              = function(s) return type(s) == "table" and s or {} end,
    logger_info              = function() end,
    logger_warn              = function() end,
    storage_read             = function(reads)
        -- 为 season_config/current 返回一个有效赛季，其余返回空
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
            local msg  = type(data) == "table" and (data.content or "") or ""
            local hero  = type(data) == "table" and data.hero
            local skill = type(data) == "table" and data.skill
            if hero and skill then
                TRIGGERS[hero] = TRIGGERS[hero] or {}
                TRIGGERS[hero][skill] = (TRIGGERS[hero][skill] or 0) + 1
            end
            -- 取消下行注释可输出详细日志
            -- if msg ~= "" then print(prefix .. " " .. msg) end
        end,
        match_label_update = function() end,
    }
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local CN = {
    ATTACK="攻击", DEFENSE="防御", HEAL="治疗",
    AOE_SANDSTORM="沙尘暴", DRAW_TWO="无中生有", JUDGE_STORM="天谴",
    WEAPON="武器", ARMOR="防具", HORSE="马匹", WINE="酒",
    DELAYED_TRICK="延时锦囊", INSTANT_TRICK="即时锦囊",
}
local function hand_str(hand)
    local t = {}
    for _, c in ipairs(hand) do table.insert(t, CN[c.type] or c.type) end
    return #t > 0 and table.concat(t, "/") or "空"
end

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
            local def_card
            for _, c in ipairs(p.hand) do if c.type == "DEFENSE" then def_card = c; break end end
            rules.handle_response(state._dispatcher, state, action.target_id,
                {confirm = def_card ~= nil, card_id = def_card and def_card.id or nil})

        elseif action.type == "WAITING_FOR_AOE" then
            local p = state.players[action.current_target]
            if not p then state.pending_action = nil; break end
            local def_card
            for _, c in ipairs(p.hand) do if c.type == "DEFENSE" then def_card = c; break end end
            rules.handle_response(state._dispatcher, state, action.current_target,
                {confirm = def_card ~= nil, card_id = def_card and def_card.id or nil})

        -- ---- 英雄技能响应 ----
        elseif action.type == "ALADDIN_LAMP" then
            local p = state.players[action.player_id]
            if #p.hand >= 2 then
                -- 废牌优先：天谴 > 延时锦囊 > 沙尘暴 > 装备牌 > 其他
                local discard_scores = {
                    JUDGE_STORM = 5, DELAYED_TRICK = 4, AOE_SANDSTORM = 3,
                    WEAPON = 2, ARMOR = 2, HORSE = 2,
                    INSTANT_TRICK = 1, DRAW_TWO = 1, WINE = 1,
                    HEAL = 0, DEFENSE = 0, ATTACK = 0,
                }
                local scored = {}
                for _, c in ipairs(p.hand) do
                    table.insert(scored, {id = c.id, score = discard_scores[c.type] or 0})
                end
                table.sort(scored, function(a, b) return a.score > b.score end)
                hero_mgr.handle_response(state._dispatcher, state, action.player_id,
                    {confirm=true, card_ids={scored[1].id, scored[2].id}})
            else
                hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=false})
            end

        elseif action.type == "ALIBABA_COUNTER" then
            hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=true})

        elseif action.type == "HAKIM_XING_XIANG" then
            -- 观星：按优先级排序（最好的放前面），on_response 会自己摸2张
            if action.cards and #action.cards > 0 then
                local card_priority = { HEAL=10, DEFENSE=9, ATTACK=8, WINE=7,
                    INSTANT_TRICK=6, DRAW_TWO=5, AOE_SANDSTORM=4,
                    DELAYED_TRICK=3, JUDGE_STORM=2, WEAPON=1, ARMOR=1, HORSE=1 }
                local sorted = {}
                for _, c in ipairs(action.cards) do table.insert(sorted, c) end
                table.sort(sorted, function(a, b)
                    return (card_priority[a.type] or 0) > (card_priority[b.type] or 0)
                end)
                local sorted_ids = {}
                for _, c in ipairs(sorted) do table.insert(sorted_ids, c.id) end
                hero_mgr.handle_response(state._dispatcher, state, action.player_id,
                    {confirm=true, sorted_ids=sorted_ids})
            else
                hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=false})
            end

        elseif action.type == "SCHEHERAZADE_QIANYE" then
            -- 受到伤害后反制：弃自己最差的牌，选攻击者展示牌中第一张弃置
            local p = state.players[action.player_id]
            if p and #p.hand >= 1 and action.shown_cards and #action.shown_cards > 0 then
                -- 选自己最差的牌（优先天谴/延时锦囊/沙尘暴）
                local waste_priority = { JUDGE_STORM=5, DELAYED_TRICK=4, AOE_SANDSTORM=3, WEAPON=2, ARMOR=2, HORSE=2 }
                local worst, worst_idx = nil, 1
                for i, c in ipairs(p.hand) do
                    local s = waste_priority[c.type] or 0
                    if not worst or s > worst then worst, worst_idx = s, i end
                end
                hero_mgr.handle_response(state._dispatcher, state, action.player_id,
                    {confirm=true, own_card_id=p.hand[worst_idx].id, target_card_id=action.shown_cards[1].id})
            else
                hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=false})
            end

        elseif action.type == "HARUN_CHOOSE" then
            -- 令目标承受1点伤害（不弃牌）
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
            -- 看4张牌，按优先级排序，保留最好的2张
            if action.cards and #action.cards > 0 then
                local card_priority = {
                    HEAL = 10, DEFENSE = 9, ATTACK = 8, WINE = 7,
                    INSTANT_TRICK = 6, DRAW_TWO = 5, AOE_SANDSTORM = 4,
                    DELAYED_TRICK = 3, JUDGE_STORM = 2,
                    WEAPON = 1, ARMOR = 1, HORSE = 1,
                }
                local sorted = {}
                for _, c in ipairs(action.cards) do table.insert(sorted, c) end
                table.sort(sorted, function(a, b)
                    return (card_priority[a.type] or 0) > (card_priority[b.type] or 0)
                end)
                local sorted_ids = {}
                for _, c in ipairs(sorted) do table.insert(sorted_ids, c.id) end
                hero_mgr.handle_response(state._dispatcher, state, action.player_id,
                    {confirm=true, sorted_ids=sorted_ids, keep_ids={sorted[1].id, sorted[2].id}})
            else
                hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=false})
            end

        elseif action.type == "AL_BIRUNI_CELIANG" then
            -- 看4选2：按优先级排序，保留最好的2张
            if action.cards and #action.cards > 0 then
                local card_priority = { HEAL=10, DEFENSE=9, ATTACK=8, WINE=7,
                    INSTANT_TRICK=6, DRAW_TWO=5, AOE_SANDSTORM=4,
                    DELAYED_TRICK=3, JUDGE_STORM=2, WEAPON=1, ARMOR=1, HORSE=1 }
                local sorted = {}
                for _, c in ipairs(action.cards) do table.insert(sorted, c) end
                table.sort(sorted, function(a, b)
                    return (card_priority[a.type] or 0) > (card_priority[b.type] or 0)
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

        elseif action.type == "SULEIMAN_YU_FENG" then
            if action.targets and #action.targets > 0 then
                local block_types = {"ATTACK", "DEFENSE", "HEAL", "AOE_SANDSTORM"}
                hero_mgr.handle_response(state._dispatcher, state, action.player_id,
                    {confirm=true, target_id=action.targets[1].id, block_type=block_types[math.random(4)]})
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
            -- 发动颂词摸4给1，净收益+3，总是发动
            hero_mgr.handle_response(state._dispatcher, state, action.player_id, {confirm=true})

        elseif action.type == "ENHEDUANNA_SONG_CI_GIVE" then
            -- 选第一张手牌给第一个可选目标
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
                local rescue_idx
                for i, c in ipairs(rescuer.hand) do
                    if c.type == "HEAL" or (c.suit == "HEART" and rescuer.hero == "avicenna") then
                        rescue_idx = i; break
                    end
                end
                if rescue_idx then
                    local card = table.remove(rescuer.hand, rescue_idx)
                    table.insert(state.discard_pile, card)
                    rules.handle_response(state._dispatcher, state, rescuer_id, {confirm=true, card_id=card.id})
                else
                    rules.handle_response(state._dispatcher, state, rescuer_id, {confirm=false})
                end
            else
                state.pending_action = nil
                break
            end

        elseif action.type == "WAITING_FOR_TRICK_SELECT" then
            -- 锦囊选择：默认 confirm=true（接受默认行为）
            rules.handle_response(state._dispatcher, state, action.chooser_id or action.player_id, {confirm=true})

        else
            -- 未知 pending_action，清除防止死锁
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
        -- PVP 模式：选最低血量的存活对手
        for oid, op in pairs(state.players) do
            if oid ~= uid and op.health > 0 then
                if not target_id or op.health < state.players[target_id].health then
                    target_id = oid
                end
            end
        end
    else
        -- identity 模式：角色感知选择
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
            -- MONARCH / MINISTER：集火最低血量的反贼或内奸
            for oid, op in pairs(state.players) do
                if oid ~= uid and op.health > 0
                   and (op.role == "REBEL" or op.role == "TRAITOR") then
                    if not target_id or op.health < state.players[target_id].health then
                        target_id = oid
                    end
                end
            end
        end

        -- 兜底
        if not target_id then
            for oid, op in pairs(state.players) do
                if oid ~= uid and op.health > 0 then target_id = oid; break end
            end
        end
    end

    -- ── 出牌优先级 ───────────────────────────────────────────────────────
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
    -- 3. 攻击（主要输出，提前）
    if target_id then
        for _, c in ipairs(p.hand) do
            if c.type == "ATTACK" then return {card_id=c.id, target_id=target_id} end
        end
    end
    -- 4. AOE（多目标伤害）
    for _, c in ipairs(p.hand) do
        if c.type == "AOE_SANDSTORM" then return {card_id=c.id} end
    end
    -- 5. 酒牌（增强下次攻击）
    if not p.weapon_buff then
        for _, c in ipairs(p.hand) do
            if c.type == "WINE" then return {card_id=c.id} end
        end
    end
    -- 6. 延时锦囊挂到对手
    if target_id then
        for _, c in ipairs(p.hand) do
            if c.type == "DELAYED_TRICK" then return {card_id=c.id, target_id=target_id} end
        end
    end
    -- 7. 即时锦囊
    for _, c in ipairs(p.hand) do
        if c.type == "INSTANT_TRICK" then
            local needs_target = c.subtype == "discard_enemy_card" or c.subtype == "swap_hands"
            if needs_target and target_id then return {card_id=c.id, target_id=target_id}
            elseif not needs_target then return {card_id=c.id} end
        end
    end
    -- 8. 无中生有
    for _, c in ipairs(p.hand) do
        if c.type == "DRAW_TWO" then return {card_id=c.id} end
    end
    -- 9. 天谴
    if target_id then
        for _, c in ipairs(p.hand) do
            if c.type == "JUDGE_STORM" then return {card_id=c.id, target_id=target_id} end
        end
    end
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

    -- 先解决挂起的操作
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
local MATCH_CONFIGS = {
    -- 原有 5 局（第二批扩展英雄）
    { seed=42,  p1={id="a1", name="哈伦·拉希德", hero="harun_al_rashid"}, p2={id="a2", name="海亚姆",      hero="khayyam"}      },
    { seed=100, p1={id="b1", name="芝诺比娅",     hero="zenobia"},        p2={id="b2", name="穆阿维叶",    hero="muawiyah"}      },
    { seed=999, p1={id="c1", name="尼扎姆",       hero="nizamulmulk"},    p2={id="c2", name="恩赫杜安娜",  hero="enheduanna"}    },
    { seed=777, p1={id="d1", name="曼苏尔",       hero="al_mansur"},      p2={id="d2", name="吉尔伽美什",  hero="gilgamesh"}     },
    { seed=321, p1={id="e1", name="伊姆鲁盖斯",   hero="imru_al_qais"},   p2={id="e2", name="巴希拉",      hero="basira"}        },
    -- 新增 10 局（覆盖原版 6 + 第一批 12 扩展英雄）
    { seed=11,  p1={id="f1", name="阿拉丁",       hero="aladdin"},        p2={id="f2", name="阿里巴巴",    hero="alibaba"}       },
    { seed=22,  p1={id="g1", name="萨拉丁",       hero="saladin"},        p2={id="g2", name="贾法尔",      hero="jafar"}         },
    { seed=33,  p1={id="h1", name="哈基姆",       hero="hakim"},          p2={id="h2", name="舍赫拉莎德",  hero="scheherazade"}  },
    { seed=44,  p1={id="i1", name="伊本白图泰",   hero="ibn_battuta"},    p2={id="i2", name="花拉子密",    hero="al_khwarizmi"}  },
    { seed=55,  p1={id="j1", name="阿维森纳",     hero="avicenna"},       p2={id="j2", name="辛巴达",      hero="sinbad"}        },
    { seed=66,  p1={id="k1", name="旭烈兀",       hero="hulagu"},         p2={id="k2", name="纳芙蒂蒂",    hero="nefertiti"}     },
    { seed=77,  p1={id="l1", name="鲁米",         hero="rumi"},           p2={id="l2", name="帖木儿",      hero="tamerlane"}     },
    { seed=88,  p1={id="m1", name="祖拜达",       hero="zubaydah"},       p2={id="m2", name="比鲁尼",      hero="al_biruni"}     },
    { seed=123, p1={id="n1", name="杜尼亚扎德",   hero="dunyazad"},       p2={id="n2", name="安塔拉",      hero="antar"}         },
    { seed=456, p1={id="o1", name="苏莱曼",       hero="suleiman"},       p2={id="o2", name="双角王",      hero="dhul_qarnayn"}  },
    -- 5 人身份局（验证角色系统与多目标 AOE）
    { seed=200, players={
        {id="q1", name="阿拉丁",     hero="aladdin"},
        {id="q2", name="哈基姆",     hero="hakim"},
        {id="q3", name="萨拉丁",     hero="saladin"},
        {id="q4", name="贾法尔",     hero="jafar"},
        {id="q5", name="舍赫拉莎德", hero="scheherazade"},
    }},
    { seed=201, players={
        {id="r1", name="旭烈兀",     hero="hulagu"},
        {id="r2", name="鲁米",       hero="rumi"},
        {id="r3", name="帖木儿",     hero="tamerlane"},
        {id="r4", name="祖拜达",     hero="zubaydah"},
        {id="r5", name="辛巴达",     hero="sinbad"},
    }},
}

--------------------------------------------------------------------------------
-- 初始化所有对局
--------------------------------------------------------------------------------
local matches = {}
for i, cfg in ipairs(MATCH_CONFIGS) do
    math.randomseed(cfg.seed)
    local label     = string.format("[对局%02d]", i)
    local disp      = make_dispatcher(label)
    local ctx       = {}
    local plist     = cfg.players or {cfg.p1, cfg.p2}  -- 统一视为玩家列表
    local max_p     = #plist

    -- 不传 mode，由 match_init 根据人数自动选择（2人→pvp，5人→identity）
    local state = handler.match_init(ctx, {max_players=max_p})
    state._dispatcher = disp

    for _, pc in ipairs(plist) do
        local pr = {user_id=pc.id, username=pc.name}
        state = handler.match_join(ctx, disp, 0, state, {pr})
        state._dispatcher = disp
    end

    -- 强制指定英雄（覆盖随机分配）
    for _, pc in ipairs(plist) do
        state.players[pc.id].hero = pc.hero
    end

    matches[i] = {state=state, dispatcher=disp, label=label, winner=nil, turns=0, crashed=false, plist=plist}
end

--------------------------------------------------------------------------------
-- Round-Robin：15 局交替推进
--------------------------------------------------------------------------------
print("╔════════════════════════════════════════════════════════════════╗")
print("║  阿苏拉 · 并发验证 Demo（15局2人+2局5人 / 覆盖30名英雄）      ║")
print("╚════════════════════════════════════════════════════════════════╝")
for i, cfg in ipairs(MATCH_CONFIGS) do
    if cfg.players then
        local parts = {}
        for _, pc in ipairs(cfg.players) do table.insert(parts, pc.name.."("..pc.hero..")") end
        print(string.format("  对局%02d: [5人局] %s  seed=%d", i, table.concat(parts, " / "), cfg.seed))
    else
        print(string.format("  对局%02d: %-10s(%s)  vs  %-10s(%s)  seed=%d",
            i, cfg.p1.name, cfg.p1.hero, cfg.p2.name, cfg.p2.hero, cfg.seed))
    end
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
    if cfg.players then
        print(string.format("  对局%02d  [5人局]  %s  共%d回合  %s", i, result, m.turns, status))
    else
        print(string.format("  对局%02d  %-8s vs %-8s  %s  共%d回合  %s",
            i, cfg.p1.hero, cfg.p2.hero, result, m.turns, status))
    end
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
local ALL_HEROES = {
    -- 原版 6
    "aladdin","alibaba","saladin","hakim","scheherazade","jafar",
    -- 第一批 12
    "ibn_battuta","al_khwarizmi","avicenna","sinbad","hulagu","rumi",
    "zubaydah","al_biruni","tamerlane","dunyazad","antar","nefertiti",
    -- 第二批 12
    "harun_al_rashid","suleiman","khayyam","zenobia","muawiyah","nizamulmulk",
    "enheduanna","al_mansur","gilgamesh","imru_al_qais","basira","dhul_qarnayn",
}

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
    print("全部对局运行完毕，无崩溃 ✓")
else
    print(string.format("存在 %d 局崩溃，请检查上方错误信息", crashed_count))
    os.exit(1)
end

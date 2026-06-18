local nk = require("nakama")
local local_mgr = require("localization_manager")
local M = {}

-- 双角王（Dhul-Qarnayn）- 《古兰经》中的伟大君主，筑壁垒、征远疆
-- 技能：【筑壁】 出牌阶段铸手牌为壁垒（最多3枚）；任意角色受伤时自动消耗壁垒减伤1并摸1张；准备阶段从弃牌堆回收1张补壁
-- 技能：【远疆】 弃1张牌声明方位：西行→本回合杀无距离限制+可额外指定1目标；东行→本回合非延时锦囊可额外选1目标

local MAX_WALLS = 3

-- 辅助：本地 pending_action 函数（需在 on_play_phase_start 前定义）
local function _offer_skills(dispatcher, state, player_id, p)
    local can_wall = p.dhul_wall_count < MAX_WALLS and #p.hand > 0
    local can_west = not p.dhul_west_used and #p.hand > 0
    local can_east = not p.dhul_east_used and #p.hand > 0
    if not can_wall and not can_west and not can_east then return end

    state.pending_action = {
        type       = "DHUL_SKILL_CHOICE",
        player_id  = player_id,
        hero_id    = "dhul_qarnayn",
        can_wall   = can_wall,
        can_west   = can_west,
        can_east   = can_east,
        wall_count = p.dhul_wall_count,
        deadline   = os.time() + 15,
    }
    dispatcher.broadcast_message(101, nk.json_encode({
        type = "skill_choice",
        skill = "zhu_bi_yuan_jiang",
        description = "Choose a skill or skip",
        can_wall   = can_wall,
        can_west   = can_west,
        can_east   = can_east,
        wall_count = p.dhul_wall_count,
    }), {state.presences[player_id]})
end

-- 准备阶段：从弃牌堆回收1张牌铸为壁垒（不占出牌阶段次数）
function M.on_draw_phase_start(dispatcher, state, player_id)
    local p = state.players[player_id]
    if p.hero ~= "dhul_qarnayn" then return false end
    if p.health <= 0 then return false end

    p.dhul_wall_count = p.dhul_wall_count or 0
    if p.dhul_wall_count >= MAX_WALLS then return false end
    if #state.discard_pile == 0 then return false end

    p.dhul_wall_count = p.dhul_wall_count + 1
    local msg = local_mgr.bc("skill_dhul_qarnayn_wall_recover", {
        username = p.username,
        current = tostring(p.dhul_wall_count),
        max = tostring(MAX_WALLS),
    })
    msg.hero = "dhul_qarnayn"
    msg.skill = "zhu_bi"
    dispatcher.broadcast_message(11, nk.json_encode(msg))
    return false
end

-- 出牌阶段：提供技能选择菜单（筑壁/西行/东行）
function M.on_play_phase_start(dispatcher, state, player_id)
    local p = state.players[player_id]
    if p.hero ~= "dhul_qarnayn" then return false end
    if p.health <= 0 then return false end

    p.dhul_wall_count  = p.dhul_wall_count  or 0
    p.dhul_west_used   = p.dhul_west_used   or false
    p.dhul_east_used   = p.dhul_east_used   or false

    _offer_skills(dispatcher, state, player_id, p)
    return true
end

-- 记录玩家打出的牌，供【远疆】额外目标使用
function M.on_card_played(dispatcher, state, player_id, card)
    local p = state.players[player_id]
    if p.hero ~= "dhul_qarnayn" then return end
    if p.health <= 0 then return end

    if state.dhul_westward and state.dhul_westward[player_id] and card.type == "ATTACK" then
        if not state.dhul_west_extra_used or not state.dhul_west_extra_used[player_id] then
            state._dhul_last_attack_card = card
        end
    end
    if state.dhul_eastward and state.dhul_eastward[player_id] and card.type == "INSTANT_TRICK" then
        if not state.dhul_east_extra_used or not state.dhul_east_extra_used[player_id] then
            state._dhul_last_trick_card = { card = card, subtype = card.subtype }
        end
    end
end

-- 【远疆-西行】额外攻击目标：攻击链结束后调用
function M.on_attack_resolved(dispatcher, state, attacker_id)
    if not state.dhul_westward or not state.dhul_westward[attacker_id] then return false end
    local p = state.players[attacker_id]
    if not p or p.health <= 0 then return false end
    if state.dhul_west_extra_used and state.dhul_west_extra_used[attacker_id] then return false end
    if not state._dhul_last_attack_card then return false end

    -- 找额外攻击目标（存活、非本人、攻击链中尚未成为目标可能会重复，但取决于先后）
    local targets = {}
    for uid, p2 in pairs(state.players) do
        if uid ~= attacker_id and p2.health > 0 then
            table.insert(targets, {id = uid, name = p2.username})
        end
    end
    if #targets == 0 then return false end

    state.dhul_west_extra_used = state.dhul_west_extra_used or {}
    state.dhul_west_extra_used[attacker_id] = true

    state.pending_action = {
        type       = "DHUL_WEST_EXTRA",
        player_id  = attacker_id,
        hero_id    = "dhul_qarnayn",
        card       = state._dhul_last_attack_card,
        targets    = targets,
        deadline   = os.time() + 15,
    }

    dispatcher.broadcast_message(101, nk.json_encode({
        type        = "skill_choice",
        skill       = "yuan_jiang_west",
        description = "[Far-Reach West] Choose an extra attack target",
        targets     = targets,
    }), {state.presences[attacker_id]})
    return true
end

-- 【远疆-东行】额外锦囊目标：非延时锦囊效果执行后调用
function M.on_trick_resolved(dispatcher, state, player_id, subtype)
    if not state.dhul_eastward or not state.dhul_eastward[player_id] then return false end
    local p = state.players[player_id]
    if not p or p.health <= 0 then return false end
    if state.dhul_east_extra_used and state.dhul_east_extra_used[player_id] then return false end
    if not state._dhul_last_trick_card then return false end

    -- 仅对单体锦囊支持额外目标
    if subtype ~= "discard_one" and subtype ~= "steal_one" then return false end

    local targets = {}
    for uid, p2 in pairs(state.players) do
        if uid ~= player_id and p2.health > 0 then
            table.insert(targets, {id = uid, name = p2.username})
        end
    end
    if #targets == 0 then return false end

    state.dhul_east_extra_used = state.dhul_east_extra_used or {}
    state.dhul_east_extra_used[player_id] = true

    state.pending_action = {
        type        = "DHUL_EAST_EXTRA",
        player_id   = player_id,
        hero_id     = "dhul_qarnayn",
        trick_type  = subtype,
        trick_card  = state._dhul_last_trick_card.card,
        targets     = targets,
        deadline    = os.time() + 15,
    }

    dispatcher.broadcast_message(101, nk.json_encode({
        type        = "skill_choice",
        skill       = "yuan_jiang_east",
        description = "[Far-Reach East] Choose an extra trick target",
        targets     = targets,
    }), {state.presences[player_id]})
    return true
end

-- 任意角色受伤时自动消耗壁垒减伤
function M.on_before_damage(dispatcher, state, target_id, amount, source_id)
    if amount <= 0 then return false end
    for _, p in pairs(state.players) do
        if p.hero == "dhul_qarnayn" and p.health > 0 then
            local wc = p.dhul_wall_count or 0
            if wc > 0 then
                p.dhul_wall_count = wc - 1
                local rules = require("game_rules")
                rules.draw_cards(state, p.id, 1)
                local tname = (state.players[target_id] and state.players[target_id].username) or "?"
                local msg3 = local_mgr.bc("skill_dhul_qarnayn_wall_consume", {
                    username = p.username,
                    target = tname,
                    remaining = tostring(p.dhul_wall_count),
                })
                msg3.hero = "dhul_qarnayn"
                msg3.skill = "zhu_bi"
                dispatcher.broadcast_message(11, nk.json_encode(msg3))
                return true
            end
        end
    end
    return false
end

function M.on_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action or action.hero_id ~= "dhul_qarnayn" then return end

    local rules = require("game_rules")
    local p = state.players[player_id]
    if not p then return end

    -- ========= 顶层面板：选择技能 =========
    if action.type == "DHUL_SKILL_CHOICE" then
        state.pending_action = nil

        if payload.confirm ~= true then
            rules.broadcast_update(dispatcher, state)
            return
        end

        local cost_paid = false
        if type(payload.card_id) == "string" then
            for i, c in ipairs(p.hand) do
                if c.id == payload.card_id then
                    table.insert(state.discard_pile, table.remove(p.hand, i))
                    cost_paid = true
                    break
                end
            end
        end
        if not cost_paid then
            rules.broadcast_update(dispatcher, state)
            return
        end

        if payload.skill == "wall" then
            p.dhul_wall_count = (p.dhul_wall_count or 0) + 1
            local msg = local_mgr.bc("skill_dhul_qarnayn_wall_build", {
                username = p.username,
                current = tostring(p.dhul_wall_count),
                max = tostring(MAX_WALLS),
            })
            msg.hero = "dhul_qarnayn"
            msg.skill = "zhu_bi"
            dispatcher.broadcast_message(11, nk.json_encode(msg))

        elseif payload.skill == "westward" then
            state.dhul_westward = state.dhul_westward or {}
            state.dhul_westward[player_id] = true
            local msg4 = local_mgr.bc("skill_dhul_qarnayn_far_west", {
                username = p.username,
            })
            msg4.hero = "dhul_qarnayn"
            msg4.skill = "yuan_jiang"
            dispatcher.broadcast_message(11, nk.json_encode(msg4))

        elseif payload.skill == "eastward" then
            state.dhul_eastward = state.dhul_eastward or {}
            state.dhul_eastward[player_id] = true
            local msg5 = local_mgr.bc("skill_dhul_qarnayn_far_east", {
                username = p.username,
            })
            msg5.hero = "dhul_qarnayn"
            msg5.skill = "yuan_jiang"
            dispatcher.broadcast_message(11, nk.json_encode(msg5))

        else
            rules.broadcast_update(dispatcher, state)
            return
        end

        -- 技能执行完后检查是否还有可用技能
        _offer_skills(dispatcher, state, player_id, p)
        rules.broadcast_update(dispatcher, state)

    -- ========= 远疆-西行：选择额外攻击目标 =========
    elseif action.type == "DHUL_WEST_EXTRA" then
        state.pending_action = nil

        if payload.confirm ~= true or type(payload.target_id) ~= "string" then
            rules.broadcast_update(dispatcher, state)
            return
        end
        local target = state.players[payload.target_id]
        if not target or target.health <= 0 then
            rules.broadcast_update(dispatcher, state)
            return
        end

        -- 复用攻击效果（用记录的卡牌对额外目标发起攻击）
        local msg6 = local_mgr.bc("skill_dhul_qarnayn_far_west_extra", {
            username = p.username,
            target = target.username,
        })
        msg6.hero = "dhul_qarnayn"
        msg6.skill = "yuan_jiang"
        dispatcher.broadcast_message(11, nk.json_encode(msg6))
        local card = action.card
        local rules2 = require("game_rules")
        rules2.CARD_EFFECTS["ATTACK"](dispatcher, state, player_id, payload.target_id, card)

    -- ========= 远疆-东行：选择额外锦囊目标 =========
    elseif action.type == "DHUL_EAST_EXTRA" then
        state.pending_action = nil

        if payload.confirm ~= true or type(payload.target_id) ~= "string" then
            rules.broadcast_update(dispatcher, state)
            return
        end
        local target = state.players[payload.target_id]
        if not target or target.health <= 0 then
            rules.broadcast_update(dispatcher, state)
            return
        end

        -- 过河拆桥/顺手牵羊的距离限制
        if action.trick_type == "steal_one" then
            local dist = rules.seat_distance(state, player_id, payload.target_id)
            if dist > 1 then
                rules.broadcast_update(dispatcher, state)
                return
            end
        end

        local msg7 = local_mgr.bc("skill_dhul_qarnayn_far_east_extra", {
            username = p.username,
            target = target.username,
        })
        msg7.hero = "dhul_qarnayn"
        msg7.skill = "yuan_jiang"
        dispatcher.broadcast_message(11, nk.json_encode(msg7))

        local card = action.trick_card
        -- pt intentionally unused: only need the trick_card reference above
        -- 绕过 COUNTER 窗口直接执行效果（额外目标是同一锦囊的一部分）
        local rules2 = require("game_rules")
        rules2.CARD_EFFECTS["INSTANT_TRICK"](dispatcher, state, player_id, payload.target_id, card)
        -- 如果重新进入了 WAITING_FOR_TRICK_SELECT（即原来的锦囊选择还没结束），
        -- 此时 pending_action 已设为本 pending 的子类型，不做额外处理
    end
end

-- 死亡时清理全局状态标志（防止在他人回合内死亡时标志残留）
function M.on_timeout(dispatcher, state, act)
    state.pending_action = nil
    require("game_rules").broadcast_update(dispatcher, state)
end

function M.on_death(dispatcher, state, player_id)
    local p = state.players[player_id]
    if p.hero ~= "dhul_qarnayn" then return false end
    state.dhul_westward = nil
    state.dhul_eastward = nil
    state._dhul_last_attack_card = nil
    state._dhul_last_trick_card = nil
    p.dhul_west_used = false
    p.dhul_east_used = false
    return false
end

-- 回合结束时重置每回合计数
function M.on_turn_end(dispatcher, state, player_id)
    local p = state.players[player_id]
    if p.hero ~= "dhul_qarnayn" then return false end
    p.dhul_west_used = false
    p.dhul_east_used = false
    state.dhul_westward = nil
    state.dhul_eastward = nil
    state._dhul_last_attack_card = nil
    state._dhul_last_trick_card = nil
    return false
end

return M

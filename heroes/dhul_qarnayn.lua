local nk = require("nakama")
local local_mgr = require("localization_manager")
local M = {}

-- 双角王（Dhul-Qarnayn）- 《古兰经》中的伟大君主，筑壁垒、征远疆
-- 技能：【筑壁】 出牌阶段弃1张手牌，把壁垒公开放在任意一名角色身上（场上最多2枚，同一角色不叠）；
--               带壁垒者下次受伤 -1，壁垒消耗。给谁上壁由玩家决定——公开站队或伪装身份都是玩法
-- 技能：【远疆】 弃1张牌声明方位：西行→本回合杀无距离限制+可额外指定1目标；东行→本回合非延时锦囊可额外选1目标

local MAX_WALLS = 2

-- 壁垒存在被保护者身上（wall_from = 双角王 id），伤害结算时由 absorb_wall 消耗
local function walls_placed(state, owner_id)
    local n = 0
    for _, p in pairs(state.players) do
        if p.wall_from == owner_id and p.health > 0 then n = n + 1 end
    end
    return n
end

local function wall_targets(state)
    local list = {}
    for uid, p in pairs(state.players) do
        if p.health > 0 and not p.wall_from then
            list[#list + 1] = { id = uid, username = p.username, seat_idx = p.seat_idx or 0 }
        end
    end
    table.sort(list, function(a, b) return a.seat_idx < b.seat_idx end)
    return list
end

-- 辅助：本地 pending_action 函数（需在 on_play_phase_start 前定义）
local function _offer_skills(dispatcher, state, player_id, p)
    local placed = walls_placed(state, player_id)
    local targets = wall_targets(state)
    local can_wall = placed < MAX_WALLS and #p.hand > 0 and #targets > 0
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
        wall_count = placed,
        wall_targets = targets,
        deadline   = os.time() + 15,
    }
    local m = local_mgr.bc("skill_dhul_qarnayn_skill_choose")
    m.type = "skill_choice"
    m.skill = "zhu_bi_yuan_jiang"
    m.can_wall   = can_wall
    m.can_west   = can_west
    m.can_east   = can_east
    m.wall_count = placed
    m.wall_targets = targets
    dispatcher.broadcast_message(101, nk.json_encode(m), {state.presences[player_id]})
end

-- 出牌阶段：提供技能选择菜单（筑壁/西行/东行）
function M.on_play_phase_start(dispatcher, state, player_id)
    local p = state.players[player_id]
    if p.hero ~= "dhul_qarnayn" then return false end
    if p.health <= 0 then return false end

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

    local m = local_mgr.bc("skill_dhul_qarnayn_west_target")
    m.type    = "skill_choice"
    m.skill   = "yuan_jiang_west"
    m.targets = targets
    dispatcher.broadcast_message(101, nk.json_encode(m), {state.presences[attacker_id]})
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

    local m = local_mgr.bc("skill_dhul_qarnayn_east_target")
    m.type    = "skill_choice"
    m.skill   = "yuan_jiang_east"
    m.targets = targets
    dispatcher.broadcast_message(101, nk.json_encode(m), {state.presences[player_id]})
    return true
end

-- 由 game_rules.apply_damage 经 hero_mgr.absorb_wall 调用：受伤者带壁垒则消耗并减伤 1
function M.absorb_wall(dispatcher, state, target_id)
    local t = state.players[target_id]
    if not t or not t.wall_from then return false end
    t.wall_from = nil
    local msg = local_mgr.bc("skill_dhul_qarnayn_wall_consume", { target = t.username })
    msg.hero = "dhul_qarnayn"
    msg.skill = "zhu_bi"
    dispatcher.broadcast_message(11, nk.json_encode(msg))
    return true
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

        local wall_target
        if payload.skill == "wall" then
            local tid = payload.target_id
            if tid == nil then tid = player_id end
            local t = type(tid) == "string" and state.players[tid]
            if not t or t.health <= 0 or t.wall_from
                or walls_placed(state, player_id) >= MAX_WALLS then
                _offer_skills(dispatcher, state, player_id, p)
                rules.broadcast_update(dispatcher, state)
                return
            end
            wall_target = t
        elseif (payload.skill == "westward" and p.dhul_west_used)
            or (payload.skill == "eastward" and p.dhul_east_used)
            or (payload.skill ~= "westward" and payload.skill ~= "eastward") then
            _offer_skills(dispatcher, state, player_id, p)
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
            wall_target.wall_from = player_id
            local msg = local_mgr.bc("skill_dhul_qarnayn_wall_build", {
                username = p.username,
                target = wall_target.username,
                current = tostring(walls_placed(state, player_id)),
                max = tostring(MAX_WALLS),
            })
            msg.target_id = wall_target.id
            msg.hero = "dhul_qarnayn"
            msg.skill = "zhu_bi"
            dispatcher.broadcast_message(11, nk.json_encode(msg))

        elseif payload.skill == "westward" then
            state.dhul_westward = state.dhul_westward or {}
            state.dhul_westward[player_id] = true
            p.dhul_west_used = true
            local msg4 = local_mgr.bc("skill_dhul_qarnayn_far_west", {
                username = p.username,
            })
            msg4.hero = "dhul_qarnayn"
            msg4.skill = "yuan_jiang"
            dispatcher.broadcast_message(11, nk.json_encode(msg4))

        elseif payload.skill == "eastward" then
            state.dhul_eastward = state.dhul_eastward or {}
            state.dhul_eastward[player_id] = true
            p.dhul_east_used = true
            local msg5 = local_mgr.bc("skill_dhul_qarnayn_far_east", {
                username = p.username,
            })
            msg5.hero = "dhul_qarnayn"
            msg5.skill = "yuan_jiang"
            dispatcher.broadcast_message(11, nk.json_encode(msg5))
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

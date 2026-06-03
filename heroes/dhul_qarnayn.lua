local nk = require("nakama")
local M = {}

-- 双角王（Dhul-Qarnayn）- 《古兰经》中的伟大君主，筑壁垒、征远疆
-- 技能：【筑壁】 出牌阶段将手牌铸为壁垒（最多3枚）；任意角色受伤时自动消耗壁垒减伤1并摸1张；准备阶段从弃牌堆回收1张牌铸为壁垒
-- 技能：【远疆】 出牌阶段：西行→弃1张牌对攻击范围内角色造成1点伤害；东行→弃1张牌令目标摸1弃1。各限1次/回合

local MAX_WALLS = 3

-- 准备阶段：从弃牌堆回收1张牌铸为壁垒（不占出牌阶段次数）
function M.on_draw_phase_start(dispatcher, state, player_id)
    local p = state.players[player_id]
    if p.hero ~= "dhul_qarnayn" then return false end
    if p.health <= 0 then return false end

    p.dhul_wall_count = p.dhul_wall_count or 0
    if p.dhul_wall_count >= MAX_WALLS then return false end
    if #state.discard_pile == 0 then return false end

    p.dhul_wall_count = p.dhul_wall_count + 1
    dispatcher.broadcast_message(11, nk.json_encode({
        content = string.format("%s 发动【筑壁】，从弃牌堆回收1张牌补为壁垒（%d/%d）",
            p.username, p.dhul_wall_count, MAX_WALLS),
        hero    = "dhul_qarnayn", skill = "zhu_bi"
    }))
    return false
end

local function _offer_skills(dispatcher, state, player_id, p, can_wall, can_west, can_east)
    -- 本地函数，必须在 on_play_phase_start 之前定义
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
        description = "选择技能或跳过",
        can_wall   = can_wall,
        can_west   = can_west,
        can_east   = can_east,
        wall_count = p.dhul_wall_count,
    }), {state.presences[player_id]})
end

-- 出牌阶段：提供技能选择菜单
function M.on_play_phase_start(dispatcher, state, player_id)
    local p = state.players[player_id]
    if p.hero ~= "dhul_qarnayn" then return false end
    if p.health <= 0 then return false end

    p.dhul_wall_count  = p.dhul_wall_count  or 0
    p.dhul_west_used   = p.dhul_west_used   or false
    p.dhul_east_used   = p.dhul_east_used   or false

    local can_wall = p.dhul_wall_count < MAX_WALLS and #p.hand > 0
    local can_west = not p.dhul_west_used and #p.hand > 0
    local can_east = not p.dhul_east_used and #p.hand > 0
    if not can_wall and not can_west and not can_east then return false end

    _offer_skills(dispatcher, state, player_id, p, can_wall, can_west, can_east)
    return true
end

-- 任意角色受伤时自动消耗壁垒减伤
-- player_id 为受伤者，遍历全场找 dhul_qarnayn 的壁垒消耗
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
                dispatcher.broadcast_message(11, nk.json_encode({
                    content = string.format("%s 消耗1枚壁垒，为%s减免1点伤害并摸1张牌（剩余%d）",
                        p.username, tname, p.dhul_wall_count),
                    hero = "dhul_qarnayn", skill = "zhu_bi"
                }))
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

        if payload.skill == "wall" then
            p.dhul_wall_count = (p.dhul_wall_count or 0) + 1
            if payload.card_id and type(payload.card_id) == "string" then
                for i, c in ipairs(p.hand) do
                    if c.id == payload.card_id then
                        table.insert(state.discard_pile, table.remove(p.hand, i))
                        break
                    end
                end
            end
            dispatcher.broadcast_message(11, nk.json_encode({
                content = string.format("%s 发动【筑壁】，铸1张手牌为壁垒（%d/%d）",
                    p.username, p.dhul_wall_count, MAX_WALLS),
                hero = "dhul_qarnayn", skill = "zhu_bi"
            }))

        elseif payload.skill == "westward" then
            state.pending_action = {
                type       = "DHUL_WESTWARD_TARGET",
                player_id  = player_id,
                hero_id    = "dhul_qarnayn",
                deadline   = os.time() + 15,
            }
            local targets = {}
            for uid, p2 in pairs(state.players) do
                if uid ~= player_id and p2.health > 0 and rules.can_attack(state, player_id, uid) then
                    table.insert(targets, {id = uid, name = p2.username})
                end
            end
            if #targets == 0 then
                rules.broadcast_update(dispatcher, state)
                return
            end
            dispatcher.broadcast_message(101, nk.json_encode({
                type = "skill_choice",
                skill = "yuan_jiang_west",
                description = "【远疆-西行】选择目标造成1点伤害",
                targets = targets,
            }), {state.presences[player_id]})
            return

        elseif payload.skill == "eastward" then
            state.pending_action = {
                type       = "DHUL_EASTWARD_TARGET",
                player_id  = player_id,
                hero_id    = "dhul_qarnayn",
                deadline   = os.time() + 15,
            }
            local targets = {}
            for uid, p2 in pairs(state.players) do
                if uid ~= player_id and p2.health > 0 then
                    table.insert(targets, {id = uid, name = p2.username})
                end
            end
            if #targets == 0 then
                rules.broadcast_update(dispatcher, state)
                return
            end
            dispatcher.broadcast_message(101, nk.json_encode({
                type = "skill_choice",
                skill = "yuan_jiang_east",
                description = "【远疆-东行】选择目标令其摸1弃1",
                targets = targets,
            }), {state.presences[player_id]})
            return
        else
            -- 不可用的技能或未知命令 → 跳过
            rules.broadcast_update(dispatcher, state)
            return
        end

        -- 技能执行完后检查是否还有可用技能，继续面板
        local can_wall2 = p.dhul_wall_count < MAX_WALLS and #p.hand > 0
        local can_west2 = not p.dhul_west_used and #p.hand > 0 and payload.skill ~= "westward"
        local can_east2 = not p.dhul_east_used and #p.hand > 0 and payload.skill ~= "eastward"
        if can_wall2 or can_west2 or can_east2 then
            _offer_skills(dispatcher, state, player_id, p, can_wall2, can_west2, can_east2)
        end
        rules.broadcast_update(dispatcher, state)

    -- ========= 远疆-西行：选择目标 =========
    elseif action.type == "DHUL_WESTWARD_TARGET" then
        state.pending_action = nil
        p.dhul_west_used = true

        if payload.confirm ~= true or type(payload.target_id) ~= "string" then
            rules.broadcast_update(dispatcher, state)
            return
        end
        local target = state.players[payload.target_id]
        if not target or target.health <= 0 then
            rules.broadcast_update(dispatcher, state)
            return
        end
        if not rules.can_attack(state, player_id, payload.target_id) then
            rules.broadcast_update(dispatcher, state)
            return
        end

        -- 弃1张牌
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

        rules.apply_damage(dispatcher, state, payload.target_id, 1, player_id)
        dispatcher.broadcast_message(11, nk.json_encode({
            content = string.format("%s 发动【远疆-西行】，弃1张牌对%s造成1点伤害！",
                p.username, target.username),
            hero = "dhul_qarnayn", skill = "yuan_jiang"
        }))
        if not (state.pending_action and state.pending_action.type == "WAITING_FOR_RESCUE") then
            rules.broadcast_update(dispatcher, state)
        end

    -- ========= 远疆-东行：选择目标 =========
    elseif action.type == "DHUL_EASTWARD_TARGET" then
        state.pending_action = nil
        p.dhul_east_used = true

        if payload.confirm ~= true or type(payload.target_id) ~= "string" then
            rules.broadcast_update(dispatcher, state)
            return
        end
        local target = state.players[payload.target_id]
        if not target or target.health <= 0 then
            rules.broadcast_update(dispatcher, state)
            return
        end

        -- 弃1张牌
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

        -- 目标摸1弃1
        rules.draw_cards(state, payload.target_id, 1)
        if #target.hand > 0 then
            table.insert(state.discard_pile, table.remove(target.hand, #target.hand))
        end
        dispatcher.broadcast_message(11, nk.json_encode({
            content = string.format("%s 发动【远疆-东行】，弃1张牌令%s摸1弃1！",
                p.username, target.username),
            hero = "dhul_qarnayn", skill = "yuan_jiang"
        }))
        rules.broadcast_update(dispatcher, state)
    end
end

-- 回合结束时重置每回合计数
function M.on_turn_end(dispatcher, state, player_id)
    local p = state.players[player_id]
    if p.hero ~= "dhul_qarnayn" then return false end
    p.dhul_west_used = false
    p.dhul_east_used = false
    return false
end

return M

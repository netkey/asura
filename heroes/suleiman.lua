local nk = require("nakama")
local M = {}

-- 苏莱曼（Suleiman）- 奥斯曼帝国苏丹，"立法者"（Kanuni），以法律改革闻名
-- 技能：【敕令】 - 出牌阶段开始时，选择一名玩家+一种牌型（攻击或治疗），该玩家本回合不能使用该类型牌

local BLOCKABLE_TYPES = {
    ATTACK  = "攻击",
    HEAL    = "治疗",
}

function M.on_play_phase_start(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "suleiman" then return false end

    local targets = {}
    for uid, p in pairs(state.players) do
        if uid ~= player_id and p.health > 0 then
            table.insert(targets, { id = uid, username = p.username })
        end
    end
    if #targets == 0 then return false end

    local block_types = {}
    for k, v in pairs(BLOCKABLE_TYPES) do
        table.insert(block_types, { type = k, label = v })
    end

    state.pending_action = {
        type        = "SULEIMAN_CHI_LING",
        player_id   = player_id,
        hero_id     = "suleiman",
        targets     = targets,
        block_types = block_types,
        deadline    = os.time() + 15,
    }

    dispatcher.broadcast_message(101, nk.json_encode({
        type        = "skill_choice",
        skill       = "chi_ling",
        description = "是否发动【敕令】？选择一名玩家并禁止一种牌型",
        targets     = targets,
        block_types = block_types,
    }), { state.presences[player_id] })

    return true
end

function M.on_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action or action.type ~= "SULEIMAN_CHI_LING" then return end
    if action.player_id ~= player_id then return end

    state.pending_action = nil

    if payload.confirm ~= true or type(payload.target_id) ~= "string" or type(payload.block_type) ~= "string" then
        local rules = require("game_rules")
        rules.broadcast_update(dispatcher, state)
        return
    end

    if not BLOCKABLE_TYPES[payload.block_type] then
        local rules = require("game_rules")
        rules.broadcast_update(dispatcher, state)
        return
    end

    local target = state.players[payload.target_id]
    if not target or target.health <= 0 or payload.target_id == player_id then
        local rules = require("game_rules")
        rules.broadcast_update(dispatcher, state)
        return
    end

    state.suleiman_chi_ling = {
        target_id    = payload.target_id,
        blocked_type = payload.block_type,
    }

    local player = state.players[player_id]
    dispatcher.broadcast_message(11, nk.json_encode({
        content = string.format("%s 发动【敕令】，%s 本回合禁止使用【%s】！",
            player.username, target.username,
            BLOCKABLE_TYPES[payload.block_type] or payload.block_type),
        event     = "skill_used",
        hero      = "suleiman",
        skill     = "chi_ling",
        target_id = payload.target_id,
        block_type = payload.block_type,
    }))

    local rules = require("game_rules")
    rules.broadcast_update(dispatcher, state)
end

function M.on_timeout(dispatcher, state, act)
    local hero_mgr = require("hero_manager")
    if act.targets and #act.targets > 0 then
        hero_mgr.handle_response(dispatcher, state, act.player_id,
            { confirm = true, target_id = act.targets[1].id, block_type = "ATTACK" })
    else
        hero_mgr.handle_response(dispatcher, state, act.player_id, { confirm = false })
    end
end

return M

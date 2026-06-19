local nk = require("nakama")
local local_mgr = require("localization_manager")
local M = {}

-- 苏莱曼（Suleiman）- 奥斯曼帝国苏丹，"立法者"（Kanuni），以法律改革闻名
-- 技能：【敕令】 - 出牌阶段开始时，选择一名玩家+一种牌型（攻击或治疗），该玩家本回合不能使用该类型牌

local BLOCKABLE_TYPES = {
    ATTACK  = "Attack",
    HEAL    = "Heal",
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

    local m = local_mgr.bc("skill_suleiman_decree_prompt")
    m.type        = "skill_choice"
    m.skill       = "chi_ling"
    m.targets     = targets
    m.block_types = block_types
    dispatcher.broadcast_message(101, nk.json_encode(m), { state.presences[player_id] })

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
    local msg = local_mgr.bc("skill_suleiman_decree", {
        username = player.username,
    })
    msg.event = "skill_used"
    msg.hero = "suleiman"
    msg.skill = "chi_ling"
    msg.target_id = payload.target_id
    msg.block_type = payload.block_type
    dispatcher.broadcast_message(11, nk.json_encode(msg))

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

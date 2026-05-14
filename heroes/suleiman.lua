local nk = require("nakama")
local M = {}

-- 苏莱曼（所罗门） - 古代以色列联合王国最伟大的国王，传说拥有封印恶魔的神戒指
-- 技能：【封印】 - 出牌阶段开始时，可宣告一名其他玩家本回合不能使用【AOE沙尘暴】（主动选择）

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

    state.pending_action = {
        type      = "SULEIMAN_SEAL",
        player_id = player_id,
        hero_id   = "suleiman",
        targets   = targets,
        deadline  = os.time() + 15,
    }

    dispatcher.broadcast_message(101, nk.json_encode({
        type        = "skill_choice",
        skill       = "feng_yin",
        description = "是否发动【封印】？选择一名玩家令其本回合不能使用【沙尘暴】",
        targets     = targets,
    }), { state.presences[player_id] })

    return true
end

function M.on_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action or action.type ~= "SULEIMAN_SEAL" then return end
    if action.player_id ~= player_id then return end

    state.pending_action = nil

    -- confirm=false 或超时：放弃技能，直接进入出牌阶段
    if payload.confirm ~= true or type(payload.target_id) ~= "string" then
        local rules = require("game_rules")
        rules.broadcast_update(dispatcher, state)
        return
    end

    -- 校验目标合法
    local target = state.players[payload.target_id]
    if not target or target.health <= 0 or payload.target_id == player_id then
        local rules = require("game_rules")
        rules.broadcast_update(dispatcher, state)
        return
    end

    state.suleiman_sealed = state.suleiman_sealed or {}
    state.suleiman_sealed[payload.target_id] = true
    state.suleiman_sealed_owner = player_id

    local player = state.players[player_id]
    dispatcher.broadcast_message(11, nk.json_encode({
        content   = string.format("%s 发动【封印】，%s 本回合不能使用【沙尘暴】！",
                        player.username, target.username),
        event     = "skill_used",
        hero      = "suleiman",
        skill     = "feng_yin",
        target_id = payload.target_id,
    }))

    local rules = require("game_rules")
    rules.broadcast_update(dispatcher, state)
end

return M

local nk = require("nakama")
local M = {}

-- 哈伦·拉希德 - 阿拔斯王朝最鼎盛时期的哈里发
-- 技能：【哈里发令】 - 出牌阶段，可指定一名其他玩家，令其选择：弃置1张牌，或受到1点伤害

function M.on_play_phase_start(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "harun_al_rashid" then return false end

    local targets = {}
    for uid, p in pairs(state.players) do
        if uid ~= player_id and p.health > 0 then
            table.insert(targets, uid)
        end
    end
    if #targets == 0 then return false end

    local target_id = targets[math.random(#targets)]
    local target    = state.players[target_id]

    state.pending_action = {
        type        = "HARUN_CHOOSE",
        -- 响应者是目标玩家（由目标决定弃牌或受伤）
        player_id   = target_id,
        hero_id     = "harun_al_rashid",
        caster_id   = player_id,
        target_id   = target_id,
        deadline    = os.time() + 15,
        description = "你被【哈里发令】指定，请选择：弃1张牌或受1点伤害",
    }

    -- 广播给全场：哈伦发动技能
    dispatcher.broadcast_message(11, nk.json_encode({
        content   = string.format("%s 发动【哈里发令】，指定 %s：弃1张牌或受1点伤害",
                        player.username, target.username),
        event     = "skill_used",
        hero      = "harun_al_rashid",
        skill     = "ha_li_fa_ling",
        target_id = target_id,
    }))

    -- 私信给目标玩家：弹出选择框
    dispatcher.broadcast_message(101, nk.json_encode({
        type        = "skill_choice",
        skill       = "ha_li_fa_ling",
        description = string.format("%s 对你发动【哈里发令】，请选择：弃1张牌（choose_discard=true）或受1点伤害",
                          player.username),
        caster_id   = player_id,
    }), { state.presences[target_id] })

    return true
end

-- 目标玩家响应：choose_discard=true 弃牌，否则受伤
function M.on_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action or action.type ~= "HARUN_CHOOSE" then return end
    if action.player_id ~= player_id then return end

    local rules     = require("game_rules")
    local target    = state.players[action.target_id]
    local caster_id = action.caster_id

    if target and target.health > 0 then
        if payload.confirm ~= false and payload.choose_discard and #target.hand > 0 then
            local card = table.remove(target.hand, math.random(#target.hand))
            table.insert(state.discard_pile, card)
            dispatcher.broadcast_message(11, nk.json_encode({
                content = target.username .. " 服从【哈里发令】，弃置了1张牌",
            }))
        else
            -- 超时/拒绝弃牌/无牌可弃：受1点伤害
            rules.apply_damage(dispatcher, state, action.target_id, 1, caster_id)
        end
    end

    state.pending_action = nil
    if not (state.pending_action and state.pending_action.type == "WAITING_FOR_RESCUE") then
        rules.broadcast_update(dispatcher, state)
    end
end

return M

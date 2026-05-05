local nk = require("nakama")
local M = {}

-- 哈伦·拉希德 - 阿拔斯王朝最鼎盛时期的哈里发
-- 技能：【哈里发令】 - 出牌阶段，可指定一名其他玩家，令其选择：弃置1张牌，或受到1点伤害

function M.on_play_phase_start(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "harun_al_rashid" then return false end

    -- 找可指定的目标（其他存活玩家）
    local targets = {}
    for uid, p in pairs(state.players) do
        if uid ~= player_id and p.health > 0 then
            table.insert(targets, uid)
        end
    end
    if #targets == 0 then return false end

    -- 简化：AI 直接选第一个目标
    local target_id = targets[math.random(#targets)]
    local target = state.players[target_id]

    state.pending_action = {
        type = "HARUN_CHOOSE",
        player_id = player_id,
        hero_id = "harun_al_rashid",
        target_id = target_id,
        description = "是否对 " .. target.username .. " 发动【哈里发令】？"
    }
    dispatcher.broadcast_message(101, nk.json_encode({
        type = "skill_choice",
        skill = "ha_li_fa_ling",
        description = string.format("%s 发动【哈里发令】，%s 必须：弃1张牌或受1点伤害",
            player.username, target.username),
        target_id = target_id
    }), {state.presences[player_id]})
    return true
end

function M.on_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action or action.type ~= "HARUN_CHOOSE" then return end

    if payload.confirm ~= true then
        state.pending_action = nil
        return
    end

    local rules = require("game_rules")
    local target_id = action.target_id
    local target = state.players[target_id]

    if target and target.health > 0 then
        if payload.choose_discard then
            -- 目标选择弃牌
            if #target.hand > 0 then
                local card = table.remove(target.hand)
                table.insert(state.discard_pile, card)
                dispatcher.broadcast_message(11, nk.json_encode({
                    content = target.username .. " 服从【哈里发令】，弃置了1张牌"
                }))
            else
                -- 没牌可弃，受1点伤害
                rules.apply_damage(dispatcher, state, target_id, 1, player_id)
            end
        else
            -- 目标选择受伤害
            rules.apply_damage(dispatcher, state, target_id, 1, player_id)
        end
        rules.broadcast_update(dispatcher, state)
    end

    state.pending_action = nil
end

return M

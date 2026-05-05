local nk = require("nakama")
local M = {}

-- 鲁米 - 波斯苏菲诗人，旋转舞创始人
-- 技能：【旋回】 - 出牌阶段开始时，可将全部手牌弃置，摸等量新牌

function M.on_play_phase_start(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "rumi" then return false end
    if #player.hand < 1 then return false end

    state.pending_action = {
        type = "RUMI_XUANHUI",
        player_id = player_id,
        hero_id = "rumi",
        hand_count = #player.hand,
        description = "是否发动【旋回】，弃置全部手牌并摸等量新牌？"
    }
    dispatcher.broadcast_message(101, nk.json_encode({
        type = "skill_choice",
        skill = "xuan_hui",
        description = string.format("是否发动【旋回】，弃置全部 %d 张手牌，摸 %d 张新牌？",
            #player.hand, #player.hand)
    }), {state.presences[player_id]})
    return true
end

function M.on_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action or action.type ~= "RUMI_XUANHUI" then return end

    if payload.confirm ~= true then
        state.pending_action = nil
        return
    end

    local rules = require("game_rules")
    local player = state.players[player_id]
    local count = #player.hand

    -- 弃置全部手牌
    for i = #player.hand, 1, -1 do
        table.insert(state.discard_pile, table.remove(player.hand))
    end

    -- 摸等量新牌
    rules.draw_cards(state, player_id, count)
    dispatcher.broadcast_message(11, nk.json_encode({
        content = string.format("%s 发动【旋回】，弃%d摸%d，手牌焕然一新！",
            player.username, count, count),
        hero = "rumi", skill = "xuan_hui"
    }))
    rules.broadcast_update(dispatcher, state)
    state.pending_action = nil
end

return M

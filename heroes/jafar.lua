local nk = require("nakama")
local M = {}

-- 贾法尔 - 大维齐尔，《一千零一夜》中的权术家
-- 技能：【毒计】 - 被动：你发动的【攻击】需要目标出2张【防御】才能抵挡

function M.on_before_attack(dispatcher, state, player_id, target_id)
    local player = state.players[player_id]
    if player.hero ~= "jafar" then return false end

    state.jafar_du_ji = true

    local target = state.players[target_id]
    dispatcher.broadcast_message(11, nk.json_encode({
        content = string.format("%s 发动【毒计】，%s 需出2张【防御】才能抵挡！",
            player.username, target and target.username or target_id),
        hero = "jafar", skill = "du_ji"
    }))

    return false
end

return M

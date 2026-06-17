local nk = require("nakama")
local local_mgr = require("localization_manager")

local M = {}

-- 贾法尔 - 大维齐尔，《一千零一夜》中的权术家
-- 技能：【毒计】 - 被动：你发动的【攻击】需要目标出2张【防御】才能抵挡

function M.on_before_attack(dispatcher, state, player_id, target_id)
    local player = state.players[player_id]
    if player.hero ~= "jafar" then return false end

    state.jafar_du_ji = true

    local target = state.players[target_id]
    local bmsg = local_mgr.bc("skill_jafar_poison_plot", {
        username = player.username,
        target = target.username,
    })
    bmsg.hero = "jafar"
    bmsg.skill = "du_ji"
    dispatcher.broadcast_message(11, nk.json_encode(bmsg))

    return false
end

return M

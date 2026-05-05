local nk = require("nakama")
local M = {}

-- 贾法尔 - 大维齐尔，《一千零一夜》中的阴谋家
-- 技能：【毒计】 - 被动：你发动的【攻击】强制命中，目标无法使用【防御】抵挡

function M.on_before_attack(dispatcher, state, player_id, target_id)
    local player = state.players[player_id]

    if player.hero ~= "jafar" then
        return false
    end

    -- 标记本次攻击为强制命中，game_rules.handle_response 会检查此标志
    state.attack_forced = true

    local target = state.players[target_id]
    local target_name = target and target.username or target_id
    dispatcher.broadcast_message(11, nk.json_encode({
        content = player.username .. " 发动【毒计】，" .. target_name .. " 无法防御！",
        hero = "jafar",
        skill = "du_ji"
    }))

    return false  -- 不挂起，继续正常攻击流程
end

return M

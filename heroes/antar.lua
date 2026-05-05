local nk = require("nakama")
local M = {}

-- 安塔拉·伊本·沙达德 - 前伊斯兰时代最著名的阿拉伯骑士诗人
-- 技能：【骑士之誓】 - 每回合第一次攻击强制命中（对方无法防御）

function M.on_before_attack(dispatcher, state, player_id, target_id)
    local player = state.players[player_id]
    if player.hero ~= "antar" then return false end

    -- 每回合第一次攻击才触发
    if (player.attacks_this_turn or 0) > 0 then return false end

    state.attack_forced = true
    local target = state.players[target_id]
    dispatcher.broadcast_message(11, nk.json_encode({
        content = string.format("%s 发动【骑士之誓】，本次攻击强制命中，%s 无法防御！",
            player.username,
            target and target.username or target_id),
        hero = "antar", skill = "qi_shi_zhi_shi"
    }))
    return false
end

return M

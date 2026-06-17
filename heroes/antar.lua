local nk = require("nakama")
local local_mgr = require("localization_manager")
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
    local msg = local_mgr.bc("skill_antar_oath", {
        username = player.username,
        target = target.username,
    })
    msg.hero = "antar"
    msg.skill = "qi_shi_zhi_shi"
    dispatcher.broadcast_message(11, nk.json_encode(msg))
    return false
end

return M

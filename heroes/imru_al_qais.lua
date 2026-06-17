local nk = require("nakama")
local local_mgr = require("localization_manager")
local M = {}

-- 伊姆鲁勒盖斯 - 阿拉伯贾希利叶时期最伟大的诗人，"悬诗"诗人之首
-- 技能：【悬诗】 - 回合结束时，若手中【攻击】牌≥3张，额外摸1张牌

function M.on_turn_end(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "imru_al_qais" then return false end
    if player.health <= 0 then return false end

    local attack_count = 0
    for _, c in ipairs(player.hand) do
        if c.type == "ATTACK" then attack_count = attack_count + 1 end
    end

    if attack_count >= 3 then
        local rules = require("game_rules")
        rules.draw_cards(state, player_id, 1)
        local msg = local_mgr.bc("skill_imru_ode", {
            username = player.username,
            count = tostring(attack_count),
        })
        msg.hero = "imru_al_qais"
        msg.skill = "xuan_shi"
        dispatcher.broadcast_message(11, nk.json_encode(msg))
    end
    return false
end

return M

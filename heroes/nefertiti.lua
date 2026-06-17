local nk = require("nakama")
local local_mgr = require("localization_manager")
local M = {}

-- 纳芙蒂蒂 - 古埃及王后，"美人驾临"之意，中东文明圈代表性女性
-- 技能：【古仪】 - 回合结束时，若本回合未使用任何【攻击】牌，回复1点血量

function M.on_turn_end(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "nefertiti" then return false end
    if player.health <= 0 then return false end
    if player.health >= player.max_health then return false end

    -- attacks_this_turn 由引擎在 CARD_EFFECTS["ATTACK"] 中递增
    if (player.attacks_this_turn or 0) > 0 then return false end

    player.health = player.health + 1
    local msg = local_mgr.bc("skill_nefertiti_ancient_rite", {
        username = player.username,
    })
    msg.hero = "nefertiti"
    msg.skill = "gu_yi"
    dispatcher.broadcast_message(11, nk.json_encode(msg))
    return false
end

return M

local nk = require("nakama")
local M = {}

-- 吉尔伽美什 - 美索不达米亚神话中传奇的乌鲁克国王，三分之二神三分之一人
-- 技能：【不朽】 - 回合结束时，若血量<2，自动回复至2

function M.on_turn_end(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "gilgamesh" then return false end
    if player.health <= 0 then return false end
    if player.health >= 2 then return false end

    player.health = 2
    dispatcher.broadcast_message(11, nk.json_encode({
        content = string.format("%s 发动【不朽】，血量过低时自动回复至2点！",
            player.username),
        hero = "gilgamesh", skill = "bu_xiu"
    }))
    local rules = require("game_rules")
    rules.broadcast_update(dispatcher, state)
    return false
end

return M

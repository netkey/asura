local nk = require("nakama")
local M = {}

-- 帖木儿 - 14世纪中亚征服者，建立帖木儿帝国
-- 技能：【万骑】 - 击杀玩家后立刻摸3张牌

function M.on_kill(dispatcher, state, player_id, victim_id)
    local player = state.players[player_id]
    if player.hero ~= "tamerlane" then return false end

    local rules = require("game_rules")
    rules.draw_cards(state, player_id, 3)
    dispatcher.broadcast_message(11, nk.json_encode({
        content = string.format("%s 发动【万骑】，击杀后摸3张牌！",
            player.username),
        hero = "tamerlane", skill = "wan_qi"
    }))
    rules.broadcast_update(dispatcher, state)
    return false
end

return M

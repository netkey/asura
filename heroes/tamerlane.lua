local nk = require("nakama")
local M = {}

-- 帖木儿 - 14世纪中亚征服者，建立帖木儿帝国
-- 技能：【万骑】
--   每回合首次造成伤害时，摸1张牌
--   击杀玩家时，摸3张牌

function M.on_damage_dealt(dispatcher, state, player_id, amount, target_id)
    local player = state.players[player_id]
    if player.hero ~= "tamerlane" then return false end
    if player.tamerlane_drawn_this_turn then return false end

    player.tamerlane_drawn_this_turn = true

    local rules = require("game_rules")
    rules.draw_cards(state, player_id, 1)
    dispatcher.broadcast_message(11, nk.json_encode({
        content = string.format("%s activates [Ten Thousand Horsemen], draws 1 card after dealing damage!",
            player.username),
        hero = "tamerlane", skill = "wan_qi"
    }))
    return false
end

function M.on_kill(dispatcher, state, player_id, victim_id)
    local player = state.players[player_id]
    if player.hero ~= "tamerlane" then return false end

    local rules = require("game_rules")
    rules.draw_cards(state, player_id, 3)
    dispatcher.broadcast_message(11, nk.json_encode({
        content = string.format("%s activates [Ten Thousand Horsemen], draws 3 cards after killing!",
            player.username),
        hero = "tamerlane", skill = "wan_qi"
    }))
    return false
end

function M.on_turn_end(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "tamerlane" then return false end
    player.tamerlane_drawn_this_turn = false
    return false
end

return M

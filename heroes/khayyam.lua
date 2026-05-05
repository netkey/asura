local nk = require("nakama")
local M = {}

-- 海亚姆（奥马尔·海亚姆）- 波斯数学家、天文学家、诗人
-- 技能：【诗酒】 - 回合结束时，若弃牌堆≥5张，将弃牌堆洗回牌堆

function M.on_turn_end(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "khayyam" then return false end
    if #state.discard_pile < 5 then return false end

    local count = #state.discard_pile
    local rules = require("game_rules")
    state.deck = rules.shuffle(state.discard_pile)
    state.discard_pile = {}

    dispatcher.broadcast_message(11, nk.json_encode({
        content = string.format("%s 发动【诗酒】，将 %d 张弃牌洗回牌堆！",
            player.username, count),
        hero = "khayyam", skill = "shi_jiu"
    }))
    rules.broadcast_update(dispatcher, state)
    return false
end

return M

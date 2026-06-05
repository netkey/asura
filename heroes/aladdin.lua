local nk = require("nakama")
local M = {}

-- 阿拉丁 - 神灯主题英雄
-- 技能：【神灯】 - 出牌阶段开始时，判定牌堆顶一张牌：若为红色，摸1张牌

function M.on_play_phase_start(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "aladdin" then return false end

    local rules = require("game_rules")

    -- 牌堆空则先洗入弃牌堆
    if #state.deck == 0 then
        state.deck = rules.shuffle(state.discard_pile)
        state.discard_pile = {}
    end
    if #state.deck == 0 then return false end

    -- 揭示牌堆顶一张牌作为判定牌
    local judge_card = table.remove(state.deck, 1)
    table.insert(state.discard_pile, judge_card)

    dispatcher.broadcast_message(11, nk.json_encode({
        content = string.format("%s 发动【神灯】，判定为 %s（%s）",
            player.username,
            judge_card.suit == "HEART" and "♥ 红桃" or judge_card.suit == "DIAMOND" and "♦ 方块" or "♠♣ 黑色",
            judge_card.name),
        hero = "aladdin", skill = "shen_deng"
    }))

    -- 红色 → 神灯显灵，从牌堆摸1张
    if judge_card.suit == "HEART" or judge_card.suit == "DIAMOND" then
        rules.draw_cards(state, player_id, 1)
        dispatcher.broadcast_message(11, nk.json_encode({
            content = string.format("%s 神灯显灵，摸 1 张牌！", player.username),
            hero = "aladdin", skill = "shen_deng"
        }))
    end

    rules.broadcast_update(dispatcher, state)
    return false
end

return M

local nk = require("nakama")
local local_mgr = require("localization_manager")
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

    local msg = local_mgr.bc("skill_aladdin_magic_lamp", {
        username = player.username,
        suit_color = judge_card.suit == "HEART" and "♥ Hearts" or judge_card.suit == "DIAMOND" and "♦ Diamonds" or "♠♣ Black",
        card_id = local_mgr.card_lookup_key(judge_card.name),
    })
    msg.hero = "aladdin"
    msg.skill = "shen_deng"
    dispatcher.broadcast_message(11, nk.json_encode(msg))

    -- 红色 → 神灯显灵，从牌堆摸1张
    if judge_card.suit == "HEART" or judge_card.suit == "DIAMOND" then
        rules.draw_cards(state, player_id, 1)
        local msg2 = local_mgr.bc("skill_aladdin_awaken", {
            username = player.username,
        })
        msg2.hero = "aladdin"
        msg2.skill = "shen_deng"
        dispatcher.broadcast_message(11, nk.json_encode(msg2))
    end

    rules.broadcast_update(dispatcher, state)
    return false
end

return M

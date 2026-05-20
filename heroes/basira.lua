local nk = require("nakama")
local M = {}

-- 巴希拉 - 巴士拉著名女学者，以敏锐洞察力著称
-- 技能：【洞察】 - 摸牌阶段查看牌堆顶1张牌，红色（红桃/方块）则额外摸1张

function M.on_draw_phase_start(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "basira" then return false end

    local rules = require("game_rules")
    local deck = state.deck

    -- 查看牌堆顶
    if #deck == 0 then
        deck = rules.shuffle(state.discard_pile)
        state.deck = deck
        state.discard_pile = {}
    end

    local top_card = deck[#deck]
    local is_red = top_card and (top_card.suit == "HEART" or top_card.suit == "DIAMOND")

    -- 正常摸 2 张
    rules.draw_cards(state, player_id, 2)

    -- 红色额外摸 1 张
    if is_red then
        rules.draw_cards(state, player_id, 1)
    end

    dispatcher.broadcast_message(11, nk.json_encode({
        content = string.format("%s 发动【洞察】，牌堆顶是 %s %s（%s），%s！",
            player.username,
            top_card.suit or "?",
            top_card and top_card.name or "无牌",
            is_red and "红色" or "黑色",
            is_red and "额外摸1张！" or "无额外摸牌"),
        hero = "basira", skill = "dong_cha"
    }))
    rules.broadcast_update(dispatcher, state)
    return true
end

return M

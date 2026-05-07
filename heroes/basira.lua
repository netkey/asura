local nk = require("nakama")
local M = {}

-- 巴希拉 - 传说中守护正义的天使之一
-- 技能：【先知】 - 摸牌阶段开始时，可宣告一种花色；然后执行正常摸牌（2张）；第一张若花色匹配，额外摸1张（每回合限1次）

function M.on_draw_phase_start(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "basira" then return false end

    -- 每回合限制1次
    if player.basira_used then return false end

    local suits = {"HEART", "SPADE", "CLUB", "DIAMOND"}
    local guess = suits[math.random(4)]

    state.pending_action = {
        type = "BASIRA_XIAN_ZHI",
        player_id = player_id,
        hero_id = "basira",
        guess = guess,
        description = "是否发动【先知】？"
    }
    dispatcher.broadcast_message(101, nk.json_encode({
        type = "skill_choice",
        skill = "xian_zhi",
        description = string.format("是否发动【先知】？宣告一种花色，第一张摸牌若猜中，额外摸1张（AI自动猜%s）", guess),
        suits = suits, guess = guess
    }), {state.presences[player_id]})
    return true
end

function M.on_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action or action.type ~= "BASIRA_XIAN_ZHI" then return end

    local rules = require("game_rules")
    local player = state.players[player_id]
    player.basira_used = true

    if payload.confirm ~= true then
        state.pending_action = nil
        rules.draw_cards(state, player_id, 2)
        rules.broadcast_update(dispatcher, state)
        return
    end

    local guess = payload.guess or action.guess or "HEART"

    -- 摸第1张并检查花色（draw_cards 内已处理牌堆耗尽/洗牌逻辑）
    if #state.deck == 0 and #state.discard_pile == 0 then
        state.pending_action = nil
        return
    end
    if #state.deck == 0 then
        state.deck = rules.shuffle(state.discard_pile)
        state.discard_pile = {}
    end
    if #state.deck == 0 then
        state.pending_action = nil
        return
    end
    local first_card = table.remove(state.deck, 1)
    table.insert(player.hand, first_card)

    local hit = (first_card.suit == guess)
    dispatcher.broadcast_message(11, nk.json_encode({
        content = string.format("%s 发动【先知】猜%s，第一张摸到%s，%s！",
            player.username, guess,
            first_card.suit or "?",
            hit and "猜中，额外摸1张！" or "未猜中"),
        hero = "basira", skill = "xian_zhi"
    }))

    -- 摸第2张（固定）
    rules.draw_cards(state, player_id, 1)

    if hit then
        rules.draw_cards(state, player_id, 1)
    end

    rules.broadcast_update(dispatcher, state)
    state.pending_action = nil
end

return M

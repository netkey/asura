local nk = require("nakama")
local M = {}

-- 舍赫拉莎德 - 一千零一夜的讲述者
-- 技能：【千夜】 - 出牌阶段开始时，可弃置 1 张牌摸 2 张牌（净 +1）

function M.on_play_phase_start(dispatcher, state, player_id)
    local player = state.players[player_id]

    if player.hero ~= "scheherazade" then
        return false
    end

    -- 手牌为空则无法弃牌，跳过
    if #player.hand < 1 then
        return false
    end

    state.pending_action = {
        type = "SCHEHERAZADE_QIANYE",
        player_id = player_id,
        hero_id = "scheherazade",
        deadline = os.time() + 15,
        description = "是否弃置 1 张牌发动【千夜】，摸 2 张牌？"
    }

    dispatcher.broadcast_message(101, nk.json_encode({
        type = "skill_choice",
        skill = "qian_ye",
        description = "是否弃置 1 张牌发动【千夜】，摸 2 张牌？",
        min_cards = 1,
        max_cards = 1
    }), {state.presences[player_id]})

    return true
end

function M.on_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action or action.type ~= "SCHEHERAZADE_QIANYE" then
        return
    end

    if payload.confirm ~= true then
        state.pending_action = nil
        return
    end

    local rules = require("game_rules")
    local player = state.players[player_id]

    -- 弃置指定的 1 张牌
    local discarded = false
    if type(payload.card_ids) == "table" then
        for _, card_id in ipairs(payload.card_ids) do
            if type(card_id) ~= "string" then break end
            for i, card in ipairs(player.hand) do
                if card.id == card_id then
                    table.insert(state.discard_pile, table.remove(player.hand, i))
                    discarded = true
                    break
                end
            end
            if discarded then break end
        end
    end

    if discarded then
        rules.draw_cards(state, player_id, 2)
        dispatcher.broadcast_message(11, nk.json_encode({
            content = player.username .. " 发动【千夜】，弃 1 张牌摸 2 张牌！",
            hero = "scheherazade",
            skill = "qian_ye"
        }))
    end

    state.pending_action = nil
    rules.broadcast_update(dispatcher, state)
end

return M

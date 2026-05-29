local nk = require("nakama")
local M = {}

-- 阿拉丁 - 神灯主题英雄
-- 技能：【神灯】 - 出牌阶段，可弃置2张手牌，摸2张新牌（每回合限一次）

function M.on_play_phase_start(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "aladdin" then return false end
    if #player.hand < 2 then return false end

    state.pending_action = {
        type      = "ALADDIN_LAMP",
        player_id = player_id,
        hero_id   = "aladdin",
        deadline  = os.time() + 15,
    }

    dispatcher.broadcast_message(101, nk.json_encode({
        type        = "skill_choice",
        skill       = "shen_deng",
        description = "是否弃置2张牌发动【神灯】，摸2张牌？",
    }), {state.presences[player_id]})

    return true
end

function M.on_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action or action.type ~= "ALADDIN_LAMP" then return end
    if action.player_id ~= player_id then return end
    state.pending_action = nil

    if payload.confirm ~= true or type(payload.card_ids) ~= "table" then
        require("game_rules").broadcast_update(dispatcher, state)
        return
    end

    local rules = require("game_rules")
    local player = state.players[player_id]

    local to_discard = {}
    local seen = {}
    for _, card_id in ipairs(payload.card_ids) do
        if type(card_id) ~= "string" or seen[card_id] then goto continue end
        seen[card_id] = true
        for _, card in ipairs(player.hand) do
            if card.id == card_id then
                table.insert(to_discard, card.id)
                break
            end
        end
        if #to_discard >= 2 then break end
        ::continue::
    end

    if #to_discard >= 2 then
        for _, cid in ipairs(to_discard) do
            for i, card in ipairs(player.hand) do
                if card.id == cid then
                    table.insert(state.discard_pile, table.remove(player.hand, i))
                    break
                end
            end
        end
        rules.draw_cards(state, player_id, 2)
        dispatcher.broadcast_message(11, nk.json_encode({
            content = string.format("%s 发动【神灯】，弃置2张牌并摸2张牌！", player.username),
            hero = "aladdin", skill = "shen_deng"
        }))
    end
    rules.broadcast_update(dispatcher, state)
end

return M

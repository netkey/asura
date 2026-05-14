local nk = require("nakama")
local M = {}

-- 阿拉丁 - 神灯主题英雄
-- 技能：【神灯】 - 出牌阶段，可以弃置2张牌，视为使用一张【无中生有】

function M.on_play_phase_start(dispatcher, state, player_id)
    local player = state.players[player_id]

    -- 检查是否是阿拉丁
    if player.hero ~= "aladdin" then
        return false
    end

    -- 检查是否有足够的牌
    if #player.hand < 2 then
        return false
    end

    -- 挂起操作，询问玩家是否发动神灯技能
    state.pending_action = {
        type = "ALADDIN_LAMP",
        player_id = player_id,
        hero_id = "aladdin",
        description = "是否弃置2张牌发动【神灯】？"
    }

    dispatcher.broadcast_message(100, nk.json_encode({
        type = "skill_choice",
        skill = "shen_deng",
        description = "是否弃置2张牌发动【神灯】，摸2张牌？",
        min_cards = 2,
        max_cards = 2
    }), {state.presences[player_id]})

    return true  -- 挂起游戏流程
end

-- 处理神灯技能响应
function M.on_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action or action.type ~= "ALADDIN_LAMP" then
        return
    end

    if payload.confirm ~= true then
        state.pending_action = nil
        return
    end

    local rules = require("game_rules")
    local player = state.players[player_id]

    -- 校验 card_ids
    if type(payload.card_ids) ~= "table" or #payload.card_ids > 10 then
        state.pending_action = nil
        return
    end

    -- 先验证 2 张牌都存在于手牌中再弃置，避免部分弃牌无回滚
    local to_discard = {}
    for _, card_id in ipairs(payload.card_ids) do
        if type(card_id) ~= "string" then break end
        for _, card in ipairs(player.hand) do
            if card.id == card_id then
                table.insert(to_discard, card_id)
                break
            end
        end
        if #to_discard >= 2 then break end
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
        -- 摸2张牌
        rules.draw_cards(state, player_id, 2)

        dispatcher.broadcast_message(11, nk.json_encode({
            content = player.username .. " 发动【神灯】，弃置2张牌并摸2张牌！",
            hero = "aladdin",
            skill = "shen_deng"
        }))

        -- 同步状态
        rules.broadcast_update(dispatcher, state)
    end

    state.pending_action = nil
end

return M

local nk = require("nakama")
local M = {}

-- 比鲁尼 - 中世纪伊斯兰最伟大的百科全书式学者
-- 技能：【测量】 - 摸牌阶段，可跳过正常摸牌，改为看牌堆顶5张选1张入手，其余放回

function M.on_draw_phase_start(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "al_biruni" then return false end
    if #state.deck < 1 then return false end

    -- 取出牌堆顶最多5张供选择
    local peek_count = math.min(5, #state.deck)
    local cards = {}
    for i = 1, peek_count do
        table.insert(cards, state.deck[i])
    end

    state.pending_action = {
        type = "AL_BIRUNI_CELIANG",
        player_id = player_id,
        hero_id = "al_biruni",
        cards = cards,
        deadline = os.time() + 15,
        description = "是否发动【测量】？选1张牌入手，其余放回"
    }
    dispatcher.broadcast_message(101, nk.json_encode({
        type = "skill_choice",
        skill = "ce_liang",
        description = "发动【测量】：查看牌堆顶5张牌，选1张加入手牌，其余放回原位",
        cards = cards
    }), {state.presences[player_id]})
    return true  -- 挂起，跳过默认摸2张
end

function M.on_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action or action.type ~= "AL_BIRUNI_CELIANG" then return end

    local rules = require("game_rules")
    local player = state.players[player_id]

    if payload.confirm ~= true then
        -- 取消：正常摸2张
        state.pending_action = nil
        rules.draw_cards(state, player_id, 2)
        rules.broadcast_update(dispatcher, state)
        return
    end

    local chosen_id = type(payload.card_ids) == "table" and type(payload.card_ids[1]) == "string" and payload.card_ids[1]
    local chosen = nil
    if chosen_id then
        for i, c in ipairs(action.cards) do
            if c.id == chosen_id then
                chosen = c
                -- 从牌堆顶移除该张
                for j, dc in ipairs(state.deck) do
                    if dc.id == chosen_id then
                        table.remove(state.deck, j)
                        break
                    end
                end
                break
            end
        end
    end

    if chosen then
        table.insert(player.hand, chosen)
        dispatcher.broadcast_message(11, nk.json_encode({
            content = player.username .. " 发动【测量】，从5张牌中精选1张！",
            hero = "al_biruni", skill = "ce_liang"
        }))
    else
        -- 未有效选择，摸2张
        rules.draw_cards(state, player_id, 2)
    end
    rules.broadcast_update(dispatcher, state)
    state.pending_action = nil
end

return M

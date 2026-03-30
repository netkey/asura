local nk = require("nakama")
local M = {}

-- 技能：【星象】
function M.on_draw_phase_start(dispatcher, state, hakim_id)
    local hakim = state.players[hakim_id]
    local cards = {}
    local count = math.min(3, #state.deck)
    for i = 1, count do
        table.insert(cards, state.deck[i])
    end

    if #cards == 0 then return false end

    state.pending_action = {
        player_id = hakim_id,
        hero_id = "hakim",
        skill = "xing_xiang",
        cards = cards 
    }

    local msg = {
        prompt = "你发动了【星象】，请排列牌堆顶的 3 张牌：",
        skill_id = "xing_xiang",
        cards = cards
    }
    dispatcher.broadcast_message(102, nk.json_encode(msg), {state.presences[hakim_id]})

    return true 
end

-- 响应：哈基姆排列好顺序后返回
function M.on_response(dispatcher, state, player_id, payload)
    local new_order_ids = payload.sorted_ids
    
    -- 仅当收到有效的排序 ID 时才执行重排逻辑
    if new_order_ids and #new_order_ids > 0 then
        local temp_map = {}
        -- 缓存前几张牌
        for i = 1, math.min(5, #state.deck) do
            local card = state.deck[i]
            temp_map[card.id] = card
        end

        -- 移除旧牌
        local num_to_reorder = #new_order_ids
        for i = 1, num_to_reorder do
            table.remove(state.deck, 1)
        end

        -- 按新顺序插回
        for i = #new_order_ids, 1, -1 do
            local cid = new_order_ids[i]
            local card_obj = temp_map[cid]
            if card_obj then
                table.insert(state.deck, 1, card_obj)
            end
        end
        nk.logger_info("哈基姆已完成【星象】排列")
    end

    -- 无论是否排序成功，都必须执行的清理工作放在这里
    state.pending_action = nil

    local rules = require("game_rules")
    rules.draw_cards(state, player_id, 2)
    rules.broadcast_update(dispatcher, state)
end

return M

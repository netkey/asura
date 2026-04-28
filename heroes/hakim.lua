local nk = require("nakama")
local M = {}

-- 哈基姆 - 智者主题英雄
-- 技能：【星象】 - 在判定阶段，可以观看牌堆顶的3张牌并调整顺序

-- 触发时机：摸牌阶段开始前（可提前调整牌堆顶影响判定/摸牌结果）
function M.on_draw_phase_start(dispatcher, state, player_id)
    local player = state.players[player_id]

    -- 检查是否是哈基姆
    if player.hero ~= "hakim" then
        return false
    end

    -- 检查是否有判定牌
    if #player.judgments == 0 then
        return false
    end

    -- 检查牌堆是否有足够的牌
    if #state.deck < 3 then
        return false
    end

    -- 获取牌堆顶的3张牌
    local cards = {}
    for i = 1, 3 do
        if state.deck[i] then
            table.insert(cards, state.deck[i])
        end
    end

    if #cards == 0 then
        return false
    end

    -- 挂起操作，询问玩家是否调整判定牌顺序
    state.pending_action = {
        type = "HAKIM_XING_XIANG",
        player_id = player_id,
        hero_id = "hakim",
        cards = cards,
        description = "是否使用【星象】调整判定牌的顺序？"
    }

    dispatcher.broadcast_message(102, nk.json_encode({
        type = "skill_choice",
        skill = "xing_xiang",
        description = "你发动了【星象】，可以调整接下来3张判定牌的顺序",
        cards = cards
    }), {state.presences[player_id]})

    return true  -- 挂起等待玩家选择
end

-- 处理星象技能响应
function M.on_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action or action.type ~= "HAKIM_XING_XIANG" then
        return
    end

    -- 如果玩家取消，直接返回
    if payload.confirm ~= true then
        state.pending_action = nil
        return
    end

    -- 获取新的牌序
    local new_order_ids = payload.sorted_ids
    if not new_order_ids or #new_order_ids ~= #action.cards then
        state.pending_action = nil
        return
    end

    -- 重新排列牌堆顶的牌
    local temp_map = {}
    for i, card in ipairs(action.cards) do
        temp_map[card.id] = card
    end

    -- 移除原来的牌
    for i = 1, #action.cards do
        table.remove(state.deck, 1)
    end

    -- 按新顺序插入
    for i = #new_order_ids, 1, -1 do
        local card_id = new_order_ids[i]
        if temp_map[card_id] then
            table.insert(state.deck, 1, temp_map[card_id])
        end
    end

    local player = state.players[player_id]
    dispatcher.broadcast_message(11, nk.json_encode({
        content = player.username .. " 发动【星象】，改变了判定牌的顺序！",
        hero = "hakim",
        skill = "xing_xiang"
    }))

    state.pending_action = nil
end

return M

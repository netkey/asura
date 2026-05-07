local nk = require("nakama")
local M = {}

-- 哈基姆 - 智者主题英雄
-- 技能：【星象】 - 判定阶段开始前，可以观看牌堆顶3张牌并调整顺序，从而影响判定结果

-- 触发时机：判定阶段开始前（current player 有判定牌时）
function M.on_judgment_phase_start(dispatcher, state, player_id)
    local player = state.players[player_id]

    if player.hero ~= "hakim" then
        return false
    end

    -- 只有自己有判定牌时才触发（调用方已保证，这里双重校验）
    if #player.judgments == 0 then
        return false
    end

    if #state.deck < 1 then
        return false
    end

    -- 最多看3张，不足时看全部
    local peek_count = math.min(3, #state.deck)
    local peeked = {}
    for i = 1, peek_count do
        table.insert(peeked, state.deck[i])
    end

    state.pending_action = {
        type        = "HAKIM_XING_XIANG",
        player_id   = player_id,
        hero_id     = "hakim",
        peeked      = peeked,
        deadline    = os.time() + 20,
    }

    dispatcher.broadcast_message(102, nk.json_encode({
        type        = "skill_choice",
        skill       = "xing_xiang",
        description = "你可以使用【星象】调整接下来 " .. peek_count .. " 张牌的顺序以影响判定",
        cards       = peeked,
    }), {state.presences[player_id]})

    return true
end

-- 处理星象技能响应（confirm=false 或超时时直接放弃，恢复判定流程）
function M.on_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action or action.type ~= "HAKIM_XING_XIANG" then return end
    if action.player_id ~= player_id then return end

    local peeked = action.peeked

    if payload.confirm == true and type(payload.sorted_ids) == "table" and #payload.sorted_ids == #peeked then
        local id_map = {}
        for _, c in ipairs(peeked) do id_map[c.id] = c end

        local valid = true
        for _, sid in ipairs(payload.sorted_ids) do
            if not id_map[sid] then valid = false; break end
        end

        if valid then
            -- 移除原有牌
            for _ = 1, #peeked do table.remove(state.deck, 1) end
            -- 按客户端选择的顺序放回（index 1 = 牌堆顶）
            for i = #payload.sorted_ids, 1, -1 do
                table.insert(state.deck, 1, id_map[payload.sorted_ids[i]])
            end

            local player = state.players[player_id]
            dispatcher.broadcast_message(11, nk.json_encode({
                content = (player and player.username or "?") .. " 发动【星象】，调整了判定牌的顺序！",
                event   = "skill_used",
                hero    = "hakim",
                skill   = "xing_xiang",
            }))
        end
    end

    state.pending_action = nil
    -- 标记需要继续执行判定+摸牌阶段（match_loop 下一 tick 检测）
    state.pending_turn_continuation = {uid = player_id}
end

return M

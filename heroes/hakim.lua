local nk = require("nakama")
local M = {}

-- 哈基姆 - 法蒂玛王朝哈里发，神秘智者
-- 技能：【星象】 - 摸牌阶段，可看牌堆顶X张（X=存活玩家数），任意排序后放回，再正常摸2张

function M.on_draw_phase_start(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "hakim" then return false end

    -- X = 存活玩家数
    local alive = 0
    for _, p in pairs(state.players) do
        if p.health > 0 then alive = alive + 1 end
    end
    local peek_count = math.min(alive, #state.deck)
    if peek_count < 1 then return false end

    local cards = {}
    for i = 1, peek_count do
        local c = state.deck[i]
        table.insert(cards, {id = c.id, name = c.name, type = c.type, subtype = c.subtype, suit = c.suit, number = c.number})
    end

    state.pending_action = {
        type      = "HAKIM_XING_XIANG",
        player_id = player_id,
        hero_id   = "hakim",
        cards     = cards,
        deadline  = os.time() + 20,
    }

    dispatcher.broadcast_message(101, nk.json_encode({
        type        = "skill_choice",
        skill       = "xing_xiang",
        description = string.format("[Xing Xiang]: Peek at top %d card(s) of deck, reorder and put back, then draw 2", #cards),
        cards       = cards,
    }), {state.presences[player_id]})

    return true
end

function M.on_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action or action.type ~= "HAKIM_XING_XIANG" then return end
    if action.player_id ~= player_id then return end
    state.pending_action = nil

    local rules = require("game_rules")
    local player = state.players[player_id]

    if payload.confirm ~= true or type(payload.sorted_ids) ~= "table" or #payload.sorted_ids ~= #action.cards then
        rules.draw_cards(state, player_id, 2)
        rules.broadcast_update(dispatcher, state)
        return
    end

    -- 按 sorted_ids 构建重排后的牌列表
    local id_map = {}
    for _, c in ipairs(action.cards) do id_map[c.id] = c end
    local ordered = {}
    for _, sid in ipairs(payload.sorted_ids) do
        if id_map[sid] then table.insert(ordered, id_map[sid]) end
    end
    if #ordered ~= #action.cards then
        rules.draw_cards(state, player_id, 2)
        rules.broadcast_update(dispatcher, state)
        return
    end

    -- 移除原有牌
    for _ = 1, #action.cards do table.remove(state.deck, 1) end
    -- 按排列顺序放回牌堆顶（反向插入，index 1 = 牌堆顶）
    for i = #ordered, 1, -1 do
        table.insert(state.deck, 1, ordered[i])
    end

    dispatcher.broadcast_message(11, nk.json_encode({
        content = string.format("%s activated [Xing Xiang], reordered the top %d card(s) of the deck!",
            player.username, #action.cards),
        hero = "hakim", skill = "xing_xiang"
    }))

    rules.draw_cards(state, player_id, 2)
    rules.broadcast_update(dispatcher, state)
end

function M.on_timeout(dispatcher, state, act)
    state.pending_action = nil
    local player = state.players[act.player_id]
    if not player then return end
    local rules = require("game_rules")
    rules.draw_cards(state, act.player_id, 2)
    rules.broadcast_update(dispatcher, state)
end

return M

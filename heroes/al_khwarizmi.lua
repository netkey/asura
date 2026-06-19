local nk = require("nakama")
local local_mgr = require("localization_manager")
local M = {}

-- 花拉子密 - 代数之父，"算法"一词源于其名
-- 技能：【算法】 - 摸牌阶段，可看牌堆顶4张，任意排序后选择其中2张入手

function M.on_draw_phase_start(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "al_khwarizmi" then return false end

    local top_cards = {}
    for _ = 1, 4 do
        if #state.deck == 0 then
            local rules = require("game_rules")
            state.deck = rules.shuffle(state.discard_pile)
            state.discard_pile = {}
        end
        if #state.deck > 0 then
            local card = table.remove(state.deck, 1)
            if card then
                table.insert(top_cards, {id = card.id, name = card.name, type = card.type, subtype = card.subtype, suit = card.suit, number = card.number})
            end
        end
    end
    if #top_cards == 0 then return false end

    state.pending_action = {
        type      = "AL_KHWARIZMI_SUANFA",
        player_id = player_id,
        hero_id   = "al_khwarizmi",
        cards     = top_cards,
        deadline  = os.time() + 15,
    }

    local m = local_mgr.bc("skill_al_khwarizmi_algorithm_prompt")
    m.type  = "skill_choice"
    m.skill = "suan_fa"
    m.cards = top_cards
    dispatcher.broadcast_message(101, nk.json_encode(m), {state.presences[player_id]})

    return true
end

function M.on_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action or action.type ~= "AL_KHWARIZMI_SUANFA" then return end
    if action.player_id ~= player_id then return end
    state.pending_action = nil

    local rules = require("game_rules")
    local player = state.players[player_id]

    if payload.confirm ~= true or type(payload.sorted_ids) ~= "table" or type(payload.keep_ids) ~= "table" then
        -- 取消：回退4张牌到牌堆顶，正常摸2张
        for i = #action.cards, 1, -1 do
            local c = action.cards[i]
            table.insert(state.deck, 1, {id = c.id, name = c.name, type = c.type, subtype = c.subtype, suit = c.suit, number = c.number})
        end
        rules.draw_cards(state, player_id, 2)
        rules.broadcast_update(dispatcher, state)
        return
    end

    -- 构建 keep 集合
    local keep_set = {}
    for _, kid in ipairs(payload.keep_ids) do
        if type(kid) == "string" then keep_set[kid] = true end
    end

    -- 按 sorted_ids 顺序放回牌堆顶，keep 的牌入手
    local sorted_map = {}
    for _, c in ipairs(action.cards) do
        sorted_map[c.id] = c
    end

    local keep_count = 0
    -- 反向放入牌堆顶（因为前面的会先被 draw）
    for i = #payload.sorted_ids, 1, -1 do
        local c = sorted_map[payload.sorted_ids[i]]
        if c then
            if keep_set[c.id] then
                table.insert(player.hand, {id = c.id, name = c.name, type = c.type, subtype = c.subtype, suit = c.suit, number = c.number})
                keep_count = keep_count + 1
            else
                table.insert(state.deck, 1, {id = c.id, name = c.name, type = c.type, subtype = c.subtype, suit = c.suit, number = c.number})
            end
        end
    end

    if keep_count > 0 then
        local msg = local_mgr.bc("skill_al_khwarizmi_algorithm", {
            username = player.username,
            count = tostring(#action.cards),
            keep = tostring(keep_count),
        })
        msg.hero = "al_khwarizmi"
        msg.skill = "suan_fa"
        dispatcher.broadcast_message(11, nk.json_encode(msg))
    end

    rules.broadcast_update(dispatcher, state)
end

function M.on_timeout(dispatcher, state, act)
    state.pending_action = nil
    local player = state.players[act.player_id]
    if not player then return end
    -- 回退所有牌到牌堆顶
    for i = #act.cards, 1, -1 do
        local c = act.cards[i]
        table.insert(state.deck, 1, {id = c.id, name = c.name, type = c.type, subtype = c.subtype, suit = c.suit, number = c.number})
    end
    local rules = require("game_rules")
    rules.draw_cards(state, act.player_id, 2)
    rules.broadcast_update(dispatcher, state)
end

return M

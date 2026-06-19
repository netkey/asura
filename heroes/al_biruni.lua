local nk = require("nakama")
local local_mgr = require("localization_manager")
local M = {}

-- 比鲁尼 - 中世纪伊斯兰最伟大的百科全书式学者
-- 技能：【测量】 - 摸牌阶段，可看牌堆顶4张，选2张入手，其余弃置

function M.on_draw_phase_start(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "al_biruni" then return false end

    local peek_count = math.min(4, #state.deck)
    if peek_count < 1 then return false end

    local cards = {}
    for i = 1, peek_count do
        local c = state.deck[i]
        table.insert(cards, {id = c.id, name = c.name, type = c.type, subtype = c.subtype, suit = c.suit, number = c.number})
    end

    state.pending_action = {
        type      = "AL_BIRUNI_CELIANG",
        player_id = player_id,
        hero_id   = "al_biruni",
        cards     = cards,
        deadline  = os.time() + 15,
    }

    local m = local_mgr.bc("skill_al_biruni_measure_prompt", { count = #cards })
    m.type  = "skill_choice"
    m.skill = "ce_liang"
    m.cards = cards
    dispatcher.broadcast_message(101, nk.json_encode(m), {state.presences[player_id]})

    return true
end

function M.on_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action or action.type ~= "AL_BIRUNI_CELIANG" then return end
    if action.player_id ~= player_id then return end
    state.pending_action = nil

    local rules = require("game_rules")
    local player = state.players[player_id]

    if payload.confirm ~= true or type(payload.keep_ids) ~= "table" or #payload.keep_ids == 0 then
        rules.draw_cards(state, player_id, 2)
        rules.broadcast_update(dispatcher, state)
        return
    end

    -- 构建配置：哪些卡是 keep，哪些是 discard
    local keep_set = {}
    for _, kid in ipairs(payload.keep_ids) do
        if type(kid) == "string" then keep_set[kid] = true end
    end

    -- 移除原有的 peeked cards
    for _ = 1, #action.cards do table.remove(state.deck, 1) end

    local kept = 0
    for _, c in ipairs(action.cards) do
        if keep_set[c.id] and kept < 2 then
            table.insert(player.hand, c)
            kept = kept + 1
        else
            table.insert(state.discard_pile, c)
        end
    end

    if kept > 0 then
        local msg = local_mgr.bc("skill_al_biruni_measure", {
            username = player.username,
            count = tostring(kept),
        })
        msg.hero = "al_biruni"
        msg.skill = "ce_liang"
        dispatcher.broadcast_message(11, nk.json_encode(msg))
    end

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

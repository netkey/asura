local nk = require("nakama")
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
        table.insert(cards, {id = c.id, name = c.name, type = c.type, suit = c.suit, number = c.number})
    end

    state.pending_action = {
        type      = "AL_BIRUNI_CELIANG",
        player_id = player_id,
        hero_id   = "al_biruni",
        cards     = cards,
        deadline  = os.time() + 15,
    }

    dispatcher.broadcast_message(101, nk.json_encode({
        type        = "skill_choice",
        skill       = "ce_liang",
        description = string.format("【测量】：查看牌堆顶%d张，选2张入手，其余弃置", #cards),
        cards       = cards,
    }), {state.presences[player_id]})

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

    local config = {}
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
        dispatcher.broadcast_message(11, nk.json_encode({
            content = string.format("%s 发动【测量】，从%d张牌中精选%d张入手！",
                player.username, #action.cards, kept),
            hero = "al_biruni", skill = "ce_liang"
        }))
    end

    rules.broadcast_update(dispatcher, state)
end

return M

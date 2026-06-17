local nk = require("nakama")
local M = {}

-- 伊本·西拿（阿维森纳）- 医学泰斗
-- 技能：【医典】
--   自诊：出牌阶段，可弃1张红桃牌回复自己1点血量（每回合限1次）
--   济世：有人濒死时，可用红桃牌代替治疗牌进行救援（game_rules 中实现）

function M.on_play_phase_start(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "avicenna" then return false end
    if player.health <= 0 then return false end
    if player.health >= player.max_health then return false end
    if #player.hand < 1 then return false end

    local heart_cards = {}
    for _, c in ipairs(player.hand) do
        if c.suit == "HEART" then
            table.insert(heart_cards, {id = c.id, name = c.name, type = c.type})
        end
    end
    if #heart_cards == 0 then return false end

    state.pending_action = {
        type        = "AVICENNA_ZHEN",
        player_id   = player_id,
        hero_id     = "avicenna",
        heart_cards = heart_cards,
        deadline    = os.time() + 15,
    }

    dispatcher.broadcast_message(101, nk.json_encode({
        type        = "skill_choice",
        skill       = "yi_dian",
        description = "Discard 1 heart card to activate [Canon of Medicine: Self-Diagnosis] and recover 1 HP?",
        heart_cards = heart_cards,
    }), {state.presences[player_id]})

    return true
end

function M.on_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action or action.hero_id ~= "avicenna" then return end
    if action.player_id ~= player_id then return end

    if action.type == "AVICENNA_ZHEN" then
        state.pending_action = nil
        if payload.confirm ~= true or type(payload.card_id) ~= "string" then
            require("game_rules").broadcast_update(dispatcher, state)
            return
        end

        local player = state.players[player_id]
        for i, c in ipairs(player.hand) do
            if c.id == payload.card_id and c.suit == "HEART" then
                table.insert(state.discard_pile, table.remove(player.hand, i))
                player.health = math.min(player.health + 1, player.max_health)
                dispatcher.broadcast_message(11, nk.json_encode({
                    content = string.format("%s discards heart card [%s], activating [Canon of Medicine: Self-Diagnosis] to recover 1 HP!",
                        player.username, c.name),
                    hero = "avicenna", skill = "yi_dian"
                }))
                break
            end
        end

        local rules = require("game_rules")
        rules.broadcast_update(dispatcher, state)
    end
end

function M.on_timeout(dispatcher, state, act)
    state.pending_action = nil
    -- 超时时玩家已死，直接跳过（防死锁）
    if not state.players[act.player_id] or state.players[act.player_id].health <= 0 then
        require("game_rules").broadcast_update(dispatcher, state)
        return
    end
    if act.heart_cards and #act.heart_cards > 0 then
        require("hero_manager").handle_response(dispatcher, state, act.player_id,
            { confirm = true, card_id = act.heart_cards[1].id })
    else
        require("hero_manager").handle_response(dispatcher, state, act.player_id, { confirm = false })
    end
end

function M.can_rescue_with(card)
    return card.suit == "HEART"
end

return M

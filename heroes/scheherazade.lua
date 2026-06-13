local nk = require("nakama")
local M = {}

-- 舍赫拉莎德 - 一千零一夜的讲述者
-- 技能：【千夜】 - 受到攻击伤害时，可弃1张手牌，随机看攻击者2张手牌并选择1张弃置

function M.on_damaged(dispatcher, state, target_id, amount, source_id)
    local player = state.players[target_id]
    if player.hero ~= "scheherazade" then return false end
    if player.health <= 0 then return false end
    if #player.hand < 1 then return false end

    -- 不打断 AOE 或其他待响应操作
    if state.pending_action then return false end

    local attacker = state.players[source_id]
    if not attacker or attacker.health <= 0 or #attacker.hand < 1 then return false end

    -- 从攻击者手牌随机抽 min(2, 手牌数) 张展示
    local rules = require("game_rules")
    local pool = {}
    for _, c in ipairs(attacker.hand) do
        table.insert(pool, c)
    end
    pool = rules.shuffle(pool)
    local shown = {}
    for i = 1, math.min(2, #pool) do
        table.insert(shown, {id = pool[i].id, name = pool[i].name, type = pool[i].type, suit = pool[i].suit})
    end

    state.pending_action = {
        type        = "SCHEHERAZADE_QIANYE",
        player_id   = target_id,
        hero_id     = "scheherazade",
        attacker_id = source_id,
        shown_cards = shown,
        deadline    = os.time() + 15,
    }

    dispatcher.broadcast_message(101, nk.json_encode({
        type        = "skill_choice",
        skill       = "qian_ye",
        description = string.format("%s dealt %d damage to you! Activate [Thousand Nights]? Discard 1 card and choose 1 of their cards to discard.",
            attacker.username, amount),
        shown_cards = shown,
    }), {state.presences[target_id]})

    return false
end

function M.on_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action or action.type ~= "SCHEHERAZADE_QIANYE" then return end
    if action.player_id ~= player_id then return end
    state.pending_action = nil

    if payload.confirm ~= true or type(payload.own_card_id) ~= "string" or type(payload.target_card_id) ~= "string" then
        require("game_rules").broadcast_update(dispatcher, state)
        return
    end

    local rules = require("game_rules")
    local player    = state.players[player_id]
    local attacker  = state.players[action.attacker_id]
    if not player or not attacker then
        rules.broadcast_update(dispatcher, state)
        return
    end

    -- 1. 弃置自己选择的1张牌（代价）
    local cost_paid = false
    for i, c in ipairs(player.hand) do
        if c.id == payload.own_card_id then
            table.insert(state.discard_pile, table.remove(player.hand, i))
            cost_paid = true
            break
        end
    end
    if not cost_paid then
        rules.broadcast_update(dispatcher, state)
        return
    end

    -- 2. 弃置攻击者被选择的那张牌
    for i, c in ipairs(attacker.hand) do
        if c.id == payload.target_card_id then
            table.insert(state.discard_pile, table.remove(attacker.hand, i))
            dispatcher.broadcast_message(11, nk.json_encode({
                content = string.format("%s activated [Thousand Nights], discarded 1 card and forced %s to discard [%s]!",
                    player.username, attacker.username, c.name),
                hero = "scheherazade", skill = "qian_ye"
            }))
            break
        end
    end

    rules.broadcast_update(dispatcher, state)
end

return M

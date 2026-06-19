local nk = require("nakama")
local local_mgr = require("localization_manager")
local M = {}

-- 吉尔伽美什 - 美索不达米亚神话中传奇的乌鲁克国王，追寻永生
-- 技能：【不朽】 - 回合结束时，若血量<2，可弃1张牌回复1点血量

function M.on_turn_end(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "gilgamesh" then return false end
    if player.health <= 0 then return false end
    if player.health >= 2 then return false end
    if #player.hand < 1 then return false end

    local cards = {}
    for _, c in ipairs(player.hand) do
        table.insert(cards, {id = c.id, name = c.name})
    end

    state.pending_action = {
        type      = "GILGAMESH_BU_XIU",
        player_id = player_id,
        hero_id   = "gilgamesh",
        cards     = cards,
        deadline  = os.time() + 15,
    }

    local m = local_mgr.bc("skill_gilgamesh_bu_xiu_prompt")
    m.type  = "skill_choice"
    m.skill = "bu_xiu"
    m.cards = cards
    dispatcher.broadcast_message(101, nk.json_encode(m), {state.presences[player_id]})

    return true
end

function M.on_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action or action.type ~= "GILGAMESH_BU_XIU" then return end
    if action.player_id ~= player_id then return end
    state.pending_action = nil

    if payload.confirm ~= true or type(payload.card_id) ~= "string" then
        local rules = require("game_rules")
        rules.broadcast_update(dispatcher, state)
        return
    end

    local player = state.players[player_id]
    for i, c in ipairs(player.hand) do
        if c.id == payload.card_id then
            table.insert(state.discard_pile, table.remove(player.hand, i))
            player.health = math.min(player.health + 1, player.max_health)
            local msg = local_mgr.bc("skill_gilgamesh_immortal", {
                username = player.username,
                card_id = local_mgr.card_lookup_key(c.name),
            })
            msg.hero = "gilgamesh"
            msg.skill = "bu_xiu"
            dispatcher.broadcast_message(11, nk.json_encode(msg))
            break
        end
    end

    local rules = require("game_rules")
    rules.broadcast_update(dispatcher, state)
end

function M.on_timeout(dispatcher, state, act)
    local hero_mgr = require("hero_manager")
    if act.cards and #act.cards > 0 then
        hero_mgr.handle_response(dispatcher, state, act.player_id,
            { confirm = true, card_id = act.cards[1].id })
    else
        hero_mgr.handle_response(dispatcher, state, act.player_id, { confirm = false })
    end
end

return M

local nk = require("nakama")
local local_mgr = require("localization_manager")
local M = {}

-- 恩赫杜安娜 - 公元前22世纪的苏美尔诗人/神职人员，人类历史上第一位已知姓名的作家
-- 技能：【颂词】 - 摸牌阶段，可选择发动：摸4张牌，然后选择一名其他角色，交给其1张手牌

function M.on_draw_phase_start(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "enheduanna" then return false end
    if player.health <= 0 then return false end

    local has_other = false
    for uid, p in pairs(state.players) do
        if uid ~= player_id and p.health > 0 then
            has_other = true
            break
        end
    end
    if not has_other then return false end

    state.pending_action = {
        type      = "ENHEDUANNA_SONG_CI",
        player_id = player_id,
        hero_id   = "enheduanna",
        deadline  = os.time() + 15,
    }

    dispatcher.broadcast_message(101, nk.json_encode({
        type        = "skill_choice",
        skill       = "song_ci",
        description = "Activate [Song Ci] to draw 4 cards, then give 1 hand card to another character?",
    }), {state.presences[player_id]})

    return true
end

function M.on_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action or action.hero_id ~= "enheduanna" then return end
    if action.player_id ~= player_id then return end

    local rules = require("game_rules")

    if action.type == "ENHEDUANNA_SONG_CI" then
        state.pending_action = nil

        if payload.confirm ~= true then
            rules.draw_cards(state, player_id, 2)
            rules.broadcast_update(dispatcher, state)
            return
        end

        -- 发动：摸4张牌
        rules.draw_cards(state, player_id, 4)
        local player = state.players[player_id]

        local targets = {}
        for uid, p in pairs(state.players) do
            if uid ~= player_id and p.health > 0 then
                table.insert(targets, {id = uid, name = p.username})
            end
        end

        local hand_cards = {}
        for _, c in ipairs(player.hand) do
            table.insert(hand_cards, {id = c.id, name = c.name, type = c.type, suit = c.suit})
        end

        state.pending_action = {
            type       = "ENHEDUANNA_SONG_CI_GIVE",
            player_id  = player_id,
            hero_id    = "enheduanna",
            hand_cards = hand_cards,
            targets    = targets,
            deadline   = os.time() + 15,
        }

        dispatcher.broadcast_message(101, nk.json_encode({
            type        = "skill_choice",
            skill       = "song_ci_give",
            description = "Select 1 hand card to give to another character",
            hand_cards  = hand_cards,
            targets     = targets,
        }), {state.presences[player_id]})

        rules.broadcast_update(dispatcher, state)

    elseif action.type == "ENHEDUANNA_SONG_CI_GIVE" then
        state.pending_action = nil
        local player = state.players[player_id]

        if payload.confirm ~= true or type(payload.card_id) ~= "string" or type(payload.target_id) ~= "string" then
            -- 无效响应：取第一张手牌给第一个可选目标
            if player and #player.hand > 0 then
                local card = table.remove(player.hand, 1)
                local given = false
                for uid, p in pairs(state.players) do
                    if uid ~= player_id and p.health > 0 then
                        table.insert(p.hand, card)
                        given = true
                        break
                    end
                end
                if not given then
                    table.insert(state.discard_pile, card)
                end
            end
        else
            for i, c in ipairs(player.hand) do
                if c.id == payload.card_id then
                    local card = table.remove(player.hand, i)
                    local target = state.players[payload.target_id]
                    if target and target.health > 0 then
                        table.insert(target.hand, card)
                        local msg = local_mgr.bc("skill_enheduanna_song_ci", {
                            username = player.username,
                            target = target.username,
                            card_id = local_mgr.card_lookup_key(c.name),
                        })
                        msg.hero = "enheduanna"
                        msg.skill = "song_ci"
                        dispatcher.broadcast_message(11, nk.json_encode(msg))
                    else
                        table.insert(state.discard_pile, card)
                    end
                    break
                end
            end
        end

        rules.broadcast_update(dispatcher, state)
    end
end

function M.on_timeout(dispatcher, state, act)
    local hero_mgr = require("hero_manager")
    if act.type == "ENHEDUANNA_SONG_CI_GIVE" then
        if act.hand_cards and #act.hand_cards > 0 and act.targets and #act.targets > 0 then
            hero_mgr.handle_response(dispatcher, state, act.player_id,
                { confirm = true, card_id = act.hand_cards[1].id, target_id = act.targets[1].id })
        else
            hero_mgr.handle_response(dispatcher, state, act.player_id, { confirm = true })
        end
    else
        hero_mgr.handle_response(dispatcher, state, act.player_id, { confirm = true })
    end
end

return M

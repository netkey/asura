local nk = require("nakama")
local local_mgr = require("localization_manager")
local M = {}

-- 鲁米 - 波斯诗人与哲人，旋转舞创始人
-- 技能：【旋回】 - 出牌阶段开始时，可将全部手牌弃置，摸等量新牌

function M.on_play_phase_start(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "rumi" then return false end
    if #player.hand < 1 then return false end

    state.pending_action = {
        type = "RUMI_XUANHUI",
        player_id = player_id,
        hero_id = "rumi",
        hand_count = #player.hand,
        deadline = os.time() + 15,
        description = "Activate [Whirl], discard all to draw equal?",
    }
    local m = local_mgr.bc("skill_rumi_whirl_prompt", { hand_count = #player.hand })
    m.type = "skill_choice"
    m.skill = "xuan_hui"
    dispatcher.broadcast_message(101, nk.json_encode(m), {state.presences[player_id]})
    return true
end

function M.on_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action or action.type ~= "RUMI_XUANHUI" then return end
    if action.player_id ~= player_id then return end

    if payload.confirm ~= true then
        state.pending_action = nil
        require("game_rules").broadcast_update(dispatcher, state)
        return
    end

    local rules = require("game_rules")
    local player = state.players[player_id]
    local count = #player.hand

    -- 弃置全部手牌
    for i = #player.hand, 1, -1 do
        table.insert(state.discard_pile, table.remove(player.hand))
    end

    -- 摸等量新牌
    rules.draw_cards(state, player_id, count)
    local msg = local_mgr.bc("skill_rumi_whirl", {
        username = player.username,
    })
    msg.hero = "rumi"
    msg.skill = "xuan_hui"
    dispatcher.broadcast_message(11, nk.json_encode(msg))
    state.pending_action = nil
    rules.broadcast_update(dispatcher, state)
end

function M.on_timeout(dispatcher, state, act)
    local hero_mgr = require("hero_manager")
    hero_mgr.handle_response(dispatcher, state, act.player_id, { confirm = true })
end

return M

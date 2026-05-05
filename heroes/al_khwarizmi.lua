local nk = require("nakama")
local M = {}

-- 花拉子密 - 代数之父，算法之名源于此
-- 技能：【算法】 - 摸牌阶段，可弃1张手牌改为摸3张（净+2）

function M.on_draw_phase_start(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "al_khwarizmi" then return false end
    if #player.hand < 1 then return false end

    state.pending_action = {
        type = "AL_KHWARIZMI_SUANFA",
        player_id = player_id,
        hero_id = "al_khwarizmi",
        description = "是否弃1张牌发动【算法】，改为摸3张牌？"
    }
    dispatcher.broadcast_message(101, nk.json_encode({
        type = "skill_choice",
        skill = "suan_fa",
        description = "是否弃1张牌发动【算法】，改为摸3张牌（净+2）？",
        min_cards = 1, max_cards = 1
    }), {state.presences[player_id]})
    return true  -- 挂起，跳过默认摸2张
end

function M.on_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action or action.type ~= "AL_KHWARIZMI_SUANFA" then return end

    local rules = require("game_rules")
    local player = state.players[player_id]

    if payload.confirm ~= true then
        -- 取消：执行正常摸2张
        state.pending_action = nil
        rules.draw_cards(state, player_id, 2)
        rules.broadcast_update(dispatcher, state)
        return
    end

    local discarded = false
    for _, cid in ipairs(payload.card_ids or {}) do
        for i, c in ipairs(player.hand) do
            if c.id == cid then
                table.insert(state.discard_pile, table.remove(player.hand, i))
                discarded = true
                break
            end
        end
        if discarded then break end
    end

    if discarded then
        rules.draw_cards(state, player_id, 3)
        dispatcher.broadcast_message(11, nk.json_encode({
            content = player.username .. " 发动【算法】，弃1张牌摸3张牌！",
            hero = "al_khwarizmi", skill = "suan_fa"
        }))
    else
        rules.draw_cards(state, player_id, 2)
    end
    rules.broadcast_update(dispatcher, state)
    state.pending_action = nil
end

return M

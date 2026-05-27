local nk = require("nakama")
local M = {}

-- 伊本·白图泰 - 史上最伟大旅行家
-- 技能：【远行】 - 出牌阶段开始时，可弃1张牌，从弃牌堆顶取1张牌入手

function M.on_play_phase_start(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "ibn_battuta" then return false end
    if #player.hand < 1 then return false end
    if #state.discard_pile == 0 then return false end

    state.pending_action = {
        type = "IBN_BATTUTA_YUAN_XING",
        player_id = player_id,
        hero_id = "ibn_battuta",
        deadline = os.time() + 15,
        description = "是否弃1张牌发动【远行】，取弃牌堆顶1张牌入手？"
    }
    dispatcher.broadcast_message(101, nk.json_encode({
        type = "skill_choice",
        skill = "yuan_xing",
        description = "是否弃1张牌发动【远行】，从弃牌堆顶取1张牌？",
        min_cards = 1, max_cards = 1
    }), {state.presences[player_id]})
    return true
end

function M.on_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action or action.type ~= "IBN_BATTUTA_YUAN_XING" then return end

    if payload.confirm ~= true then
        state.pending_action = nil
        require("game_rules").broadcast_update(dispatcher, state)
        return
    end

    local rules = require("game_rules")
    local player = state.players[player_id]

    -- 弃指定的1张牌
    local discarded = false
    if type(payload.card_ids) == "table" then
        for _, cid in ipairs(payload.card_ids) do
            if type(cid) ~= "string" then break end
            for i, c in ipairs(player.hand) do
                if c.id == cid then
                    table.insert(state.discard_pile, table.remove(player.hand, i))
                    discarded = true
                    break
                end
            end
            if discarded then break end
        end
    end

    if discarded and #state.discard_pile >= 2 then
        -- 取弃牌堆中自己刚弃的那张之前的牌（自己刚弃的在堆顶）
        local taken = table.remove(state.discard_pile, #state.discard_pile - 1)
        table.insert(player.hand, taken)
        dispatcher.broadcast_message(11, nk.json_encode({
            content = player.username .. " 发动【远行】，以牌换牌！",
            hero = "ibn_battuta", skill = "yuan_xing"
        }))
    end
    state.pending_action = nil
    rules.broadcast_update(dispatcher, state)
end

return M

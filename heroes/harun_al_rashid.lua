local nk = require("nakama")
local M = {}

-- 哈伦·拉希德 - 阿拔斯王朝最鼎盛时期的哈里发
-- 技能：【哈里发令】 - 出牌阶段，可指定一名其他玩家，令其选择：弃置1张牌，或受到1点伤害

function M.on_play_phase_start(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "harun_al_rashid" then return false end

    local targets = {}
    for uid, p in pairs(state.players) do
        if uid ~= player_id and p.health > 0 then
            table.insert(targets, uid)
        end
    end
    if #targets == 0 then return false end

    local target_list = {}
    for _, uid in ipairs(targets) do
        table.insert(target_list, { id = uid, username = state.players[uid].username })
    end

    state.pending_action = {
        type        = "HARUN_SELECT_TARGET",
        player_id   = player_id,
        hero_id     = "harun_al_rashid",
        targets     = target_list,
        deadline    = os.time() + 15,
    }

    dispatcher.broadcast_message(101, nk.json_encode({
        type        = "skill_choice",
        skill       = "ha_li_fa_ling",
        description = "是否发动【哈里发令】？选择一名玩家令其弃1张牌或受1点伤害",
        targets     = target_list,
    }), { state.presences[player_id] })

    return true
end

function M.on_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action then return end

    local rules = require("game_rules")

    -- 第一步：施法者选择目标
    if action.type == "HARUN_SELECT_TARGET" then
        if action.player_id ~= player_id then return end
        state.pending_action = nil

        if payload.confirm ~= true or type(payload.target_id) ~= "string" then
            rules.broadcast_update(dispatcher, state)
            return
        end
        local target = state.players[payload.target_id]
        if not target or target.health <= 0 or payload.target_id == player_id then
            rules.broadcast_update(dispatcher, state)
            return
        end

        local player = state.players[player_id]
        dispatcher.broadcast_message(11, nk.json_encode({
            content   = string.format("%s 发动【哈里发令】，指定 %s：弃1张牌或受1点伤害",
                            player.username, target.username),
            event     = "skill_used",
            hero      = "harun_al_rashid",
            skill     = "ha_li_fa_ling",
            target_id = payload.target_id,
        }))

        state.pending_action = {
            type        = "HARUN_CHOOSE",
            player_id   = payload.target_id,
            hero_id     = "harun_al_rashid",
            caster_id   = player_id,
            target_id   = payload.target_id,
            deadline    = os.time() + 15,
        }
        dispatcher.broadcast_message(101, nk.json_encode({
            type        = "skill_choice",
            skill       = "ha_li_fa_ling",
            description = string.format("%s 对你发动【哈里发令】，请选择：弃1张牌或受1点伤害",
                              player.username),
            caster_id   = player_id,
        }), { state.presences[payload.target_id] })
        return
    end

    -- 第二步：目标玩家选择弃牌或受伤
    if action.type == "HARUN_CHOOSE" then
        if action.player_id ~= player_id then return end

        local target    = state.players[action.target_id]
        local caster_id = action.caster_id

        if target and target.health > 0 then
            if payload.confirm == true and payload.choose_discard and #target.hand > 0 then
                local card = table.remove(target.hand, math.random(#target.hand))
                table.insert(state.discard_pile, card)
                dispatcher.broadcast_message(11, nk.json_encode({
                    content = target.username .. " 服从【哈里发令】，弃置了1张牌",
                }))
            else
                rules.apply_damage(dispatcher, state, action.target_id, 1, caster_id)
            end
        end

        if not (state.pending_action and state.pending_action.type == "WAITING_FOR_RESCUE") then
            state.pending_action = nil
            rules.broadcast_update(dispatcher, state)
        end
    end
end

return M

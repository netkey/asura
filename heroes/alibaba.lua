local nk = require("nakama")
local M = {}

-- 阿里巴巴 - 盗贼主题英雄
-- 技能：【暗号】 - 成功防御后，可以对攻击者使用一张【攻击】

function M.on_attack_defended(dispatcher, state, defender_id, attacker_id)
    local defender = state.players[defender_id]

    -- 检查是否是阿里巴巴
    if defender.hero ~= "alibaba" then
        return false
    end

    -- 检查是否有攻击牌
    local has_attack = false
    for _, card in ipairs(defender.hand) do
        if card.type == "ATTACK" then
            has_attack = true
            break
        end
    end

    if not has_attack then
        return false
    end

    -- 记录挂起状态，询问是否反击
    state.pending_action = {
        type = "ALIBABA_COUNTER",
        player_id = defender_id,
        hero_id = "alibaba",
        attacker_id = attacker_id,
        deadline = os.time() + 15,
        description = "是否对攻击者使用一张【攻击】进行反击？"
    }

    dispatcher.broadcast_message(101, nk.json_encode({
        type = "skill_choice",
        skill = "an_hao",
        description = "防御成功！是否发动【暗号】对攻击者反击？",
        attacker_id = attacker_id
    }), {state.presences[defender_id]})

    return true  -- 挂起等待玩家选择
end

-- 处理反击响应
function M.on_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action or action.type ~= "ALIBABA_COUNTER" then
        return
    end

    local rules = require("game_rules")

    if payload.confirm ~= true then
        state.pending_action = nil
        rules.broadcast_update(dispatcher, state)
        return
    end

    local defender = state.players[player_id]
    local attacker_id = action.attacker_id

    -- 找到一张攻击牌并使用
    for i, card in ipairs(defender.hand) do
        if card.type == "ATTACK" then
            -- 移除攻击牌
            table.remove(defender.hand, i)
            table.insert(state.discard_pile, card)

            -- 对攻击者使用攻击
            local attacker_name = "已阵亡玩家"
            if state.players[attacker_id] then
                attacker_name = state.players[attacker_id].username
            end
            dispatcher.broadcast_message(11, nk.json_encode({
                content = defender.username .. " 发动【暗号】，对 " .. attacker_name .. " 进行反击！",
                hero = "alibaba",
                skill = "an_hao"
            }))

            -- 攻击者可能已阵亡，跳过反击
            if not state.players[attacker_id] then
                state.pending_action = nil
                rules.broadcast_update(dispatcher, state)
                return
            end

            -- 反击固定1点伤害，不受武器/酒加成
            state._fixed_damage = true
            rules.apply_damage(dispatcher, state, attacker_id, 1, player_id)
            state._fixed_damage = nil
            break
        end
    end

    -- 只在 apply_damage 未触发濒死救援时才清除，避免覆盖 WAITING_FOR_RESCUE
    if not (state.pending_action and state.pending_action.type == "WAITING_FOR_RESCUE") then
        state.pending_action = nil
        rules.broadcast_update(dispatcher, state)
    end
end

return M

local nk = require("nakama")
local M = {}

-- 双角王（Dhul-Qarnayn）- 古代中东传说中的伟大君主，铁壁守护者
-- 技能：【铁壁】
--   受到伤害时，可弃1张基本牌减伤1点（每回合限1次）
--   击杀玩家时，在其弃牌之前收缴其1张随机手牌

local BASIC_TYPES = { ATTACK = true, DEFENSE = true, HEAL = true }

function M.on_before_damage(dispatcher, state, target_id, amount, source_id)
    local player = state.players[target_id]
    if player.hero ~= "dhul_qarnayn" then return false end
    if player.dhul_qarnayn_iron_wall_used then return false end

    -- 找一张基本牌弃置
    local card_idx
    for i, c in ipairs(player.hand) do
        if BASIC_TYPES[c.type] then
            card_idx = i
            break
        end
    end
    if not card_idx then return false end

    player.dhul_qarnayn_iron_wall_used = true
    local discarded = table.remove(player.hand, card_idx)
    table.insert(state.discard_pile, discarded)

    dispatcher.broadcast_message(11, nk.json_encode({
        content = string.format("%s 发动【铁壁】，弃置【%s】减免1点伤害！",
            player.username, discarded.name),
        hero = "dhul_qarnayn", skill = "tie_bi"
    }))
    local rules = require("game_rules")
    rules.broadcast_update(dispatcher, state)
    return true
end

function M.on_kill(dispatcher, state, player_id, victim_id)
    local player = state.players[player_id]
    if player.hero ~= "dhul_qarnayn" then return false end

    local victim = state.players[victim_id]
    if not victim or #victim.hand == 0 then return false end

    local ri = math.random(#victim.hand)
    local stolen = table.remove(victim.hand, ri)
    table.insert(player.hand, stolen)

    dispatcher.broadcast_message(11, nk.json_encode({
        content = string.format("%s 发动【铁壁】，击杀 %s 前收缴了1张牌！",
            player.username, victim.username),
        hero = "dhul_qarnayn", skill = "tie_bi"
    }))
    return false
end

function M.on_turn_end(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "dhul_qarnayn" then return false end
    player.dhul_qarnayn_iron_wall_used = false
    return false
end

return M

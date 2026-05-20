local nk = require("nakama")
local M = {}

-- 曼苏尔 - 阿拔斯王朝哈里发，巴格达建城者
-- 技能：【建城】
--   击杀玩家时，立即回满血量（每局最多3次）
--   一回合内造成≥2点伤害时，回合结束时回复1点血量

function M.on_kill(dispatcher, state, player_id, victim_id)
    local player = state.players[player_id]
    if player.hero ~= "al_mansur" then return false end

    local heals = player.mansur_full_heals or 0
    if heals >= 3 then return false end
    if player.health >= player.max_health then return false end

    player.mansur_full_heals = heals + 1
    player.health = player.max_health

    dispatcher.broadcast_message(11, nk.json_encode({
        content = string.format("%s 发动【建城】，击杀后回满血量！（第%d次/共3次）",
            player.username, player.mansur_full_heals),
        hero = "al_mansur", skill = "jian_cheng"
    }))
    local rules = require("game_rules")
    rules.broadcast_update(dispatcher, state)
    return false
end

function M.on_turn_end(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "al_mansur" then return false end
    if player.health <= 0 then return false end
    if player.health >= player.max_health then return false end

    local damage_this_turn = (player.damage_dealt or 0) - (player.mansur_last_damage or 0)
    player.mansur_last_damage = player.damage_dealt or 0

    if damage_this_turn >= 2 then
        player.health = player.health + 1
        dispatcher.broadcast_message(11, nk.json_encode({
            content = string.format("%s 本回合造成%d点伤害，发动【建城】回复1点血量！",
                player.username, damage_this_turn),
            hero = "al_mansur", skill = "jian_cheng"
        }))
        local rules = require("game_rules")
        rules.broadcast_update(dispatcher, state)
    end
    return false
end

return M

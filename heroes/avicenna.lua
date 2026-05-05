local nk = require("nakama")
local M = {}

-- 伊本·西拿（阿维森纳）- 伊斯兰医学泰斗
-- 技能：【医典】 - 受伤时若手牌数为0，立即回复1点血量

function M.on_damaged(dispatcher, state, player_id, amount)
    local player = state.players[player_id]
    if player.hero ~= "avicenna" then return false end
    if player.health <= 0 then return false end
    if #player.hand ~= 0 then return false end
    if player.health >= player.max_health then return false end

    player.health = player.health + 1
    dispatcher.broadcast_message(11, nk.json_encode({
        content = player.username .. " 发动【医典】，手无余牌时回复1点血量！",
        hero = "avicenna", skill = "yi_dian"
    }))
    local rules = require("game_rules")
    rules.broadcast_update(dispatcher, state)
    return false
end

return M

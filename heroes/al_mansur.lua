local nk = require("nakama")
local M = {}

-- 曼苏尔（阿布·贾法尔·曼苏尔）- 阿拔斯王朝第二任哈里发，巴格达城的建立者
-- 技能：【建城】 - 击杀玩家后，血量上限永久+1并立即回复至新上限（上限最多+3）

function M.on_kill(dispatcher, state, player_id, victim_id)
    local player = state.players[player_id]
    if player.hero ~= "al_mansur" then return false end

    if (player.mansur_ups or 0) >= 3 then return false end

    player.mansur_ups = (player.mansur_ups or 0) + 1
    player.max_health = player.max_health + 1
    player.health = player.max_health

    dispatcher.broadcast_message(11, nk.json_encode({
        content = string.format("%s 发动【建城】，击杀后血量上限+1！（第%d次/共3次）",
            player.username, player.mansur_ups),
        hero = "al_mansur", skill = "jian_cheng"
    }))
    local rules = require("game_rules")
    rules.broadcast_update(dispatcher, state)
    return false
end

return M

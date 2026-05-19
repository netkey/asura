local nk = require("nakama")
local M = {}

-- 双角王（Dhul-Qarnayn）- 古代中东传说中的伟大君主，以铁壁守护弱者
-- 技能：【铁壁】 - 击杀玩家时，在其弃牌之前收缴其1张随机手牌

function M.on_kill(dispatcher, state, player_id, victim_id)
    local player = state.players[player_id]
    if player.hero ~= "dhul_qarnayn" then return false end

    local victim = state.players[victim_id]
    if not victim or #victim.hand == 0 then return false end

    -- 在弃牌前夺取1张
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

return M

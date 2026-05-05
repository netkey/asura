local nk = require("nakama")
local M = {}

-- 双角王（Dhul-Qarnayn）- 《古兰经》第18章提到的传奇统治者，拥有"两角"旗帜
-- 技能：【征服四方】 - 击杀玩家时，在其弃牌之前夺取其1张随机手牌

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
        content = string.format("%s 发动【征服四方】，击杀 %s 前夺取了1张牌！",
            player.username, victim.username),
        hero = "dhul_qarnayn", skill = "zheng_fu_si_fang"
    }))
    return false
end

return M

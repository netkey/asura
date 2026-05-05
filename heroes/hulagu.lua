local nk = require("nakama")
local M = {}

-- 旭烈兀 - 蒙古西征统帅，攻克巴格达
-- 技能：【铁蹄】 - 你攻击时，若目标手牌数多于你，本次伤害+1

function M.on_before_attack(dispatcher, state, player_id, target_id)
    local player = state.players[player_id]
    if player.hero ~= "hulagu" then return false end

    local target = state.players[target_id]
    if not target then return false end

    if #target.hand > #player.hand then
        state.attack_bonus = 1  -- 伤害+1，总计2点
        dispatcher.broadcast_message(11, nk.json_encode({
            content = player.username .. " 发动【铁蹄】，目标手牌更多，攻击伤害+1！",
            hero = "hulagu", skill = "tie_ti"
        }))
    end
    return false
end

return M

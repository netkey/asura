local nk = require("nakama")
local M = {}

-- 芝诺比娅 - 帕尔米拉帝国女王，被称为"东方女王"
-- 技能：【铁甲女王】 - 攻击手牌最多的玩家时，攻击强制命中

function M.on_before_attack(dispatcher, state, player_id, target_id)
    local player = state.players[player_id]
    if player.hero ~= "zenobia" then return false end

    -- 找手牌最多的存活玩家
    local max_cards = -1
    local top_target = nil
    for uid, p in pairs(state.players) do
        if uid ~= player_id and p.health > 0 and #p.hand > max_cards then
            max_cards = #p.hand
            top_target = uid
        end
    end

    if target_id == top_target then
        state.attack_forced = true
        dispatcher.broadcast_message(11, nk.json_encode({
            content = string.format("%s 发动【铁甲女王】，%s 手牌最多，攻击强制命中！",
                player.username,
                state.players[target_id] and state.players[target_id].username or target_id),
            hero = "zenobia", skill = "tie_jia_nv_wang"
        }))
    end
    return false
end

return M

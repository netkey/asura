local nk = require("nakama")
local local_mgr = require("localization_manager")
local M = {}

-- 芝诺比娅 - 帕尔米拉帝国女王，被称为"东方女王"
-- 技能：【铁甲女王】 - 攻击手牌最多的玩家时，攻击强制命中

function M.on_before_attack(dispatcher, state, player_id, target_id)
    local player = state.players[player_id]
    if player.hero ~= "zenobia" then return false end

    -- 找手牌最多的存活玩家（并列时取 id 最小，保证确定性）
    local max_cards = -1
    local top_target = nil
    for uid, p in pairs(state.players) do
        if uid ~= player_id and p.health > 0 then
            if #p.hand > max_cards or (#p.hand == max_cards and (not top_target or uid < top_target)) then
                max_cards = #p.hand
                top_target = uid
            end
        end
    end

    if target_id == top_target then
        state.attack_forced = true
        local msg = local_mgr.bc("skill_zenobia_iron_queen", {
            username = player.username,
        })
        msg.hero = "zenobia"
        msg.skill = "tie_jia_nv_wang"
        dispatcher.broadcast_message(11, nk.json_encode(msg))
    end
    return false
end

return M

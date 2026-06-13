local nk = require("nakama")
local M = {}

-- 祖拜达 - 哈里发哈伦·拉希德之妻，以慷慨仁慈著称
-- 技能：【仁济】 - 受伤时，令场上血量最低的其他存活玩家回复1点血量

function M.on_damaged(dispatcher, state, player_id, amount, source_id)
    local player = state.players[player_id]
    if player.hero ~= "zubaydah" then return false end
    if player.health <= 0 then return false end

    -- 找血量最低的其他存活玩家
    local min_hp = math.huge
    local target_id = nil
    for uid, p in pairs(state.players) do
        if uid ~= player_id and p.health > 0 and p.health < min_hp then
            min_hp = p.health
            target_id = uid
        end
    end

    if not target_id then return false end
    local target = state.players[target_id]
    if target.health >= target.max_health then return false end

    target.health = target.health + 1
    dispatcher.broadcast_message(11, nk.json_encode({
        content = string.format("%s triggers [Benevolence], causing %s to recover 1 HP!",
            player.username, target.username),
        hero = "zubaydah", skill = "ren_ji"
    }))
    local rules = require("game_rules")
    rules.broadcast_update(dispatcher, state)
    return false
end

return M

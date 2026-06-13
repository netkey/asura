local nk = require("nakama")
local M = {}

-- 萨拉丁 - 战士主题英雄
-- 技能：【坚守】 - 受到伤害后，摸1张牌

function M.on_damaged(dispatcher, state, player_id, amount, source_id)
    local player = state.players[player_id]

    -- 检查是否是萨拉丁
    if player.hero ~= "saladin" then
        return false
    end

    -- 检查是否还活着
    if player.health <= 0 then
        return false
    end

    local rules = require("game_rules")

    -- 每受到1点伤害摸1张牌
    local draw_count = amount or 1
    rules.draw_cards(state, player_id, draw_count)

    dispatcher.broadcast_message(11, nk.json_encode({
        content = string.format("%s activated [Hold Fast], suffered %d damage, drew %d cards!",
            player.username, draw_count, draw_count),
        hero = "saladin",
        skill = "jian_shou"
    }))

    -- 触发后同步状态
    rules.broadcast_update(dispatcher, state)

    return false  -- 不挂起游戏流程
end

return M

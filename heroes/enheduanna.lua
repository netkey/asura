local nk = require("nakama")
local M = {}

-- 恩赫杜安娜 - 公元前22世纪的苏美尔诗人/神职人员，被认为是世界历史上第一位知名诗人
-- 技能：【颂词】 - 出牌阶段，令场上所有其他存活玩家各摸1张牌

function M.on_play_phase_start(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "enheduanna" then return false end

    local rules = require("game_rules")
    local count = 0
    for uid, p in pairs(state.players) do
        if uid ~= player_id and p.health > 0 then
            rules.draw_cards(state, uid, 1)
            count = count + 1
        end
    end

    if count > 0 then
        dispatcher.broadcast_message(11, nk.json_encode({
            content = string.format("%s 发动【颂词】，全场 %d 名存活玩家各摸1张牌！",
                player.username, count),
            hero = "enheduanna", skill = "song_ci"
        }))
        rules.broadcast_update(dispatcher, state)
    end
    return false
end

return M

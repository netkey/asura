local nk = require("nakama")
local M = {}

-- 苏莱曼（所罗门） - 古代以色列联合王国最伟大的国王，传说拥有封印恶魔的神戒指
-- 技能：【封印】 - 出牌阶段，可宣告一名其他玩家本回合不能使用【AOE沙尘暴】

function M.on_play_phase_start(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "suleiman" then return false end

    -- 找可指定的目标（其他存活玩家）
    local targets = {}
    for uid, p in pairs(state.players) do
        if uid ~= player_id and p.health > 0 then
            table.insert(targets, uid)
        end
    end
    if #targets == 0 then return false end

    local target_id = targets[math.random(#targets)]
    local target = state.players[target_id]

    -- 设置封印状态：目标本回合不能使用AOE
    state.suleiman_sealed = state.suleiman_sealed or {}
    state.suleiman_sealed[target_id] = true
    state.suleiman_sealed_owner = player_id

    dispatcher.broadcast_message(11, nk.json_encode({
        content = string.format("%s 发动【封印】，%s 本回合不能使用【沙尘暴】！",
            player.username, target.username),
        hero = "suleiman", skill = "feng_yin"
    }))
    return false
end

return M

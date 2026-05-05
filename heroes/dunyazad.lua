local nk = require("nakama")
local M = {}

-- 杜尼亚扎德 - 舍赫拉莎德的妹妹，《一千零一夜》重要角色
-- 技能：【续篇】 - 防御成功后，本回合该攻击者不能再对你使用【攻击】

function M.on_attack_defended(dispatcher, state, defender_id, attacker_id)
    local player = state.players[defender_id]
    if player.hero ~= "dunyazad" then return false end

    -- 记录免疫关系：attacker_id 本回合不能再攻击 defender_id
    state.dunyazad_immune = state.dunyazad_immune or {}
    state.dunyazad_immune[attacker_id] = defender_id

    local attacker = state.players[attacker_id]
    dispatcher.broadcast_message(11, nk.json_encode({
        content = string.format("%s 发动【续篇】，%s 本回合不能再攻击 %s！",
            player.username,
            attacker and attacker.username or attacker_id,
            player.username),
        hero = "dunyazad", skill = "xu_pian"
    }))
    -- 清除 pending_action 并广播
    state.pending_action = nil
    local rules = require("game_rules")
    rules.broadcast_update(dispatcher, state)
    return true  -- 挂起已在此处理完毕
end

return M

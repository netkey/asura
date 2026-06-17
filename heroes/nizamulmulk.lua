local nk = require("nakama")
local local_mgr = require("localization_manager")
local M = {}

-- 尼扎姆·穆尔克 - 塞尔柱帝国大维齐尔，"权谋"政治家
-- 技能：【权谋】 - 受到攻击伤害时，令攻击者弃置1张牌
-- 注：需要引擎传递 source_id，当前简化为描述性广播

function M.on_damaged(dispatcher, state, player_id, amount, source_id)
    local player = state.players[player_id]
    if player.hero ~= "nizamulmulk" then return false end
    if player.health <= 0 then return false end

    -- 仅攻击伤害触发：跳过天谴和 AOE
    if state._in_judgment_phase then return false end
    local pa = state.pending_action
    if pa and pa.type == "WAITING_FOR_AOE" then return false end

    local attacker = source_id and state.players[source_id]
    if attacker and attacker.health > 0 and #attacker.hand > 0 then
        local ri = math.random(#attacker.hand)
        local card = table.remove(attacker.hand, ri)
        table.insert(state.discard_pile, card)
        local msg = local_mgr.bc("skill_nizamulmulk_statecraft", {
            username = player.username,
            target = attacker.username,
        })
        msg.hero = "nizamulmulk"
        msg.skill = "quan_mou"
        dispatcher.broadcast_message(11, nk.json_encode(msg))
        local rules = require("game_rules")
        rules.broadcast_update(dispatcher, state)
    end
    return false
end

return M

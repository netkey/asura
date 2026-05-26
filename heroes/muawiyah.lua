local nk = require("nakama")
local M = {}

-- 穆阿维叶 - 倭马亚王朝建立者，以卓越政治手腕著称
-- 技能：【谋略】 - 防御成功后，随机夺取攻击者1张手牌

function M.on_attack_defended(dispatcher, state, defender_id, attacker_id)
    local player = state.players[defender_id]
    if player.hero ~= "muawiyah" then return false end

    local attacker = state.players[attacker_id]
    if not attacker or #attacker.hand == 0 then
        -- 无可夺取的牌，返回 false 让调用方走正常防御成功广播
        return false
    end

    -- 随机夺取1张
    local ri = math.random(#attacker.hand)
    local stolen = table.remove(attacker.hand, ri)
    table.insert(player.hand, stolen)

    dispatcher.broadcast_message(11, nk.json_encode({
        content = string.format("%s 发动【谋略】，从 %s 手中随机夺取了1张牌！",
            player.username, attacker.username),
        hero = "muawiyah", skill = "mou_lue"
    }))

    state.pending_action = nil
    local rules = require("game_rules")
    rules.broadcast_update(dispatcher, state)
    return true
end

return M

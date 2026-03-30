local nk = require("nakama")
local M = {}

-- 技能：【坚守】
-- 触发时机：当萨拉丁受到伤害后触发 (Hook: on_after_damage)
function M.on_after_damage(dispatcher, state, saladin_id, amount)
    local saladin = state.players[saladin_id]
    if not saladin then return false end
    
    local rules = require("game_rules")

    -- 核心逻辑：受到伤害后固定摸 1 张牌
    -- 注意：如果是高并发环境，这里的 rules.draw_cards 必须是线程安全的
    rules.draw_cards(state, saladin_id, 1)

    -- 广播技能发动特效 (OpCode 11 通常用于战报或特效显示)
    local msg = {
        content = saladin.username .. " 发动了技能【坚守】，获得了一张补给！",
        hero = "saladin",
        skill = "steadfast"
    }
    dispatcher.broadcast_message(11, nk.json_encode(msg))

    -- 被动技能不打断游戏进程，返回 false
    return false
end

return M

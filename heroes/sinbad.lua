local nk = require("nakama")
local local_mgr = require("localization_manager")
local M = {}

-- 辛巴达 - 传奇七次航海的水手
-- 技能：【七航】 - 每回合结束时可取弃牌堆顶1张牌入手（每局限7次）

function M.on_turn_end(dispatcher, state, player_id)
    local player = state.players[player_id]
    if player.hero ~= "sinbad" then return false end
    if player.health <= 0 then return false end
    if #state.discard_pile == 0 then return false end

    player.sinbad_voyages = player.sinbad_voyages or 0
    if player.sinbad_voyages >= 7 then return false end

    local card = table.remove(state.discard_pile)
    table.insert(player.hand, card)
    player.sinbad_voyages = player.sinbad_voyages + 1

    local msg = local_mgr.bc("skill_sinbad_seven_voyages", {
        username = player.username,
        current = tostring(player.sinbad_voyages),
        max = "7",
    })
    msg.hero = "sinbad"
    msg.skill = "qi_hang"
    dispatcher.broadcast_message(11, nk.json_encode(msg))
    local rules = require("game_rules")
    rules.broadcast_update(dispatcher, state)
    return false
end

return M

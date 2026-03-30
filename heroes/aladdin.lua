local M = {}
local nk = require("nakama")

-- 阶段 1: 询问启动
function M.on_draw_start(dispatcher, state, player_id)
    state.pending_action = { 
        player_id = player_id, 
        hero_id = "aladdin", -- 确保对应 handle_response
        skill = "magic_lamp",
        step = "ASK_CONFIRM" -- 记录步骤
    }
    -- OpCode 100: 客户端弹出询问框
    dispatcher.broadcast_message(100, nk.json_encode({
        text = "阿拉丁，是否消耗2张手牌召唤神灯精灵？"
    }), {state.presences[player_id]})
    return true
end

-- 阶段 2: 处理响应逻辑 (由 hero_manager 转发过来)
function M.on_response(dispatcher, state, player_id, payload)
    local player = state.players[player_id]
    local rules = require("game_rules")
    local action = state.pending_action

    -- 第一步响应：确认是否发动
    if action.step == "ASK_CONFIRM" then
        if payload.confirm == true and #player.hand >= 2 then
            -- 修改步骤，等待玩家选牌
            action.step = "CHOOSE_CARDS"
            -- OpCode 101: 客户端进入“选2张弃掉”模式
            dispatcher.broadcast_message(101, nk.json_encode({
                text = "请选择2张手牌作为祭品",
                count = 2
            }), {state.presences[player_id]})
        else
            -- 拒绝或手牌不够，直接走常规摸牌并结束技能
            rules.draw_cards(state, player_id, 2)
            state.pending_action = nil
            rules.broadcast_update(dispatcher, state)
        end

    -- 第二步响应：处理选好的弃牌
    elseif action.step == "CHOOSE_CARDS" then
        local chosen_ids = payload.card_ids -- 客户端传回选中的 ID 列表
        if #chosen_ids == 2 then
            -- 这里需要遍历 player.hand，根据 ID 移除牌并放入弃牌堆
            for _, id in ipairs(chosen_ids) do
                for i, card in ipairs(player.hand) do
                    if card.id == id then
                        table.insert(state.discard_pile, table.remove(player.hand, i))
                        break
                    end
                end
            end
            -- 发放神谕牌
            local oracle_card = rules.pull_oracle(state)
            table.insert(player.hand, oracle_card)
            
            dispatcher.broadcast_message(11, player.username .. " 获得了精灵的指引！")
            
            -- 技能圆满结束，记得清空 pending
            state.pending_action = nil
            rules.broadcast_update(dispatcher, state)
        end
    end
end

return M

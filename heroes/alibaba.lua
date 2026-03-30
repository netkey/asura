local nk = require("nakama")
local M = {}

-- 技能：【暗号】
-- 触发时机：攻击者是阿里巴巴，且对方打出【防御】成功避开攻击时
function M.on_attack_defended(dispatcher, state, alibaba_id, target_id)
    -- 记录挂起状态
    state.pending_action = {
        player_id = alibaba_id,
        hero_id = "alibaba", -- 关键：方便 hero_manager 路由
        target_id = target_id,
        skill = "an_hao"
    }

    -- 私发消息给阿里巴巴 (OpCode 101)
    local msg = {
        prompt = "对方躲开了你的攻击，是否发动【暗号】抽取其一张手牌？",
        skill_id = "an_hao"
    }
    dispatcher.broadcast_message(101, nk.json_encode(msg), {state.presences[alibaba_id]})

    return true -- 挂起流程，等待选择
end

-- 响应处理
function M.on_response(dispatcher, state, player_id, payload)
    local alibaba = state.players[player_id]
    local action = state.pending_action
    
    -- 安全校验：确保目标还在线且在游戏中
    local target_id = action.target_id
    local target = state.players[target_id]

    if payload.confirm == true then
        if target and #target.hand > 0 then
            -- 逻辑：偷取一张随机手牌
            local random_idx = math.random(#target.hand)
            local stolen_card = table.remove(target.hand, random_idx)
            table.insert(alibaba.hand, stolen_card)

            dispatcher.broadcast_message(11, nk.json_encode({
                content = alibaba.username .. " 发动【暗号】，从 " .. target.username .. " 处窃取了一张牌！"
            }))
        end
    end

    -- 【关键】处理完响应，务必清除挂起状态，否则房间会卡死
    state.pending_action = nil
    
    -- 同步最新手牌数量给全场
    local rules = require("game_rules")
    rules.broadcast_update(dispatcher, state)
end

return M

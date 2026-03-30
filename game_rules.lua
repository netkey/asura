local nk = require("nakama")
local M = {}

-- ==========================================
-- 1. 卡牌效果定义
-- ==========================================
local CARD_EFFECTS = {
    ["ATTACK"] = function(dispatcher, state, source_id, target_id)
        local hero_mgr = require("hero_manager")
        -- 触发：攻击前钩子（如：某些英雄可以让攻击不可闪避）
        hero_mgr.trigger("on_before_attack", dispatcher, state, source_id, target_id)

        -- 【核心修改】：不再自动扣防御牌，而是进入等待防御状态
        state.pending_action = {
            type = "WAITING_FOR_DEFENSE",
            attacker_id = source_id,
            target_id = target_id,
            deadline = os.time() + 15 -- 给 15 秒思考时间
        }

        -- 通知客户端：A 攻击 B，B 准备操作
        dispatcher.broadcast_message(105, nk.json_encode({
            attacker = source_id,
            target = target_id,
            msg = "受到攻击，请出示【防御】"
        }))
    end,

    ["HEAL"] = function(dispatcher, state, source_id)
        local p = state.players[source_id]
        if p.health < p.max_health then
            p.health = p.health + 1
            dispatcher.broadcast_message(11, p.username .. " 使用了【药】，恢复了 1 点生命值")
        end
    end,

    -- 万箭齐发 (沙尘暴) 改造
    ["AOE_SANDSTORM"] = function(dispatcher, state, source_id)
        -- AOE 更复杂：它需要全场所有人按顺序结算防御
        -- 我们先简单处理，建立一个“待结算列表”
        local targets = {}
        for uid, p in pairs(state.players) do
            if uid ~= source_id and p.health > 0 then
                table.insert(targets, uid)
            end
        end

        state.pending_action = {
            type = "WAITING_FOR_AOE",
            attacker_id = source_id,
            remaining_targets = targets, -- 存下还没结算防御的人
            current_target = table.remove(targets, 1),
            aoe_type = "SANDSTORM"
        }
        
        -- 通知当前第一个目标出牌
        M.notify_aoe_target(dispatcher, state)
    end,

	["DRAW_TWO"] = function(dispatcher, state, source_id)
        local rules = require("game_rules")
        local player = state.players[source_id]
        
        -- 1. 广播：让全场看到玩家使用了【无中生有】的动画
        dispatcher.broadcast_message(11, nk.json_encode({
            content = player.username .. " 使用了【无中生有】",
            card_type = "DRAW_TWO"
        }))

        -- 2. 执行核心逻辑：摸 2 张牌
        -- 这里直接调用你写的 rules.draw_cards
        rules.draw_cards(state, source_id, 2)

        -- 3. 因为摸牌改变了手牌数据，同步一次状态给所有玩家
        -- 确保其他玩家看到该玩家的手牌数 +2，而该玩家看到自己的具体牌面
        rules.broadcast_update(dispatcher, state)
    end,


	["JUDGE_STORM"] = function(dispatcher, state, source_id, target_id)
    	local target = state.players[target_id]
    	-- 将这张牌挂到目标的判定区数组里
    	table.insert(target.judgments, { type = "JUDGE_STORM", from = source_id })
    	nk.logger_info("【天谴】已挂在 " .. target.username .. " 的面前")
	end,

}



-- ==========================================
-- 2. 身份局核心逻辑 (新增)
-- ==========================================

-- 奖惩机制：杀反贼奖3张，主公杀忠臣弃光牌
function M.handle_role_reward(dispatcher, state, killer_id, victim_id)
    local killer = state.players[killer_id]
    local victim = state.players[victim_id]
    if not killer or not victim then return end

    if victim.role == "REBEL" then
        M.draw_cards(state, killer_id, 3)
        dispatcher.broadcast_message(11, nk.json_encode({content = killer.username .. " 击毙反贼，奖励 3 张牌"}))
    elseif victim.role == "MINISTER" and killer.role == "MONARCH" then
        killer.hand = {}
        dispatcher.broadcast_message(11, nk.json_encode({content = "主公误杀忠臣，对手牌进行了大清洗！"}))
    end
end

-- 胜负判定逻辑
function M.check_victory(dispatcher, state)
    local alive = { MONARCH = 0, MINISTER = 0, REBEL = 0, TRAITOR = 0 }
    for _, p in pairs(state.players) do
        if p.health > 0 then
            alive[p.role] = alive[p.role] + 1
        end
    end

    -- 1. 主公阵亡
    if alive.MONARCH == 0 then
        -- 仅剩一名内奸，且其他人都死光了，内奸胜
        if alive.REBEL == 0 and alive.MINISTER == 0 and alive.TRAITOR == 1 then
            return true, "TRAITOR_WIN"
        end
        return true, "REBEL_WIN" -- 否则均为反贼胜
    end

    -- 2. 反贼和内奸全灭
    if alive.REBEL == 0 and alive.TRAITOR == 0 then
        return true, "MONARCH_WIN"
    end

    return false, nil
end

-- ==========================================
-- 3. 基础功能 (牌堆、摸牌等)
-- ==========================================
function M.start_game(dispatcher, state)
    -- 初始化发牌（逻辑已移至 match_join 触发）
    for uid, _ in pairs(state.players) do
        M.draw_cards(state, uid, 4)
    end
end

--[[old
function M.create_deck()
    local deck = {}
    for i = 1, 20 do table.insert(deck, {id = "atk_"..i, type = "ATTACK", name = "大马士革弯刀"}) end
    for i = 1, 10 do table.insert(deck, {id = "def_"..i, type = "DEFENSE", name = "蜃景"}) end
    for i = 1, 5 do table.insert(deck, {id = "heal_"..i, type = "HEAL", name = "椰枣"}) end
    for i = 1, 3 do table.insert(deck, {id = "aoe_"..i, type = "AOE_SANDSTORM", name = "沙尘暴"}) end
    return M.shuffle(deck)
end
--]]

function M.create_deck()
    local deck = {}
    local suits = {"HEART", "SPADE", "CLUB", "DIAMOND"} -- 红桃, 黑桃, 草花, 方块
    
    -- 1. 生成基础攻击牌 (20张)
    for i = 1, 20 do 
        table.insert(deck, {
            id = "atk_"..i, 
            type = "ATTACK", 
            name = "大马士革弯刀",
            suit = suits[math.random(4)],
            number = math.random(1, 13)
        }) 
    end
    
    -- 2. 生成防御牌 (10张)
    for i = 1, 10 do 
        table.insert(deck, {
            id = "def_"..i, 
            type = "DEFENSE", 
            name = "蜃景",
            suit = suits[math.random(4)],
            number = math.random(1, 13)
        }) 
    end
    
    -- 3. 生成治疗牌 (5张)
    for i = 1, 5 do 
        table.insert(deck, {
            id = "heal_"..i, 
            type = "HEAL", 
            name = "椰枣",
            suit = "HEART", -- 医疗牌通常设定为红桃，增加判定回血概率
            number = math.random(1, 13)
        }) 
    end
    
    -- 4. 生成锦囊牌 (3张)
    for i = 1, 3 do 
        table.insert(deck, {
            id = "aoe_"..i, 
            type = "AOE_SANDSTORM", 
            name = "沙尘暴",
            suit = "CLUB",
            number = math.random(1, 13)
        }) 
    end

    -- 5. 【新增】生成延时判定牌：审判/天谴 (2张)
    -- 这种牌使用后会挂在对方判定区，轮到对方时判定
    for i = 1, 2 do
        table.insert(deck, {
            id = "judge_"..i,
            type = "JUDGE_STORM",
            name = "天谴",
            suit = "SPADE", -- 它的花色是黑桃
            number = 1
        })
    end

    return M.shuffle(deck)
end


function M.shuffle(t)
    for i = #t, 2, -1 do
        local j = math.random(i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

function M.get_next_player_id(state)
    local current_idx = 1
    -- 找到当前玩家在座次表中的索引
    for i, id in ipairs(state.presence_ids) do
        if id == state.current_turn_id then
            current_idx = i
            break
        end
    end

    -- 循环寻找下一个存活的玩家
    local next_idx = current_idx
    for i = 1, #state.presence_ids do
        next_idx = (next_idx % #state.presence_ids) + 1
        local next_uid = state.presence_ids[next_idx]
        if state.players[next_uid].health > 0 then
            return next_uid
        end
    end
    return state.current_turn_id -- 如果只剩一人，返回自己
end

function M.draw_cards(state, player_id, count)
    local player = state.players[player_id]
    if not player then return end
    for i = 1, count do
        if #state.deck == 0 then
            state.deck = M.shuffle(state.discard_pile)
            state.discard_pile = {}
        end
        if #state.deck > 0 then
            table.insert(player.hand, table.remove(state.deck, 1))
        end
    end
end

-- ==========================================
-- 4. 核心出牌与伤害
-- ==========================================
function M.handle_play_card(dispatcher, state, player_id, payload)
    local player = state.players[player_id]
    local card_idx = nil
    for i, c in ipairs(player.hand) do
        if c.id == payload.card_id then card_idx = i; break end
    end

    if card_idx then
        local card = table.remove(player.hand, card_idx)
        table.insert(state.discard_pile, card)

        -- 【改进点】：执行卡牌效果
        if CARD_EFFECTS[card.type] then
            -- 传入 card 对象，因为后续可能需要判断卡牌花色/点数
            CARD_EFFECTS[card.type](dispatcher, state, player_id, payload.target_id, card)
        end
        
        M.broadcast_update(dispatcher, state)
        return true
    end
    return false
end

function M.handle_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action or action.target_id ~= player_id then return end

    if action.type == "WAITING_FOR_DEFENSE" then
        if payload.confirm == true then
            -- 玩家 B 选了一张【防御】牌
            -- 1. 执行常规防御成功逻辑
            M.handle_defense_success(dispatcher, state, action.attacker_id, player_id)
        else
            -- 玩家 B 点击了“放弃”或没有防御牌
            M.apply_damage(dispatcher, state, player_id, 1, action.attacker_id)
            state.pending_action = nil -- 伤害结算完，清除状态
        end
    end
end

-- 当玩家 B 打出【防御】牌来响应玩家 A 的【攻击】时调用
function M.handle_defense_response(dispatcher, state, defender_id, card_id)
    local action = state.pending_action
    if not action or action.type ~= "WAITING_FOR_DEFENSE" then return end

    local attacker_id = action.attacker_id

    -- 1. 正常的防御逻辑：将防御牌移入手牌弃牌堆
    local defender = state.players[defender_id]
    for i, card in ipairs(defender.hand) do
        if card.id == card_id then
            table.insert(state.discard_pile, table.remove(defender.hand, i))
            break
        end
    end

    -- 2. 清除挂起状态（攻击已被抵消）
    state.pending_action = nil
    
    -- 3. 【核心：触发阿里巴巴技能的地方】
    -- 我们调用之前提到的防御成功函数
    M.handle_defense_success(dispatcher, state, attacker_id, defender_id)
end

-- 具体的防御成功后续逻辑
function M.handle_defense_success(dispatcher, state, attacker_id, defender_id)
    nk.logger_info("防御成功，正在检查攻击者是否有追击技能...")
    
    -- 尝试触发阿里巴巴的【暗号】
    local hero_mgr = require("hero_manager")
    -- 注意：trigger 会检查 attacker_id 的英雄是不是阿里巴巴
    local suspended = hero_mgr.trigger("on_attack_defended", dispatcher, state, attacker_id, defender_id)
    
    if not suspended then
        -- 如果没有触发技能（比如攻击者是阿拉丁），直接告诉大家防御成功，继续出牌阶段
        dispatcher.broadcast_message(11, "防御成功！")
        M.broadcast_update(dispatcher, state)
    end
end



function M.apply_damage(dispatcher, state, target_id, amount, source_id)
    local target = state.players[target_id]
    if not target or target.health <= 0 then return end

    target.health = target.health - amount
    
    local hero_mgr = require("hero_manager")
    hero_mgr.trigger("on_damaged", dispatcher, state, target_id, amount)

    dispatcher.broadcast_message(20, nk.json_encode({ event = "damage", target = target_id, source = source_id, amount = amount }))

    if target.health <= 0 then
        target.health = 0
        -- 弃牌
        for i = 1, #target.hand do table.insert(state.discard_pile, table.remove(target.hand)) end
        nk.logger_info(target.username .. " 已阵亡，身份是: " .. target.role)
        
        -- 触发奖惩
        M.handle_role_reward(dispatcher, state, source_id, target_id)
    end
end

-- ==========================================
-- 5. 状态广播 (身份迷雾版)
-- ==========================================
function M.broadcast_update(dispatcher, state)
    for uid, presence in pairs(state.presences) do
        local p_data = state.players[uid]
        local payload = {
            current_turn = state.current_turn_id,
            pending = state.pending_action,
            me = {
                hand = p_data.hand,
                hp = p_data.health,
                role = p_data.role
            },
            others = {}
        }
        for other_id, other_p in pairs(state.players) do
            if other_id ~= uid then
                -- 身份迷雾逻辑：只有主公或已阵亡或游戏结束才看得到别人的身份
                local visible_role = "UNKNOWN"
                if other_p.role == "MONARCH" or other_p.health <= 0 or state.status == 2 then
                    visible_role = other_p.role
                end

                table.insert(payload.others, {
                    id = other_id,
                    username = other_p.username,
                    hp = other_p.health,
                    hand_count = #other_p.hand,
                    hero = other_p.hero,
                    role = visible_role
                })
            end
        end
        dispatcher.broadcast_message(10, nk.json_encode(payload), {presence})
    end
end


function M.execute_judgment(state)
    if #state.deck == 0 then
        state.deck = M.shuffle(state.discard_pile)
        state.discard_pile = {}
    end
    
    local judge_card = table.remove(state.deck, 1)
    table.insert(state.discard_pile, judge_card)
    
    -- 广播判定结果给所有人看
    -- 比如：判定结果是 [黑桃 1]
    return judge_card
end

return M

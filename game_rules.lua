local nk = require("nakama")
local M = {}

-- ==========================================
-- 1. 卡牌效果定义
-- ==========================================
local CARD_EFFECTS = {
    ["ATTACK"] = function(dispatcher, state, source_id, target_id)
        local hero_mgr = require("hero_manager")

        -- 杜尼亚扎德【续篇】：攻击者本回合已被该目标免疫
        if state.dunyazad_immune and state.dunyazad_immune[source_id] == target_id then
            dispatcher.broadcast_message(11, nk.json_encode({
                content = state.players[target_id].username .. " 的【续篇】令此次攻击无效"
            }))
            return
        end

        -- 触发：攻击前钩子（如：某些英雄可以让攻击不可闪避）
        hero_mgr.trigger("on_before_attack", dispatcher, state, source_id, target_id)

        -- 旭烈兀【铁蹄】若取消本次攻击则直接返回
        if state.attack_cancelled then
            state.attack_cancelled = nil
            return
        end

        -- attacks_this_turn 计数（纳芙蒂蒂/安塔拉用）
        local sp = state.players[source_id]
        if sp then sp.attacks_this_turn = (sp.attacks_this_turn or 0) + 1 end

        -- 阿拉伯弯刀：攻击后摸1张
        if sp and sp.equipment.weapon and sp.equipment.weapon.subtype == "draw_card" then
            M.draw_cards(state, source_id, 1)
            dispatcher.broadcast_message(11, nk.json_encode({
                content = sp.username .. " 的【阿拉伯弯刀】触发：攻击后摸1张"
            }))
        end

        -- 计算基础伤害
        local dmg = 1
        if sp and sp.attack_debuff then dmg = math.max(0, dmg - 1) end

        -- 流星锤：攻击无视防具（标记攻击bonus让防御阶段知道伤害）
        if sp and sp.equipment.weapon and sp.equipment.weapon.subtype == "meteor" then
            state.attack_forced = true
        end

        -- 旭烈兀【铁蹄】：attack_bonus 标志
        if state.attack_bonus then
            dmg = dmg + state.attack_bonus
            state.attack_bonus = nil
        end

        -- 【核心修改】：不再自动扣防御牌，而是进入等待防御状态
        state.pending_action = {
            type = "WAITING_FOR_DEFENSE",
            attacker_id = source_id,
            target_id = target_id,
            damage = dmg,
            deadline = os.time() + 15
        }

        -- 通知客户端：A 攻击 B，B 准备操作
        dispatcher.broadcast_message(105, nk.json_encode({
            attacker = source_id,
            target = target_id,
            damage = dmg,
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
        -- 苏莱曼【封印】：被封印者本回合不能使用AOE
        if state.suleiman_sealed and state.suleiman_sealed[source_id] then
            state.suleiman_sealed[source_id] = nil
            dispatcher.broadcast_message(11, nk.json_encode({
                content = state.players[source_id].username .. " 本回合被【封印】，无法使用【沙尘暴】！"
            }))
            return
        end

        -- AOE 更复杂：它需要全场所有人按顺序结算防御
        -- 我们先简单处理，建立一个"待结算列表"
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

	-- 武器牌：装备到武器槽，替换旧武器
	["WEAPON"] = function(dispatcher, state, source_id, _, card)
		local p = state.players[source_id]
		local old = p.equipment.weapon
		if old then
			table.insert(state.discard_pile, old)
			nk.logger_info(p.username .. " 替换旧武器：" .. old.name)
		end
		p.equipment.weapon = card
		dispatcher.broadcast_message(11, nk.json_encode({
			content = p.username .. " 装备【" .. card.name .. "】",
			card = card
		}))
		-- 流星锤：攻击无视防具；阿拉伯弯刀：攻击后摸1牌 — 这些在ATTACK结算时处理
	end,

	-- 防具牌：装备到防具槽，替换旧防具
	["ARMOR"] = function(dispatcher, state, source_id, _, card)
		local p = state.players[source_id]
		local old = p.equipment.armor
		if old then
			table.insert(state.discard_pile, old)
		end
		p.equipment.armor = card
		dispatcher.broadcast_message(11, nk.json_encode({
			content = p.username .. " 装备【" .. card.name .. "】",
			card = card
		}))
	end,

	-- 马牌：装备到马槽，替换旧马
	["HORSE"] = function(dispatcher, state, source_id, _, card)
		local p = state.players[source_id]
		local old = p.equipment.horse
		if old then
			table.insert(state.discard_pile, old)
		end
		p.equipment.horse = card
		dispatcher.broadcast_message(11, nk.json_encode({
			content = p.username .. " 装备【" .. card.name .. "】",
			card = card
		}))
	end,

	-- 酒牌：标记 weapon_buff，下次攻击伤害+1
	["WINE"] = function(dispatcher, state, source_id, _, card)
		local p = state.players[source_id]
		p.weapon_buff = true
		p.wine_subtype = card.subtype  -- 记录 subtype 用于击杀奖励
		dispatcher.broadcast_message(11, nk.json_encode({
			content = p.username .. " 饮【" .. card.name .. "】，下次攻击伤害+1",
			card = card
		}))
	end,

	-- 延时锦囊：挂在 delayed_effects，下回合判定阶段触发
	["DELAYED_TRICK"] = function(dispatcher, state, source_id, target_id, card)
		local target = state.players[target_id or source_id]
		table.insert(target.delayed_effects, {
			name = card.name,
			subtype = card.subtype,
			from = source_id
		})
		dispatcher.broadcast_message(11, nk.json_encode({
			content = target.username .. " 被挂上【" .. card.name .. "】",
			card = card
		}))
	end,

	-- 即时锦囊：打出即生效
	["INSTANT_TRICK"] = function(dispatcher, state, source_id, target_id, card)
		local p = state.players[source_id]
		if card.subtype == "peek3_reorder" then
			-- 沙漠罗盘：看牌堆顶3张，调整顺序后放回
			local peeked = {}
			for i = 1, 3 do
				if #state.deck == 0 then
					state.deck = M.shuffle(state.discard_pile)
					state.discard_pile = {}
				end
				if #state.deck > 0 then
					table.insert(peeked, table.remove(state.deck, 1))
				end
			end
			dispatcher.broadcast_message(11, nk.json_encode({
				content = p.username .. " 使用【沙漠罗盘】，查看牌堆顶3张并调整顺序",
				card = card
			}))
			-- 简单处理：直接放回牌堆顶（不交互排序，按原顺序放回）
			for i = #peeked, 1, -1 do
				table.insert(state.deck, 1, peeked[i])
			end

		elseif card.subtype == "discard_enemy_card" then
			-- 诱降：指定一名其他玩家，观看其手牌，选择1张弃置
			local target = state.players[target_id]
			if target and #target.hand > 0 then
				local idx = math.random(#target.hand)
				local discarded = table.remove(target.hand, idx)
				table.insert(state.discard_pile, discarded)
				dispatcher.broadcast_message(11, nk.json_encode({
					content = p.username .. " 对 " .. target.username .. " 使用【诱降】，弃置1张牌",
					card = card
				}))
			end

		elseif card.subtype == "swap_hands" then
			-- 以物易物：与目标交换全部手牌
			local target = state.players[target_id]
			if target then
				local tmp = target.hand
				target.hand = p.hand
				p.hand = tmp
				dispatcher.broadcast_message(11, nk.json_encode({
					content = p.username .. " 与 " .. target.username .. " 使用【以物易物】交换手牌",
					card = card
				}))
			end

		elseif card.subtype == "shuffle_draw2" then
			-- 沙漠风暴：弃牌堆洗入牌堆，然后摸2张
			state.deck = M.shuffle(state.discard_pile)
			state.discard_pile = {}
			M.draw_cards(state, source_id, 2)
			dispatcher.broadcast_message(11, nk.json_encode({
				content = p.username .. " 使用【沙漠风暴】，洗牌堆并摸2张",
				card = card
			}))
		end
	end,

}



-- 通知当前 AOE 目标准备防御，或结算完成
function M.notify_aoe_target(dispatcher, state)
    local action = state.pending_action
    if not action or action.type ~= "WAITING_FOR_AOE" then return end

    local target_id = action.current_target
    if not target_id then
        state.pending_action = nil
        M.broadcast_update(dispatcher, state)
        return
    end

    dispatcher.broadcast_message(105, nk.json_encode({
        attacker = action.attacker_id,
        target   = target_id,
        msg      = "受到【沙尘暴】，请出示【防御】或放弃"
    }))
end

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
    local suits = {"HEART", "SPADE", "CLUB", "DIAMOND"}

    -- 基础牌 (54张)
    for i = 1, 20 do
        table.insert(deck, { id = "atk_"..i, type = "ATTACK", name = "大马士革弯刀", suit = suits[math.random(4)], number = math.random(1, 13) })
    end
    for i = 1, 12 do
        table.insert(deck, { id = "def_"..i, type = "DEFENSE", name = "蜃景", suit = suits[math.random(4)], number = math.random(1, 13) })
    end
    for i = 1, 8 do
        table.insert(deck, { id = "heal_"..i, type = "HEAL", name = "椰枣", suit = "HEART", number = math.random(1, 13) })
    end
    for i = 1, 4 do
        table.insert(deck, { id = "aoe_"..i, type = "AOE_SANDSTORM", name = "沙尘暴", suit = "CLUB", number = math.random(1, 13) })
    end
    for i = 1, 6 do
        table.insert(deck, { id = "draw2_"..i, type = "DRAW_TWO", name = "无中生有", suit = "DIAMOND", number = math.random(1, 13) })
    end
    for i = 1, 4 do
        table.insert(deck, { id = "judge_"..i, type = "JUDGE_STORM", name = "天谴", suit = "SPADE", number = 1 })
    end

    -- 武器牌 (10张) — 装备区永久生效
    for i = 1, 3 do
        table.insert(deck, { id = "weapon_"..i, type = "WEAPON", name = "波斯长剑", subtype = "sword", suit = suits[math.random(4)], number = 1 })
    end
    for i = 4, 6 do
        table.insert(deck, { id = "weapon_"..i, type = "WEAPON", name = "大马士革弯刀", subtype = "scimitar", suit = suits[math.random(4)], number = 1 })
    end
    for i = 7, 8 do
        table.insert(deck, { id = "weapon_"..i, type = "WEAPON", name = "流星锤", subtype = "meteor", suit = suits[math.random(4)], number = 1 })
    end
    for i = 9, 10 do
        table.insert(deck, { id = "weapon_"..i, type = "WEAPON", name = "阿拉伯弯刀", subtype = "draw_card", suit = suits[math.random(4)], number = 1 })
    end

    -- 防具牌 (6张)
    for i = 1, 2 do
        table.insert(deck, { id = "armor_"..i, type = "ARMOR", name = "波斯盾牌", subtype = "reduce_damage", suit = suits[math.random(4)], number = 1 })
    end
    for i = 3, 4 do
        table.insert(deck, { id = "armor_"..i, type = "ARMOR", name = "古兰经护盾", subtype = "immortal_once", suit = suits[math.random(4)], number = 1 })
    end
    for i = 5, 6 do
        table.insert(deck, { id = "armor_"..i, type = "ARMOR", name = "锁子甲", subtype = "reduce_aoe", suit = suits[math.random(4)], number = 1 })
    end

    -- 马牌 (6张)
    for i = 1, 3 do
        table.insert(deck, { id = "horse_"..i, type = "HORSE", name = "阿拉伯战马", subtype = "offense", suit = suits[math.random(4)], number = 1 })
    end
    for i = 4, 6 do
        table.insert(deck, { id = "horse_"..i, type = "HORSE", name = "骆驼", subtype = "defense", suit = suits[math.random(4)], number = 1 })
    end

    -- 酒牌 (6张)
    for i = 1, 3 do
        table.insert(deck, { id = "wine_"..i, type = "WINE", name = "椰枣酒", subtype = "damage_plus1", suit = suits[math.random(4)], number = 1 })
    end
    for i = 4, 6 do
        table.insert(deck, { id = "wine_"..i, type = "WINE", name = "阿拉伯烈酒", subtype = "damage_plus1_kill_draw2", suit = suits[math.random(4)], number = 1 })
    end

    -- 延时锦囊 (6张)
    for i = 1, 2 do
        table.insert(deck, { id = "delay_"..i, type = "DELAYED_TRICK", name = "黑血蛊", subtype = "discard1_draw2", suit = "SPADE", number = 1 })
    end
    for i = 3, 4 do
        table.insert(deck, { id = "delay_"..i, type = "DELAYED_TRICK", name = "沙漠诅咒", subtype = "skip_play_phase", suit = "SPADE", number = 1 })
    end
    for i = 5, 6 do
        table.insert(deck, { id = "delay_"..i, type = "DELAYED_TRICK", name = "虚弱标记", subtype = "attack_minus1", suit = "SPADE", number = 1 })
    end

    -- 即时锦囊 (8张)
    for i = 1, 2 do
        table.insert(deck, { id = "trick_"..i, type = "INSTANT_TRICK", name = "沙漠罗盘", subtype = "peek3_reorder", suit = suits[math.random(4)], number = 1 })
    end
    for i = 3, 4 do
        table.insert(deck, { id = "trick_"..i, type = "INSTANT_TRICK", name = "诱降", subtype = "discard_enemy_card", suit = suits[math.random(4)], number = 1 })
    end
    for i = 5, 6 do
        table.insert(deck, { id = "trick_"..i, type = "INSTANT_TRICK", name = "以物易物", subtype = "swap_hands", suit = suits[math.random(4)], number = 1 })
    end
    for i = 7, 8 do
        table.insert(deck, { id = "trick_"..i, type = "INSTANT_TRICK", name = "沙漠风暴", subtype = "shuffle_draw2", suit = suits[math.random(4)], number = 1 })
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
        -- 装备牌不进弃牌堆，直接进装备槽；其余牌正常弃置
        local is_equipment = card.type == "WEAPON" or card.type == "ARMOR" or card.type == "HORSE"
        if not is_equipment then
            table.insert(state.discard_pile, card)
        end

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
    if not action then return end

    if action.type == "WAITING_FOR_DEFENSE" then
        if action.target_id ~= player_id then return end
        -- 贾法尔【毒计】：强制命中，忽略防御
        if state.attack_forced then
            state.attack_forced = nil
            state.pending_action = nil
            M.apply_damage(dispatcher, state, player_id, action.damage or 1, action.attacker_id)
            return
        end
        if payload.confirm == true then
            M.handle_defense_success(dispatcher, state, action.attacker_id, player_id)
        else
            -- 旭烈兀【铁蹄】：attack_bonus 已整合进 action.damage
            state.attack_bonus = nil
            M.apply_damage(dispatcher, state, player_id, action.damage or 1, action.attacker_id)
            state.pending_action = nil
        end

    elseif action.type == "WAITING_FOR_AOE" then
        if action.current_target ~= player_id then return end
        if payload.confirm ~= true then
            -- 未防御，扣血
            M.apply_damage(dispatcher, state, player_id, 1, action.attacker_id)
        end
        -- 推进到下一个目标
        if #action.remaining_targets > 0 then
            action.current_target = table.remove(action.remaining_targets, 1)
            M.notify_aoe_target(dispatcher, state)
        else
            state.pending_action = nil
            M.broadcast_update(dispatcher, state)
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
    local suspended = hero_mgr.trigger("on_attack_defended", dispatcher, state, defender_id, attacker_id)
    
    if not suspended then
        state.pending_action = nil
        dispatcher.broadcast_message(11, "防御成功！")
        M.broadcast_update(dispatcher, state)
    end
end



function M.apply_damage(dispatcher, state, target_id, amount, source_id)
    local target = state.players[target_id]
    if not target or target.health <= 0 then return end

    -- 计算攻击加成（来源方装备+酒牌）
    local source = source_id and state.players[source_id]
    if source then
        -- 武器加成
        if source.equipment.weapon then
            local wtype = source.equipment.weapon.subtype
            if wtype == "sword" then amount = amount + 1 end
        end
        -- 酒牌buff
        if source.weapon_buff then
            amount = amount + 1
            source.weapon_buff = nil
            -- 阿拉伯烈酒：击杀额外摸2
            source.pending_wine_kill_draw = (source.wine_subtype == "damage_plus1_kill_draw2")
            source.wine_subtype = nil
        end
    end

    -- 防具减伤
    if target.equipment.armor then
        local atype = target.equipment.armor.subtype
        if atype == "reduce_damage" then
            amount = math.max(1, amount - 1)
        elseif atype == "immortal_once" and amount >= target.health then
            -- 古兰经护盾：免疫致命伤害（每局限1次）
            if not target.immortal_used then
                amount = 0
                target.immortal_used = true
                dispatcher.broadcast_message(11, nk.json_encode({
                    content = target.username .. " 的【古兰经护盾】免疫了致命伤害！"
                }))
            end
        end
    end

    target.health = target.health - amount

    local hero_mgr = require("hero_manager")
    hero_mgr.trigger("on_damaged", dispatcher, state, target_id, amount, source_id)

    dispatcher.broadcast_message(20, nk.json_encode({ event = "damage", target = target_id, source = source_id, amount = amount }))

    if target.health <= 0 then
        target.health = 0
        -- on_kill 钩子（需在弃牌前触发，双角王可在此夺牌）
        if source_id then
            hero_mgr.trigger("on_kill", dispatcher, state, source_id, target_id)
        end
        -- 手牌弃置
        for i = 1, #target.hand do table.insert(state.discard_pile, table.remove(target.hand)) end
        -- 装备区回收（防止装备牌永久流失）
        for _, card in pairs(target.equipment) do
            if card then table.insert(state.discard_pile, card) end
        end
        target.equipment = {weapon = nil, armor = nil, horse = nil}
        nk.logger_info(target.username .. " 已阵亡，身份是: " .. target.role)

        -- 阿拉伯烈酒：击杀后摸2
        if source and source.pending_wine_kill_draw then
            source.pending_wine_kill_draw = nil
            M.draw_cards(state, source_id, 2)
            dispatcher.broadcast_message(11, nk.json_encode({
                content = source.username .. " 因【阿拉伯烈酒】效果额外摸2张"
            }))
        end

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
                role = p_data.role,
                equipment = p_data.equipment,
                delayed_effects = p_data.delayed_effects,
                weapon_buff = p_data.weapon_buff
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
                    role = visible_role,
                    equipment = other_p.equipment
                })
            end
        end
        dispatcher.broadcast_message(10, nk.json_encode(payload), {presence})
    end
end


function M.execute_judgment(state)
    if #state.deck == 0 then
        if #state.discard_pile == 0 then
            -- 极端情况：牌堆和弃牌堆均空，返回安全的默认牌避免崩溃
            return {id="dummy_judge", type="DEFENSE", suit="HEART", number=1, name="虚判"}
        end
        state.deck = M.shuffle(state.discard_pile)
        state.discard_pile = {}
    end

    local judge_card = table.remove(state.deck, 1)
    table.insert(state.discard_pile, judge_card)
    return judge_card
end

return M

local nk = require("nakama")
local M = {}

-- 结构化日志（state.match_id 由 match_handler 写入）
local function log_info(state, msg)
    nk.logger_info(string.format("[match=%s] %s", state.match_id or "?", msg))
end

-- 每个 Lua VM 实例化时播种，避免多局牌序相同
math.randomseed(os.time() + math.floor(os.clock() * 1e6))

-- ==========================================
-- 1. 卡牌效果定义
-- ==========================================
local CARD_EFFECTS = {
    ["ATTACK"] = function(dispatcher, state, source_id, target_id)
        local hero_mgr = require("hero_manager")

        -- 触发：攻击前钩子（优先于免疫检查，确保所有英雄钩子都能执行）
        hero_mgr.trigger("on_before_attack", dispatcher, state, source_id, target_id)

        -- 杜尼亚扎德【续篇】：攻击者本回合已被该目标免疫
        if state.dunyazad_immune and state.dunyazad_immune[source_id] == target_id then
            dispatcher.broadcast_message(11, nk.json_encode({
                content = state.players[target_id].username .. " 的【续篇】令此次攻击无效"
            }))
            state.attack_bonus = nil   -- 清理 on_before_attack 可能设置的状态
            state.attack_cancelled = nil
            state.jafar_du_ji = nil
            return
        end

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
            jafar_du_ji = state.jafar_du_ji,
            deadline = os.time() + 15
        }
        state.jafar_du_ji = nil

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
            dispatcher.broadcast_message(11, nk.json_encode({ content = p.username .. " 使用了【药】，恢复了 1 点生命值" }))
        end
    end,

    ["AOE_SANDSTORM"] = function(dispatcher, state, source_id)
        -- 苏莱曼【御风】：被封锁的牌型无法使用
        if state.suleiman_yu_feng and state.suleiman_yu_feng.target_id == source_id
            and state.suleiman_yu_feng.blocked_type == "AOE_SANDSTORM" then
            dispatcher.broadcast_message(11, nk.json_encode({
                content = state.players[source_id].username .. " 被【御风】封锁，无法使用【沙尘暴】！",
                hero = "suleiman", skill = "yu_feng"
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

        if #targets == 0 then return end   -- 场上只有自己时 AOE 无效

        state.pending_action = {
            type = "WAITING_FOR_AOE",
            attacker_id = source_id,
            remaining_targets = targets,
            current_target = table.remove(targets, 1),
            aoe_type = "SANDSTORM",
            deadline = os.time() + 15,
        }

        -- 通知当前第一个目标出牌
        M.notify_aoe_target(dispatcher, state)
    end,

	["DRAW_TWO"] = function(dispatcher, state, source_id)
        local player = state.players[source_id]
        dispatcher.broadcast_message(11, nk.json_encode({
            content = player.username .. " 使用了【无中生有】",
            card_type = "DRAW_TWO"
        }))
        M.draw_cards(state, source_id, 2)
        M.broadcast_update(dispatcher, state)
    end,


	["JUDGE_STORM"] = function(dispatcher, state, source_id, target_id)
    	local target = state.players[target_id]
    	-- 将这张牌挂到目标的判定区数组里
    	table.insert(target.judgments, { type = "JUDGE_STORM", from = source_id })
    	log_info(state, "【天谴】已挂在 " .. target.username .. " 的面前")
	end,

	-- 武器牌：装备到武器槽，替换旧武器
	["WEAPON"] = function(dispatcher, state, source_id, _, card)
		local p = state.players[source_id]
		local old = p.equipment.weapon
		if old then
			table.insert(state.discard_pile, old)
			log_info(state, p.username .. " 替换旧武器：" .. old.name)
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
			-- 沙漠罗盘：取出牌堆顶3张，挂起等待玩家选择放回顺序
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
			if #peeked == 0 then return end
			state.pending_action = {
				type       = "WAITING_FOR_TRICK_SELECT",
				subtype    = "peek3_reorder",
				chooser_id = source_id,
				peeked     = peeked,
				deadline   = os.time() + 20,
			}
			dispatcher.broadcast_message(11, nk.json_encode({
				content = p.username .. " 使用【沙漠罗盘】，正在选择牌堆顺序…",
				card    = card,
			}))
			-- 仅向使用者私发3张预览
			if state.presences[source_id] then
				dispatcher.broadcast_message(106, nk.json_encode({
					event  = "peek3_choose",
					peeked = peeked,
				}), {state.presences[source_id]})
			end

		elseif card.subtype == "discard_enemy_card" then
			-- 诱降：挂起，让使用者看目标手牌并选择弃哪张
			local target = state.players[target_id]
			if not target or #target.hand == 0 then return end
			state.pending_action = {
				type       = "WAITING_FOR_TRICK_SELECT",
				subtype    = "discard_enemy_card",
				chooser_id = source_id,
				target_id  = target_id,
				deadline   = os.time() + 20,
			}
			dispatcher.broadcast_message(11, nk.json_encode({
				content = p.username .. " 对 " .. target.username .. " 使用【诱降】，正在选择弃置…",
				card    = card,
			}))
			-- 仅向使用者私发目标手牌（含 card id，供选择）
			if state.presences[source_id] then
				dispatcher.broadcast_message(106, nk.json_encode({
					event     = "peek_hand_choose",
					target_id = target_id,
					hand      = target.hand,
				}), {state.presences[source_id]})
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
        local reward = state.config and state.config.combat.rebel_kill_reward or 3
        M.draw_cards(state, killer_id, reward)
        dispatcher.broadcast_message(11, nk.json_encode({content = killer.username .. " 击毙反贼，奖励 " .. reward .. " 张牌"}))
    elseif victim.role == "MINISTER" and killer.role == "MONARCH" then
        killer.hand = {}
        dispatcher.broadcast_message(11, nk.json_encode({content = "主公误杀忠臣，对手牌进行了大清洗！"}))
    end
end

-- 胜负判定逻辑
function M.check_victory(dispatcher, state)
    -- PVP 模式：任意玩家死亡即结束
    if state.mode == "pvp" then
        for _, p in pairs(state.players) do
            if p.health <= 0 then return true, "PVP_WIN" end
        end
        return false, nil
    end

    -- identity 模式：按角色阵营判定
    local alive = { MONARCH = 0, MINISTER = 0, REBEL = 0, TRAITOR = 0 }
    for _, p in pairs(state.players) do
        if p.health > 0 then
            alive[p.role] = alive[p.role] + 1
        end
    end

    -- 1. 主公阵亡
    if alive.MONARCH == 0 then
        if alive.REBEL == 0 and alive.MINISTER == 0 and alive.TRAITOR == 1 then
            return true, "TRAITOR_WIN"
        end
        return true, "REBEL_WIN"
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
    local hand_size = state.config and state.config.match.initial_hand_size or 4
    for uid, _ in pairs(state.players) do
        M.draw_cards(state, uid, hand_size)
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
    local result = {}
    for i = 1, #t do result[i] = t[i] end
    for i = #result, 2, -1 do
        local j = math.random(i)
        result[i], result[j] = result[j], result[i]
    end
    return result
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
    if not player or player.health <= 0 then return false end

    if type(payload.card_id) ~= "string" then return false end

    local target_id = payload.target_id
    if target_id ~= nil then
        if type(target_id) ~= "string" then return false end
        local target = state.players[target_id]
        if not target or target.health <= 0 then return false end
        if target_id == player_id then return false end
    end

    local card_idx = nil
    local card = nil
    for i, c in ipairs(player.hand) do
        if c.id == payload.card_id then card_idx = i; card = c; break end
    end

    if card_idx then
        -- 苏莱曼【御风】：检查是否被封锁
        if state.suleiman_yu_feng and state.suleiman_yu_feng.target_id == player_id
            and card.type == state.suleiman_yu_feng.blocked_type then
            dispatcher.broadcast_message(11, nk.json_encode({
                content = string.format("%s 被【御风】封锁，无法使用【%s】！",
                    player.username, card.name),
                hero = "suleiman", skill = "yu_feng"
            }))
            return false
        end

        table.remove(player.hand, card_idx)
        -- 装备牌不进弃牌堆，直接进装备槽；其余牌正常弃置
        local is_equipment = card.type == "WEAPON" or card.type == "ARMOR" or card.type == "HORSE"
        if not is_equipment then
            table.insert(state.discard_pile, card)
        end

        if CARD_EFFECTS[card.type] then
            CARD_EFFECTS[card.type](dispatcher, state, player_id, target_id, card)
        end

        M.broadcast_update(dispatcher, state)
        return true
    end
    return false
end

-- 真正处决一名濒死玩家（弃牌、广播、奖惩）
local function execute_death(dispatcher, state, target_id, source_id)
    local target = state.players[target_id]
    local hero_mgr = require("hero_manager")
    if source_id then
        hero_mgr.trigger("on_kill", dispatcher, state, source_id, target_id)
    end
    for i = 1, #target.hand do table.insert(state.discard_pile, table.remove(target.hand)) end
    -- Equipment ownership: slot card → discard_pile; slot cleared to nil.
    -- Cards live in exactly one place: hand, an equipment slot, or discard_pile.
    for _, card in pairs(target.equipment) do
        if card then table.insert(state.discard_pile, card) end
    end
    target.equipment = {weapon = nil, armor = nil, horse = nil}
    log_info(state, target.username .. " 已阵亡，身份是: " .. target.role)
    local ROLE_CN = { MONARCH="主公", MINISTER="忠臣", REBEL="反贼", TRAITOR="内奸" }
    local role_tag = ROLE_CN[target.role]
    dispatcher.broadcast_message(11, nk.json_encode({
        content   = target.username .. (role_tag and "（" .. role_tag .. "）" or "") .. "阵亡！",
        event     = "player_death",
        player_id = target_id,
        role      = target.role,
    }))
    local source = source_id and state.players[source_id]
    if source and source.pending_wine_kill_draw then
        source.pending_wine_kill_draw = nil
        M.draw_cards(state, source_id, 2)
        dispatcher.broadcast_message(11, nk.json_encode({
            content = source.username .. " 因【阿拉伯烈酒】效果额外摸2张"
        }))
    end
    M.handle_role_reward(dispatcher, state, source_id, target_id)
end

function M.handle_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action then return end
    -- 规范化 confirm 为严格 boolean
    payload.confirm = (payload.confirm == true)

    if action.type == "WAITING_FOR_DEFENSE" then
        if action.target_id ~= player_id then return end
        -- 流星锤：无视防具，强制命中
        if state.attack_forced then
            state.attack_forced = nil
            state.pending_action = nil
            M.apply_damage(dispatcher, state, player_id, action.damage or 1, action.attacker_id)
            return
        end
        if payload.confirm == true then
            local defender = state.players[player_id]
            -- 贾法尔【毒计】第二步：已出1张防御，还需再出1张
            if action.jafar_step2 then
                local card_idx = nil
                for i, card in ipairs(defender.hand) do
                    if card.id == payload.card_id and card.type == "DEFENSE" then
                        card_idx = i; break
                    end
                end
                if card_idx and not (state.suleiman_yu_feng and state.suleiman_yu_feng.target_id == player_id and state.suleiman_yu_feng.blocked_type == "DEFENSE") then
                    table.insert(state.discard_pile, table.remove(defender.hand, card_idx))
                    state.pending_action = nil
                    dispatcher.broadcast_message(11, nk.json_encode({
                        content = defender.username .. " 打出第2张【防御】，成功抵挡了贾法尔的【毒计】！",
                    }))
                    M.handle_defense_success(dispatcher, state, action.attacker_id, player_id)
                else
                    if card_idx then
                        dispatcher.broadcast_message(11, nk.json_encode({
                            content = string.format("%s 被【御风】封锁，无法使用【防御】！",
                                defender.username),
                            hero = "suleiman", skill = "yu_feng"
                        }))
                    end
                    state.pending_action = nil
                    M.apply_damage(dispatcher, state, player_id, action.damage or 1, action.attacker_id)
                end
                return
            end
            -- 普通防御 / 贾法尔第一步
            local card_idx = nil
            for i, card in ipairs(defender.hand) do
                if card.id == payload.card_id and card.type == "DEFENSE" then
                    card_idx = i; break
                end
            end
            if not card_idx or (state.suleiman_yu_feng and state.suleiman_yu_feng.target_id == player_id and state.suleiman_yu_feng.blocked_type == "DEFENSE") then
                if card_idx and state.suleiman_yu_feng then
                    dispatcher.broadcast_message(11, nk.json_encode({
                        content = string.format("%s 被【御风】封锁，无法使用【防御】！",
                            state.players[player_id].username),
                        hero = "suleiman", skill = "yu_feng"
                    }))
                end
                state.attack_bonus = nil
                M.apply_damage(dispatcher, state, player_id, action.damage or 1, action.attacker_id)
                if not (state.pending_action and state.pending_action.type == "WAITING_FOR_RESCUE") then
                    state.pending_action = nil
                end
                return
            end
            table.insert(state.discard_pile, table.remove(defender.hand, card_idx))
            -- 贾法尔【毒计】第一步完成：提示需要第二张防御
            if action.jafar_du_ji then
                state.pending_action = {
                    type = "WAITING_FOR_DEFENSE",
                    attacker_id = action.attacker_id,
                    target_id = action.target_id,
                    damage = action.damage,
                    jafar_step2 = true,
                    deadline = os.time() + 15,
                }
                dispatcher.broadcast_message(105, nk.json_encode({
                    attacker = action.attacker_id,
                    target = action.target_id,
                    damage = action.damage,
                    msg = "贾法尔【毒计】！需要再出1张【防御】才能抵挡",
                }))
                return
            end
            state.pending_action = nil
            M.handle_defense_success(dispatcher, state, action.attacker_id, player_id)
        else
            -- 旭烈兀【铁蹄】：attack_bonus 已整合进 action.damage
            state.attack_bonus = nil
            M.apply_damage(dispatcher, state, player_id, action.damage or 1, action.attacker_id)
            -- 若 apply_damage 触发了濒死求救，不覆盖 pending_action
            if not (state.pending_action and state.pending_action.type == "WAITING_FOR_RESCUE") then
                state.pending_action = nil
            end
        end

    elseif action.type == "WAITING_FOR_AOE" then
        if action.current_target ~= player_id then return end
        local defended = false
        if payload.confirm == true and type(payload.card_id) == "string" then
            local defender = state.players[player_id]
            for i, card in ipairs(defender.hand) do
                if card.id == payload.card_id and card.type == "DEFENSE" then
                    -- 苏莱曼【御风】封锁防御
                    if state.suleiman_yu_feng and state.suleiman_yu_feng.target_id == player_id and state.suleiman_yu_feng.blocked_type == "DEFENSE" then
                        dispatcher.broadcast_message(11, nk.json_encode({
                            content = string.format("%s 被【御风】封锁，无法使用【防御】！",
                                defender.username),
                            hero = "suleiman", skill = "yu_feng"
                        }))
                        break
                    end
                    table.insert(state.discard_pile, table.remove(defender.hand, i))
                    defended = true
                    break
                end
            end
        end
        if not defended then
            -- 未防御（或防御牌无效/不存在），扣血
            M.apply_damage(dispatcher, state, player_id, 1, action.attacker_id)
            -- 若扣血触发了濒死求救，暂停 AOE 等待救援，parent_action 已在 apply_damage 中设好
            if state.pending_action and state.pending_action.type == "WAITING_FOR_RESCUE" then
                return
            end
        end
        -- 推进到下一个目标（刷新 deadline，避免前一目标救援耗尽时间后下一目标立即超时）
        if #action.remaining_targets > 0 then
            action.current_target = table.remove(action.remaining_targets, 1)
            action.deadline       = os.time() + 15
            M.notify_aoe_target(dispatcher, state)
        else
            state.pending_action = nil
            M.broadcast_update(dispatcher, state)
        end

    elseif action.type == "WAITING_FOR_RESCUE" then
        local dying_id    = action.dying_player_id
        local rescuer_id  = action.rescuers[action.current_rescuer_idx]
        if player_id ~= rescuer_id then return end

        local rescued = false
        if payload.confirm == true and type(payload.card_id) == "string" then
            local rescuer = state.players[player_id]
            for i, card in ipairs(rescuer.hand) do
                local can_rescue = card.type == "HEAL" or card.type == "WINE"
                    or (card.suit == "HEART" and rescuer.hero == "avicenna")
                if card.id == payload.card_id and can_rescue then
                    table.remove(rescuer.hand, i)
                    table.insert(state.discard_pile, card)
                    state.players[dying_id].health = 1
                    rescued = true
                    dispatcher.broadcast_message(11, nk.json_encode({
                        content         = rescuer.username .. " 救了 " .. state.players[dying_id].username .. "！",
                        event           = "rescue_success",
                        rescuer_id      = player_id,
                        dying_player_id = dying_id,
                    }))
                    break
                end
            end
        end

        local parent = action.parent_action
        local function resume_aoe_or_end(p)
            if p and p.type == "JUDGMENT_CONTINUATION" then
                -- 判定阶段中触发了求救，救援结束后通过 pending_turn_continuation 恢复判定+摸牌
                state.pending_action = nil
                state.pending_turn_continuation = { uid = state.current_turn_id }
                M.broadcast_update(dispatcher, state)
                return
            end
            state.pending_action = p
            if p then
                if #p.remaining_targets > 0 then
                    p.current_target = table.remove(p.remaining_targets, 1)
                    p.deadline       = os.time() + 15
                    M.notify_aoe_target(dispatcher, state)
                else
                    state.pending_action = nil
                    M.broadcast_update(dispatcher, state)
                end
            else
                M.broadcast_update(dispatcher, state)
            end
        end

        if rescued then
            resume_aoe_or_end(parent)
        else
            action.current_rescuer_idx = action.current_rescuer_idx + 1
            action.deadline = os.time() + 10
            if action.current_rescuer_idx <= #action.rescuers then
                local next_id = action.rescuers[action.current_rescuer_idx]
                dispatcher.broadcast_message(11, nk.json_encode({
                    content         = state.players[dying_id].username .. " 仍在濒死，轮到 " .. state.players[next_id].username .. " 救援",
                    event           = "rescue_needed",
                    dying_player_id = dying_id,
                    rescuer_id      = next_id,
                }))
            else
                -- 无人救援，正式处决
                execute_death(dispatcher, state, dying_id, action.attacker_id)
                resume_aoe_or_end(parent)
            end
        end
    elseif action.type == "WAITING_FOR_TRICK_SELECT" then
        if player_id ~= action.chooser_id then return end

        if action.subtype == "peek3_reorder" then
            local peeked = action.peeked
            local placed = false
            if payload.confirm == true and type(payload.sorted_ids) == "table" and #payload.sorted_ids == #peeked then
                local id_map = {}
                for _, c in ipairs(peeked) do id_map[c.id] = c end
                -- validate all ids exist
                local valid = true
                for _, sid in ipairs(payload.sorted_ids) do
                    if type(sid) ~= "string" or not id_map[sid] then valid = false; break end
                end
                if valid then
                    -- put back in the client-chosen order (first in array = top of deck)
                    for i = #payload.sorted_ids, 1, -1 do
                        table.insert(state.deck, 1, id_map[payload.sorted_ids[i]])
                    end
                    placed = true
                end
            end
            if not placed then
                -- timeout or invalid: restore original order
                for i = #peeked, 1, -1 do table.insert(state.deck, 1, peeked[i]) end
            end

        elseif action.subtype == "discard_enemy_card" then
            local target = state.players[action.target_id]
            local discarded = nil
            if target and #target.hand > 0 then
                if payload.confirm == true and type(payload.card_id) == "string" then
                    for i, card in ipairs(target.hand) do
                        if card.id == payload.card_id then
                            discarded = table.remove(target.hand, i)
                            break
                        end
                    end
                end
                -- fallback: random if no valid selection
                if not discarded then
                    discarded = table.remove(target.hand, math.random(#target.hand))
                end
                table.insert(state.discard_pile, discarded)
                local chooser = state.players[action.chooser_id]
                dispatcher.broadcast_message(11, nk.json_encode({
                    content  = (chooser and chooser.username or "?") .. " 使用【诱降】弃置了 " .. (discarded.name or discarded.type),
                    event    = "trick_discard",
                    card     = discarded,
                    target_id = action.target_id,
                }))
            end
        end

        state.pending_action = nil
        M.broadcast_update(dispatcher, state)
    end
end

-- 防御成功后续逻辑（pending_action 由调用方在进入本函数前已清除）
function M.handle_defense_success(dispatcher, state, attacker_id, defender_id)
    log_info(state, "防御成功，正在检查攻击者是否有追击技能...")
    local hero_mgr = require("hero_manager")
    local suspended = hero_mgr.trigger("on_attack_defended", dispatcher, state, defender_id, attacker_id)
    if not suspended then
        dispatcher.broadcast_message(11, nk.json_encode({content = "防御成功！"}))
        M.broadcast_update(dispatcher, state)
    end
end



function M.apply_damage(dispatcher, state, target_id, amount, source_id)
    local target = state.players[target_id]
    if not target or target.health <= 0 then return end

    -- 计算攻击加成（来源方装备+酒牌），固定伤害场景跳过
    local source = source_id and state.players[source_id]
    if source and not state._fixed_damage then
        -- 武器加成
        if source.equipment.weapon then
            local wtype = source.equipment.weapon.subtype
            if wtype == "sword" then
                amount = amount + (state.config and state.config.combat.sword_damage_bonus or 1)
            end
        end
        -- 酒牌buff：仅对杀生效，AOE/锦囊不触发（buff 保留）
        local is_aoe = state.pending_action and state.pending_action.type == "WAITING_FOR_AOE"
        if source.weapon_buff and not is_aoe then
            amount = amount + (state.config and state.config.combat.wine_damage_bonus or 1)
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
            local reduce = state.config and state.config.combat.armor_damage_reduce or 1
            amount = math.max(0, amount - reduce)
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

    -- 累计伤害统计
    if amount > 0 then
        if source and source_id then
            source.damage_dealt = (source.damage_dealt or 0) + amount
        end
        target.damage_received = (target.damage_received or 0) + amount
    end

    local hero_mgr = require("hero_manager")
    local reduced = hero_mgr.trigger("on_before_damage", dispatcher, state, target_id, amount, source_id)
    if reduced then amount = amount - 1 end
    if amount <= 0 then return end

    target.health = target.health - amount

    if source and source_id then
        hero_mgr.trigger("on_damage_dealt", dispatcher, state, source_id, amount, target_id)
    end
    hero_mgr.trigger("on_damaged", dispatcher, state, target_id, amount, source_id)

    dispatcher.broadcast_message(20, nk.json_encode({ event = "damage", target = target_id, source = source_id, amount = amount }))

    if target.health <= 0 then
        -- 进入濒死求救流程：从濒死者的下一位存活玩家开始，依次询问是否救援
        local rescuers = {}
        local start_idx = 1
        for i, uid in ipairs(state.presence_ids) do
            if uid == target_id then start_idx = i + 1; break end
        end
        local n = #state.presence_ids
        for i = 0, n - 1 do
            local uid = state.presence_ids[((start_idx - 1 + i) % n) + 1]
            if uid ~= target_id and state.players[uid] and state.players[uid].health > 0 then
                table.insert(rescuers, uid)
            end
        end

        -- 保存父 pending_action：AOE → 继续 AOE；判定阶段 → 继续判定+摸牌；普通攻击 → nil
        local parent
        if state.pending_action and state.pending_action.type == "WAITING_FOR_AOE" then
            parent = state.pending_action
        elseif state._in_judgment_phase then
            parent = { type = "JUDGMENT_CONTINUATION" }
        end

        if #rescuers > 0 then
            state.pending_action = {
                type                = "WAITING_FOR_RESCUE",
                dying_player_id     = target_id,
                attacker_id         = source_id,
                rescuers            = rescuers,
                current_rescuer_idx = 1,
                deadline            = os.time() + 10,
                parent_action       = parent,
            }
            dispatcher.broadcast_message(11, nk.json_encode({
                content         = target.username .. " 濒死，请求救援！",
                event           = "rescue_needed",
                dying_player_id = target_id,
                rescuer_id      = rescuers[1],
            }))
        else
            -- 没有人可以救援，直接处决
            execute_death(dispatcher, state, target_id, source_id)
            state.pending_action = parent
        end
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
            pending = state.pending_action and {
                type = state.pending_action.type,
                player_id = state.pending_action.player_id,
                deadline = state.pending_action.deadline,
            } or nil,
            me = {
                hand            = p_data.hand,
                hp              = p_data.health,
                role            = p_data.role,
                equipment       = p_data.equipment,
                delayed_effects = p_data.delayed_effects,
                weapon_buff     = p_data.weapon_buff,
                skin_id         = p_data.skin_id,
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
                    id         = other_id,
                    username   = other_p.username,
                    hp         = other_p.health,
                    hand_count = #other_p.hand,
                    hero       = other_p.hero,
                    role       = visible_role,
                    equipment  = other_p.equipment,
                    skin_id    = other_p.skin_id,
                })
            end
        end
        dispatcher.broadcast_message(10, nk.json_encode(payload), {presence})

        -- 同步给所有旁观该玩家的旁观者（视野与该玩家完全相同）
        if state.spectators then
            for _, spec in pairs(state.spectators) do
                if spec.target_player_id == uid then
                    local spec_payload = {
                        is_spectator    = true,
                        current_turn    = payload.current_turn,
                        pending         = payload.pending,
                        me              = payload.me,
                        others          = payload.others,
                    }
                    dispatcher.broadcast_message(10, nk.json_encode(spec_payload), {spec.presence})
                end
            end
        end
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

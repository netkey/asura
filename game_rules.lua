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
    -- 杀 — 等待防御响应
    ["ATTACK"] = function(dispatcher, state, source_id, target_id, card)
        local hero_mgr = require("hero_manager")
        local p = state.players[source_id]
        local target = state.players[target_id]
        if not target or target.health <= 0 then return end

        -- 攻击前钩子（阿拉丁/贾法尔/杜尼亚扎德/旭烈兀等）
        hero_mgr.trigger("on_before_attack", dispatcher, state, source_id, target_id)

        -- 杜尼亚扎德【续篇】：本回合已被该目标免疫
        if state.dunyazad_immune and state.dunyazad_immune[source_id] == target_id then
            dispatcher.broadcast_message(11, nk.json_encode({
                content = state.players[target_id].username .. " 的【续篇】令此次攻击无效"
            }))
            state.attack_bonus = nil
            state.attack_cancelled = nil
            state.dunyazad_immune = nil
            state.jafar_du_ji = nil
            return
        end

        -- 旭烈兀【铁蹄】取消攻击
        if state.attack_cancelled then
            state.attack_bonus = nil
            state.attack_cancelled = nil
            return
        end

        -- 仁王盾：黑色攻击被封锁
        if target.equipment.armor and target.equipment.armor.subtype == "block_black_attack" then
            if card.suit == "SPADE" or card.suit == "CLUB" then
                dispatcher.broadcast_message(11, nk.json_encode({
                    content = target.username .. " 的【仁王盾】挡住了黑色攻击！"
                }))
                return
            end
        end

        -- attacks_this_turn 已在 handle_play_card 中递增
        if p then p.attacks_this_turn = (p.attacks_this_turn or 0) + 1 end

        -- 计算基础伤害（含 attack_debuff）
        local dmg = 1
        if p and p.attack_debuff then dmg = math.max(0, dmg - 1) end

        -- 旭烈兀【铁蹄】attack_bonus
        if state.attack_bonus then
            dmg = dmg + state.attack_bonus
            state.attack_bonus = nil
        end

        -- 古锭刀：目标无手牌时伤害+1
        if p and p.equipment.weapon and p.equipment.weapon.subtype == "blade_pierce" then
            if #target.hand == 0 then dmg = dmg + 1 end
        end

        -- 火攻：攻击标记为火焰伤害
        local dmg_type = "normal"
        if p and p.equipment.weapon and p.equipment.weapon.subtype == "fire_weapon" then
            dmg_type = "fire"
        end

        -- 八卦阵：先判定
        if target.equipment.armor and target.equipment.armor.subtype == "dodge_judgment" then
            local judge_card = M.execute_judgment(state)
            local is_red = judge_card.suit == "HEART" or judge_card.suit == "DIAMOND"
            dispatcher.broadcast_message(11, nk.json_encode({
                content = target.username .. " 的【八卦阵】判定为 "
                    .. (judge_card.suit or "?") .. " " .. (judge_card.number or "?")
                    .. "（" .. (is_red and "红色" or "黑色") .. "）"
            }))
            if is_red then
                -- 红色=自动闪避
                dispatcher.broadcast_message(11, nk.json_encode({
                    content = target.username .. " 的【八卦阵】判定成功，自动闪避！"
                }))
                return
            end
            -- 黑色=八卦阵无效，继续走防御
            dispatcher.broadcast_message(11, nk.json_encode({
                content = target.username .. " 的【八卦阵】判定失败，仍需出【防御】"
            }))
        end

        -- 进入等待防御状态
        state.pending_action = {
            type = "WAITING_FOR_DEFENSE",
            attacker_id = source_id,
            target_id = target_id,
            damage = dmg,
            damage_type = dmg_type,
            jafar_du_ji = state.jafar_du_ji,
            attack_card = card,
            deadline = os.time() + 15,
        }
        state.jafar_du_ji = nil

        -- 通知目标出防御
        dispatcher.broadcast_message(105, nk.json_encode({
            attacker = source_id,
            target = target_id,
            damage = dmg,
            msg = "受到攻击，请出示【防御】"
        }))
    end,

    -- 桃 — 恢复 1 点生命值
    ["HEAL"] = function(dispatcher, state, source_id)
        local p = state.players[source_id]
        if p.health < p.max_health then
            p.health = p.health + 1
            dispatcher.broadcast_message(11, nk.json_encode({
                content = p.username .. " 使用了【药】，恢复了 1 点生命值"
            }))
        end
    end,

    -- 酒 — 标记 weapon_buff，下次攻击伤害+1
    ["WINE"] = function(dispatcher, state, source_id, _, card)
        local p = state.players[source_id]
        -- weapon_buff 由 handle_play_card 统一维护
        dispatcher.broadcast_message(11, nk.json_encode({
            content = p.username .. " 饮【" .. card.name .. "】，下次攻击伤害+1",
            card = card
        }))
    end,

    -- 武器 — 装备到武器槽，替换旧武器
    ["WEAPON"] = function(dispatcher, state, source_id, _, card)
        local p = state.players[source_id]
        local old = p.equipment.weapon
        if old then
            table.insert(state.discard_pile, old)
        end
        p.equipment.weapon = card
        dispatcher.broadcast_message(11, nk.json_encode({
            content = p.username .. " 装备【" .. card.name .. "】",
            card = card
        }))
    end,

    -- 防具 — 装备到防具槽，替换旧防具
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

    -- 马牌 — 装备到马槽，替换旧马
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

    -- 即时锦囊
    ["INSTANT_TRICK"] = function(dispatcher, state, source_id, target_id, card)
        local p = state.players[source_id]

        if card.subtype == "draw_two" then
            -- 无中生有
            dispatcher.broadcast_message(11, nk.json_encode({
                content = p.username .. " 使用了【无中生有】",
                card_type = "draw_two"
            }))
            M.draw_cards(state, source_id, 2)
            M.broadcast_update(dispatcher, state)

        elseif card.subtype == "aoe_attack" then
            -- 南蛮入侵：全场出杀（按座位顺序）
            local targets = {}
            for _, uid in ipairs(state.presence_ids) do
                local p2 = state.players[uid]
                if uid ~= source_id and p2 and p2.health > 0 then
                    table.insert(targets, uid)
                end
            end
            if #targets == 0 then return end

            state.pending_action = {
                type = "WAITING_FOR_AOE",
                attacker_id = source_id,
                remaining_targets = targets,
                current_target = table.remove(targets, 1),
                aoe_subtype = "aoe_attack",
                required_response = "ATTACK",
                deadline = os.time() + 15,
            }
            dispatcher.broadcast_message(11, nk.json_encode({
                content = p.username .. " 发动了【沙漠侵袭】（南蛮入侵），全体需出【杀】！"
            }))
            M.notify_aoe_target(dispatcher, state)

        elseif card.subtype == "aoe_defense" then
            -- 万箭齐发：全场出闪（按座位顺序）
            local targets = {}
            for _, uid in ipairs(state.presence_ids) do
                local p2 = state.players[uid]
                if uid ~= source_id and p2 and p2.health > 0 then
                    table.insert(targets, uid)
                end
            end
            if #targets == 0 then return end

            state.pending_action = {
                type = "WAITING_FOR_AOE",
                attacker_id = source_id,
                remaining_targets = targets,
                current_target = table.remove(targets, 1),
                aoe_subtype = "aoe_defense",
                required_response = "DEFENSE",
                deadline = os.time() + 15,
            }
            dispatcher.broadcast_message(11, nk.json_encode({
                content = p.username .. " 发动了【万箭齐发】，全体需出【闪】！"
            }))
            M.notify_aoe_target(dispatcher, state)

        elseif card.subtype == "duel" then
            -- 决斗
            local target = state.players[target_id]
            if not target then return end

            dispatcher.broadcast_message(11, nk.json_encode({
                content = p.username .. " 对 " .. target.username .. " 发起决斗！"
            }))

            -- 检查目标是否有杀
            local has_attack = false
            for _, c in ipairs(target.hand) do
                if c.type == "ATTACK" then has_attack = true; break end
            end
            if not has_attack then
                -- 无杀立即受伤害
                dispatcher.broadcast_message(11, nk.json_encode({
                    content = target.username .. " 无法出【杀】，决斗失败，受到 1 点伤害"
                }))
                M.apply_damage(dispatcher, state, target_id, 1, source_id)
                return
            end

            state.pending_action = {
                type = "WAITING_FOR_DUEL",
                attacker_id = source_id,
                target_id = target_id,
                is_attackers_turn = false,  -- 目标先出杀
                deadline = os.time() + 15,
            }
            dispatcher.broadcast_message(105, nk.json_encode({
                event = "duel_require_attack",
                target_id = target_id,
                msg = "决斗！请出【杀】或放弃（将受1点伤害）",
            }))

        elseif card.subtype == "discard_one" then
            -- 过河拆桥
            local target = state.players[target_id]
            if not target then return end
            if #target.hand == 0 and not target.equipment.weapon
                and not target.equipment.armor and not target.equipment.horse then
                return  -- 无可弃牌
            end

            dispatcher.broadcast_message(11, nk.json_encode({
                content = p.username .. " 对 " .. target.username .. " 使用【诱降】"
            }))

            state.pending_action = {
                type = "WAITING_FOR_TRICK_SELECT",
                subtype = "discard_one",
                source_id = source_id,
                target_id = target_id,
                deadline = os.time() + 15,
            }
            if state.presences[source_id] then
                dispatcher.broadcast_message(106, nk.json_encode({
                    event = "pick_target_card",
                    target_id = target_id,
                    hand = target.hand,
                    equipment = target.equipment,
                    purpose = "discard",
                }), {state.presences[source_id]})
            end

        elseif card.subtype == "steal_one" then
            -- 顺手牵羊（需在攻击距离1内）
            local target = state.players[target_id]
            if not target then return end
            if #target.hand == 0 and not target.equipment.weapon
                and not target.equipment.armor and not target.equipment.horse then
                return
            end

            dispatcher.broadcast_message(11, nk.json_encode({
                content = p.username .. " 对 " .. target.username .. " 使用【顺手牵羊】"
            }))

            state.pending_action = {
                type = "WAITING_FOR_TRICK_SELECT",
                subtype = "steal_one",
                source_id = source_id,
                target_id = target_id,
                deadline = os.time() + 15,
            }
            if state.presences[source_id] then
                dispatcher.broadcast_message(106, nk.json_encode({
                    event = "pick_target_card",
                    target_id = target_id,
                    hand = target.hand,
                    equipment = target.equipment,
                    purpose = "steal",
                }), {state.presences[source_id]})
            end

        elseif card.subtype == "mass_heal" then
            -- 桃园结义：全场各回复1点
            dispatcher.broadcast_message(11, nk.json_encode({
                content = p.username .. " 使用了【桃园结义】，全体回复 1 点生命值"
            }))
            for _, p2 in pairs(state.players) do
                if p2.health > 0 and p2.health < p2.max_health then
                    p2.health = p2.health + 1
                end
            end
            M.broadcast_update(dispatcher, state)

        elseif card.subtype == "mass_draw" then
            -- 五谷丰登：按座次各摸1张
            dispatcher.broadcast_message(11, nk.json_encode({
                content = p.username .. " 使用了【五谷丰登】，全体摸牌"
            }))
            for _, uid in ipairs(state.presence_ids) do
                local p2 = state.players[uid]
                if p2 and p2.health > 0 then
                    M.draw_cards(state, uid, 1)
                end
            end
            M.broadcast_update(dispatcher, state)

        elseif card.subtype == "borrow_weapon" then
            -- 借刀杀人：目标需有武器 + 有可攻击的对象
            local target = state.players[target_id]
            if not target or not target.equipment.weapon then
                dispatcher.broadcast_message(11, nk.json_encode({
                    content = "【借刀杀人】目标无武器或已阵亡"
                }))
                return
            end

            -- 找合法攻击目标（存活、非本人、在射程内）
            local valid_targets = {}
            for uid, p2 in pairs(state.players) do
                if uid ~= source_id and uid ~= target_id and p2.health > 0
                    and M.can_attack(state, target_id, uid) then
                    table.insert(valid_targets, { id = uid, username = p2.username })
                end
            end
            if #valid_targets == 0 then
                dispatcher.broadcast_message(11, nk.json_encode({
                    content = "【借刀杀人】无可攻击的目标"
                }))
                return
            end

            dispatcher.broadcast_message(11, nk.json_encode({
                content = p.username .. " 对 " .. target.username .. " 使用【借刀杀人】"
            }))

            -- 让使用者选择攻击目标
            state.pending_action = {
                type = "WAITING_FOR_TRICK_SELECT",
                subtype = "borrow_weapon",
                source_id = source_id,
                target_id = target_id,
                valid_targets = valid_targets,
                deadline = os.time() + 15,
            }
            if state.presences[source_id] then
                dispatcher.broadcast_message(106, nk.json_encode({
                    event = "choose_attack_target",
                    valid_targets = valid_targets,
                    purpose = "borrow_weapon",
                }), {state.presences[source_id]})
            end

        elseif card.subtype == "fire_attack" then
            -- 火攻：目标展示一张手牌，猜花色
            local target = state.players[target_id]
            if not target or target.health <= 0 or #target.hand == 0 then
                dispatcher.broadcast_message(11, nk.json_encode({
                    content = "【火攻】目标无手牌或已阵亡"
                }))
                return
            end

            dispatcher.broadcast_message(11, nk.json_encode({
                content = p.username .. " 对 " .. target.username .. " 使用【火攻】"
            }))

            -- 随机选一张展示（或让目标选择——当前简化版随机）
            local show_idx = math.random(#target.hand)
            local revealed = target.hand[show_idx]
            dispatcher.broadcast_message(11, nk.json_encode({
                content = target.username .. " 展示了【" .. revealed.name .. "】（" .. revealed.suit .. "）"
            }))

            state.pending_action = {
                type = "WAITING_FOR_FIRE_GUESS",
                caster_id = source_id,
                target_id = target_id,
                revealed_card = revealed,
                deadline = os.time() + 15,
            }
            if state.presences[source_id] then
                dispatcher.broadcast_message(106, nk.json_encode({
                    event = "fire_guess",
                    target_hand = revealed.suit,  -- 服务端直接告诉客户端实际花色
                    prompt = "猜花色（HEART/SPADE/CLUB/DIAMOND）",
                }), {state.presences[source_id]})
            end

        elseif card.subtype == "iron_chain" then
            -- 铁索连环：重铸（无目标时弃牌摸1）或连环目标
            if not target_id then
                -- 重铸
                dispatcher.broadcast_message(11, nk.json_encode({
                    content = p.username .. " 重铸了【铁索连环】"
                }))
                M.draw_cards(state, source_id, 1)
                M.broadcast_update(dispatcher, state)
            else
                -- 连环目标（切换目标的连环状态）
                local target = state.players[target_id]
                if not target then return end
                target.iron_chained = not target.iron_chained
                local status = target.iron_chained and "被连环" or "解除连环"
                dispatcher.broadcast_message(11, nk.json_encode({
                    content = target.username .. status
                }))
                M.broadcast_update(dispatcher, state)
            end
        end
    end,

    -- 延时锦囊：挂在目标 delayed_effects，判定阶段处理
    ["DELAYED_TRICK"] = function(dispatcher, state, source_id, target_id, card)
        local target = state.players[target_id or source_id]
        table.insert(target.delayed_effects, {
            id = card.id,
            name = card.name,
            subtype = card.subtype,
            suit = card.suit,
            number = card.number,
            from = source_id,
        })
        dispatcher.broadcast_message(11, nk.json_encode({
            content = target.username .. " 被挂上【" .. card.name .. "】",
            card = card
        }))
    end,
}
M.CARD_EFFECTS = CARD_EFFECTS

-- ==========================================
-- 2. AOE 通知
-- ==========================================
function M.notify_aoe_target(dispatcher, state)
    local action = state.pending_action
    if not action or action.type ~= "WAITING_FOR_AOE" then return end

    local target_id = action.current_target
    if not target_id then
        state.pending_action = nil
        M.broadcast_update(dispatcher, state)
        return
    end

    local required_name = action.required_response == "ATTACK" and "【杀】" or "【闪】"
    dispatcher.broadcast_message(105, nk.json_encode({
        attacker = action.attacker_id,
        target   = target_id,
        required = action.required_response,
        msg      = "受到范围攻击，请出示" .. required_name .. "或放弃"
    }))
end

-- ==========================================
-- 3. 距离系统
-- ==========================================

-- 座位距离（双向最短路径）
function M.seat_distance(state, a_id, b_id)
    if a_id == b_id then return 0 end
    local a_seat, b_seat
    for i, uid in ipairs(state.presence_ids) do
        if uid == a_id then a_seat = i end
        if uid == b_id then b_seat = i end
    end
    if not a_seat or not b_seat then return 99 end
    local n = #state.presence_ids
    local diff = math.abs(a_seat - b_seat)
    return math.min(diff, n - diff)
end

-- 武器射程
function M.weapon_range(state, player_id)
    local p = state.players[player_id]
    if not p or not p.equipment.weapon then return 1 end
    local ranges = {
        unlimited_attack  = 1,
        reattempt_discard2= 3,
        reattempt_attack  = 3,
        spear_discard2    = 3,
        halberd_triple    = 4,
        blade_pierce      = 2,
        twin_discard      = 2,
        fire_weapon       = 1,
        bow_strip_horse   = 5,
    }
    local range = ranges[p.equipment.weapon.subtype]
    if not range then
        nk.logger_warn(string.format("weapon_range: 未知 subtype=%s, 默认射程 1", p.equipment.weapon.subtype))
        return 1
    end
    return range
end

-- 是否能攻击目标（距离+武器射程检查）
-- 进攻马-1，防守马+1，二者叠加
function M.can_attack(state, src_id, tgt_id)
    if src_id == tgt_id then return false end
    -- 双角王【远疆-西行】：本回合杀无距离限制
    if state.dhul_westward and state.dhul_westward[src_id] then return true end
    local dist = M.seat_distance(state, src_id, tgt_id)
    local src = state.players[src_id]
    if src and src.equipment.horse and src.equipment.horse.subtype == "offense" then
        dist = math.max(0, dist - 1)
    end
    local tgt = state.players[tgt_id]
    if tgt and tgt.equipment.horse and tgt.equipment.horse.subtype == "defense" then
        dist = dist + 1
    end
    local range = M.weapon_range(state, src_id)
    return dist <= range
end

-- ==========================================
-- 4. 身份奖惩 + 胜负判定
-- ==========================================

function M.handle_role_reward(dispatcher, state, killer_id, victim_id)
    local killer = state.players[killer_id]
    local victim = state.players[victim_id]
    if not killer or not victim then return end

    if victim.role == "REBEL" then
        local reward = state.config and state.config.combat.rebel_kill_reward or 3
        M.draw_cards(state, killer_id, reward)
        dispatcher.broadcast_message(11, nk.json_encode({
            content = killer.username .. " 击毙反贼，奖励 " .. reward .. " 张牌"
        }))
    elseif victim.role == "MINISTER" and killer.role == "MONARCH" then
        killer.hand = {}
        dispatcher.broadcast_message(11, nk.json_encode({
            content = "主公误杀忠臣，对手牌进行了大清洗！"
        }))
    end
end

function M.check_victory(dispatcher, state)
    if state.mode == "pvp" then
        local alive = 0
        local winner
        for _, p in pairs(state.players) do
            if p.health > 0 then alive = alive + 1; winner = p.id end
        end
        if alive <= 1 then return true, winner end
        return false, nil
    end

    local alive = { MONARCH = 0, MINISTER = 0, REBEL = 0, TRAITOR = 0 }
    for _, p in pairs(state.players) do
        if p.health > 0 then
            alive[p.role] = alive[p.role] + 1
        end
    end

    if alive.MONARCH == 0 then
        if alive.REBEL == 0 and alive.MINISTER == 0 and alive.TRAITOR == 1 then
            return true, "TRAITOR_WIN"
        end
        return true, "REBEL_WIN"
    end

    if alive.REBEL == 0 and alive.TRAITOR == 0 then
        return true, "MONARCH_WIN"
    end

    return false, nil
end

-- ==========================================
-- 5. 基础功能（牌堆、摸牌等）
-- ==========================================

function M.start_game(dispatcher, state)
    local hand_size = state.config and state.config.match.initial_hand_size or 4
    for uid, _ in pairs(state.players) do
        M.draw_cards(state, uid, hand_size)
    end
end

function M.create_deck()
    local card_deck = require("card_deck")
    return card_deck.create_deck()
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
    for i, id in ipairs(state.presence_ids) do
        if id == state.current_turn_id then
            current_idx = i
            break
        end
    end

    local next_idx = current_idx
    for i = 1, #state.presence_ids do
        next_idx = (next_idx % #state.presence_ids) + 1
        local next_uid = state.presence_ids[next_idx]
        if state.players[next_uid].health > 0 then
            return next_uid
        end
    end
    return state.current_turn_id
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
-- 6. 核心出牌与伤害
-- ==========================================

function M.handle_play_card(dispatcher, state, player_id, payload)
    local player = state.players[player_id]
    if not player or player.health <= 0 then return false end

    if type(payload.card_id) ~= "string" then return false end

    -- 如果玩家有活跃的待响应操作，阻止自由出牌
    if state.pending_action then
        local pa = state.pending_action
        local blocked = false
        if pa.type == "WAITING_FOR_DEFENSE" and pa.target_id == player_id then
            blocked = true
        elseif pa.type == "WAITING_FOR_AOE" and pa.current_target == player_id then
            blocked = true
        elseif pa.type == "WAITING_FOR_DUEL" then
            local current = pa.is_attackers_turn and pa.attacker_id or pa.target_id
            if current == player_id then blocked = true end
        elseif pa.type == "WAITING_FOR_TRICK_SELECT" and pa.source_id == player_id then
            blocked = true
        elseif pa.type == "WAITING_FOR_COUNTER" then
            if pa.current_target == player_id or pa.caster_id == player_id then
                blocked = true
            end
        elseif pa.type == "WAITING_FOR_BORROW_WEAPON" and pa.target_id == player_id then
            blocked = true
        elseif pa.type == "WAITING_FOR_FIRE_GUESS" and pa.caster_id == player_id then
            blocked = true
        elseif pa.type == "WAITING_FOR_RESCUE" then
            local rescuer = pa.rescuers and pa.rescuers[pa.current_rescuer_idx]
            if rescuer == player_id then blocked = true end
        elseif pa.player_id == player_id then
            -- 英雄技能选择（HAKIM_XING_XIANG / AL_KHWARIZMI_SUANFA / SCHEHERAZADE_QIANYE）
            blocked = true
        end
        if blocked then return false end
    end

    local target_id = payload.target_id
    if target_id ~= nil then
        if type(target_id) ~= "string" then return false end
        local target = state.players[target_id]
        if not target or target.health <= 0 then return false end
        if target_id == player_id then
            -- 只有延时锦囊可以对自己使用
            local cid = payload.card_id
            local found = false
            for _, c in ipairs(player.hand) do
                if c.id == cid then found = (c.type == "DELAYED_TRICK"); break end
            end
            if not found then return false end
        end
    end

    local card_idx = nil
    local card = nil
    for i, c in ipairs(player.hand) do
        if c.id == payload.card_id then card_idx = i; card = c; break end
    end
    if not card_idx then return false end

    -- ========== 前置校验 ==========

    -- 苏莱曼【御风】：检查封锁
    if state.suleiman_yu_feng and state.suleiman_yu_feng.target_id == player_id
        and card.type == state.suleiman_yu_feng.blocked_type then
        dispatcher.broadcast_message(11, nk.json_encode({
            content = string.format("%s 被【御风】封锁，无法使用【%s】！",
                player.username, card.name),
            hero = "suleiman", skill = "yu_feng"
        }))
        return false
    end

    -- 酒每回合限1次（增伤用）
    if card.type == "WINE" and player.wine_used_this_turn then
        dispatcher.broadcast_message(11, nk.json_encode({
            content = player.username .. " 本回合已用过酒，无法再使用"
        }))
        return false
    end

    -- 攻击次数限制（连弩机无视）
    if card.type == "ATTACK" then
        local has_unlimited = player.equipment.weapon
            and player.equipment.weapon.subtype == "unlimited_attack"
        if (player.attacks_this_turn or 0) >= 1 and not has_unlimited then
            dispatcher.broadcast_message(11, nk.json_encode({
                content = player.username .. " 本回合已出过【杀】，无法再出"
            }))
            return false
        end
    end

    -- 距离检查（杀/顺手牵羊）
    if card.type == "ATTACK" and target_id then
        if not M.can_attack(state, player_id, target_id) then
            dispatcher.broadcast_message(11, nk.json_encode({
                content = player.username .. " 攻击距离不足，无法攻击 " .. state.players[target_id].username
            }))
            return false
        end
    end

    -- 顺手牵羊也需要距离检查（默认距离1）
    if card.type == "INSTANT_TRICK" and card.subtype == "steal_one" and target_id then
        local dist = M.seat_distance(state, player_id, target_id)
        if dist > 1 then
            dispatcher.broadcast_message(11, nk.json_encode({
                content = player.username .. " 距离 " .. state.players[target_id].username
                    .. " 太远，无法使用【顺手牵羊】"
            }))
            return false
        end
    end

    -- ========== 前置校验通过，通知钩子（双角王记录卡牌供【远疆】额外目标使用） ==========
    local hero_mgr = require("hero_manager")
    hero_mgr.trigger("on_card_played", dispatcher, state, player_id, card)

    -- ========== 移除手牌 ==========
    table.remove(player.hand, card_idx)

    -- 无懈可击不可在出牌阶段主动使用，只能作为响应回传
    if card.type == "INSTANT_TRICK" and card.subtype == "counterspell" then
        table.insert(player.hand, card)
        return false
    end

    -- 锦囊牌在生效前需经无懈可击窗口
    local is_counterable = (card.type == "INSTANT_TRICK" or card.type == "DELAYED_TRICK")
    if is_counterable then
        state.pending_trick = { card = card, source_id = player_id, target_id = target_id }

        -- 构建询问列表（除使用者外所有存活玩家，按座次顺序从下家开始）
        local remaining = {}
        local found = false
        for _, uid in ipairs(state.presence_ids) do
            if found and state.players[uid] and state.players[uid].health > 0 then
                table.insert(remaining, uid)
            end
            if uid == player_id then found = true end
        end
        for _, uid in ipairs(state.presence_ids) do
            if uid == player_id then break end
            if state.players[uid] and state.players[uid].health > 0 then
                table.insert(remaining, uid)
            end
        end

        if #remaining == 0 then
            M.resolve_pending_trick(dispatcher, state)
        else
            state.pending_action = {
                type = "WAITING_FOR_COUNTER",
                caster_id = player_id,
                remaining_order = remaining,
                current_idx = 1,
                current_target = remaining[1],
                counter_depth = 0,
                deadline = os.time() + 15,
            }
            M.notify_counter_target(dispatcher, state)
        end
        M.broadcast_update(dispatcher, state)
        return true
    end

    -- 装备牌不进弃牌堆，其余正常弃置
    local is_equipment = card.type == "WEAPON" or card.type == "ARMOR" or card.type == "HORSE"
    if not is_equipment then
        table.insert(state.discard_pile, card)
    end

    -- 酒使用标记
    if card.type == "WINE" then
        player.wine_used_this_turn = true
        player.weapon_buff = true
    end

    -- 执行卡牌效果
    if CARD_EFFECTS[card.type] then
        CARD_EFFECTS[card.type](dispatcher, state, player_id, target_id, card)
    end

    M.broadcast_update(dispatcher, state)
    return true
end

-- 处决濒死玩家
local function execute_death(dispatcher, state, target_id, source_id)
    local target = state.players[target_id]
    local hero_mgr = require("hero_manager")
    if source_id then
        hero_mgr.trigger("on_kill", dispatcher, state, source_id, target_id)
    end
    for i = 1, #target.hand do table.insert(state.discard_pile, table.remove(target.hand)) end
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
    M.handle_role_reward(dispatcher, state, source_id, target_id)
end

function M.handle_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action then return end
    payload.confirm = (payload.confirm == true)

    -- ==================== 防御响应 ====================
    if action.type == "WAITING_FOR_DEFENSE" then
        if action.target_id ~= player_id then return end

        -- 流星锤（旧武器兼容）：无视防具，强制命中
        if state.attack_forced then
            state.attack_forced = nil
            state.pending_action = nil
            M.apply_damage(dispatcher, state, player_id, action.damage or 1, action.attacker_id, action.damage_type)
            M.broadcast_update(dispatcher, state)
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
                if card_idx and not (state.suleiman_yu_feng
                    and state.suleiman_yu_feng.target_id == player_id
                    and state.suleiman_yu_feng.blocked_type == "DEFENSE") then
                    table.insert(state.discard_pile, table.remove(defender.hand, card_idx))
                    state.pending_action = nil
                    dispatcher.broadcast_message(11, nk.json_encode({
                        content = defender.username .. " 打出第2张【防御】，成功抵挡了贾法尔的【毒计】！",
                    }))
                    M.handle_defense_success(dispatcher, state, action.attacker_id, player_id)
                else
                    if card_idx then
                        dispatcher.broadcast_message(11, nk.json_encode({
                            content = string.format("%s 被【御风】封锁，无法使用【防御】！", defender.username),
                            hero = "suleiman", skill = "yu_feng"
                        }))
                    end
                    state.pending_action = nil
                    M.apply_damage(dispatcher, state, player_id, action.damage or 1, action.attacker_id, action.damage_type)
                    M.broadcast_update(dispatcher, state)
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
            if not card_idx or (state.suleiman_yu_feng
                and state.suleiman_yu_feng.target_id == player_id
                and state.suleiman_yu_feng.blocked_type == "DEFENSE") then
                if card_idx and state.suleiman_yu_feng then
                    dispatcher.broadcast_message(11, nk.json_encode({
                        content = string.format("%s 被【御风】封锁，无法使用【防御】！", state.players[player_id].username),
                        hero = "suleiman", skill = "yu_feng"
                    }))
                end
                state.attack_bonus = nil
                M.apply_damage(dispatcher, state, player_id, action.damage or 1, action.attacker_id, action.damage_type)
                if not (state.pending_action and state.pending_action.type == "WAITING_FOR_RESCUE") then
                    state.pending_action = nil
                    M.broadcast_update(dispatcher, state)
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
                    damage_type = action.damage_type,
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

            -- 正常防御成功
            state.pending_action = nil
            M.handle_defense_success(dispatcher, state, action.attacker_id, player_id)
        else
            -- 放弃防御：直接受伤害
            state.attack_bonus = nil
            M.apply_damage(dispatcher, state, player_id, action.damage or 1, action.attacker_id, action.damage_type)
            if not (state.pending_action and state.pending_action.type == "WAITING_FOR_RESCUE") then
                state.pending_action = nil
                M.broadcast_update(dispatcher, state)
                -- 攻击链完全结束（无濒死），通知 hook（双角王【远疆-西行】额外目标）
                local hero_mgr = require("hero_manager")
                hero_mgr.trigger("on_attack_resolved", dispatcher, state, action.attacker_id)
            end
        end

    -- ==================== AOE 响应 ====================
    elseif action.type == "WAITING_FOR_AOE" then
        if action.current_target ~= player_id then return end
        local defended = false
        if payload.confirm == true and type(payload.card_id) == "string" then
            local defender = state.players[player_id]
            for i, card in ipairs(defender.hand) do
                if card.id == payload.card_id and card.type == action.required_response then
                    -- 御风封锁
                    if state.suleiman_yu_feng
                        and state.suleiman_yu_feng.target_id == player_id
                        and state.suleiman_yu_feng.blocked_type == action.required_response then
                        dispatcher.broadcast_message(11, nk.json_encode({
                            content = string.format("%s 被【御风】封锁，无法使用【%s】！",
                                defender.username, action.required_response),
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
            M.apply_damage(dispatcher, state, player_id, 1, action.attacker_id, "normal")
            if state.pending_action and state.pending_action.type == "WAITING_FOR_RESCUE" then
                return
            end
        end
        if #action.remaining_targets > 0 then
            action.current_target = table.remove(action.remaining_targets, 1)
            action.deadline       = os.time() + 15
            M.notify_aoe_target(dispatcher, state)
        else
            state.pending_action = nil
            M.broadcast_update(dispatcher, state)
        end

    -- ==================== 决斗响应 ====================
    elseif action.type == "WAITING_FOR_DUEL" then
        local current_player = action.is_attackers_turn and action.attacker_id or action.target_id
        if player_id ~= current_player then return end

        if payload.confirm == true and type(payload.card_id) == "string" then
            local p = state.players[player_id]
            local card_idx = nil
            for i, c in ipairs(p.hand) do
                if c.id == payload.card_id and c.type == "ATTACK" then
                    card_idx = i; break
                end
            end
            if card_idx then
                -- 出杀回应决斗
                local played = table.remove(p.hand, card_idx)
                table.insert(state.discard_pile, played)
                dispatcher.broadcast_message(11, nk.json_encode({
                    content = p.username .. " 打出【" .. played.name .. "】回应决斗"
                }))

                -- 切换攻防方
                action.is_attackers_turn = not action.is_attackers_turn
                action.deadline = os.time() + 15

                local next_id = action.is_attackers_turn and action.attacker_id or action.target_id
                dispatcher.broadcast_message(105, nk.json_encode({
                    event = "duel_require_attack",
                    target_id = next_id,
                    msg = "决斗！请出【杀】或放弃",
                }))
                return
            end
        end

        -- 无法出杀：受到1点伤害
        state.pending_action = nil
        local victim = state.players[player_id]
        dispatcher.broadcast_message(11, nk.json_encode({
            content = victim.username .. " 决斗失败，受到 1 点伤害"
        }))
        local duel_source = action.is_attackers_turn and action.target_id or action.attacker_id
        M.apply_damage(dispatcher, state, player_id, 1, duel_source, "normal")
        M.broadcast_update(dispatcher, state)

    -- ==================== 濒死求救 ====================
    elseif action.type == "WAITING_FOR_RESCUE" then
        local dying_id    = action.dying_player_id
        local rescuer_id  = action.rescuers[action.current_rescuer_idx]
        if player_id ~= rescuer_id then return end

        local rescued = false
        if payload.confirm == true and type(payload.card_id) == "string" then
            local rescuer = state.players[player_id]
            local is_self = (player_id == dying_id)
            for i, card in ipairs(rescuer.hand) do
                -- 自救可用桃/酒；救他人只能用桃
                local can_rescue = (is_self and card.type == "WINE")
                    or card.type == "HEAL"
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
                state.pending_action = nil
                state.pending_turn_continuation = { uid = state.current_turn_id }
                M.broadcast_update(dispatcher, state)
                return
            end
            state.pending_action = p
            if p then
                if p.type == "WAITING_FOR_AOE" then
                    -- rescue 完成后推进到下一个目标
                    p.deadline = os.time() + 15
                    if #p.remaining_targets > 0 then
                        p.current_target = table.remove(p.remaining_targets, 1)
                        M.notify_aoe_target(dispatcher, state)
                    else
                        state.pending_action = nil
                        M.broadcast_update(dispatcher, state)
                    end
                elseif #p.remaining_targets > 0 then
                    p.current_target = table.remove(p.remaining_targets, 1)
                    p.deadline       = os.time() + 15
                    M.notify_aoe_target(dispatcher, state)
                else
                    state.pending_action = nil
                    M.broadcast_update(dispatcher, state)
                end
            else
                M.broadcast_update(dispatcher, state)
                -- 攻击伤害导致的濒死救援结束（非 AOE），通知 hook（双角王额外目标）
                local hero_mgr = require("hero_manager")
                hero_mgr.trigger("on_attack_resolved", dispatcher, state, action.attacker_id)
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
                execute_death(dispatcher, state, dying_id, action.attacker_id)
                resume_aoe_or_end(parent)
            end
        end

    -- ==================== 锦囊选择（过河拆桥/顺手牵羊） ====================
    elseif action.type == "WAITING_FOR_TRICK_SELECT" then
        if player_id ~= action.source_id then return end
        local target = state.players[action.target_id]
        if not target then state.pending_action = nil; M.broadcast_update(dispatcher, state); return end

        local function pick_card(remove_fn)
            local found = false
            if payload.confirm == true and type(payload.card_id) == "string" then
                for i, c in ipairs(target.hand) do
                    if c.id == payload.card_id then
                        remove_fn(table.remove(target.hand, i))
                        found = true
                        break
                    end
                end
                if not found then
                    for slot, c in pairs(target.equipment) do
                        if type(c) == "table" and c.id == payload.card_id then
                            target.equipment[slot] = nil
                            remove_fn(c)
                            found = true
                            break
                        end
                    end
                end
            end
            if not found and #target.hand > 0 then
                remove_fn(table.remove(target.hand, math.random(#target.hand)))
            end
        end

        if action.subtype == "discard_one" then
            pick_card(function(c) table.insert(state.discard_pile, c) end)
        elseif action.subtype == "steal_one" then
            pick_card(function(c) table.insert(state.players[action.source_id].hand, c) end)
        elseif action.subtype == "borrow_weapon" then
            -- 借刀杀人：使用者选择攻击目标
            local chosen = payload.target_id
            if payload.confirm == true and chosen and type(chosen) == "string" then
                -- 验证选择是否合法
                for _, vt in ipairs(action.valid_targets) do
                    if vt.id == chosen then
                        state.pending_action = {
                            type = "WAITING_FOR_BORROW_WEAPON",
                            caster_id = action.source_id,
                            target_id = action.target_id,
                            attack_target = chosen,
                            deadline = os.time() + 15,
                        }
                        local target_p = state.players[action.target_id]
                        if target_p and state.presences[action.target_id] then
                            dispatcher.broadcast_message(106, nk.json_encode({
                                event = "borrow_weapon_choice",
                                msg = "出【杀】攻击或交出武器？",
                                attack_target = chosen,
                            }), {state.presences[action.target_id]})
                        end
                        M.broadcast_update(dispatcher, state)
                        return
                    end
                end
            end
            -- 未选择：自动失败
            state.pending_action = nil
            M.broadcast_update(dispatcher, state)
            return
        end

        local source_p = state.players[action.source_id]
        local names_map = { discard_one = "过河拆桥", steal_one = "顺手牵羊" }
        local action_name = names_map[action.subtype] or "锦囊"
        dispatcher.broadcast_message(11, nk.json_encode({
            content = (source_p and source_p.username or "?") .. " 使用【" .. action_name .. "】"
        }))

        state.pending_action = nil
        M.broadcast_update(dispatcher, state)
        -- 锦囊效果已执行（过河拆桥/顺手牵羊），通知 hook（双角王【远疆-东行】额外目标）
        if action.subtype ~= "borrow_weapon" then
            local hero_mgr = require("hero_manager")
            hero_mgr.trigger("on_trick_resolved", dispatcher, state, action.source_id, action.subtype)
        end

    -- ==================== 无懈可击窗口 ====================
    elseif action.type == "WAITING_FOR_COUNTER" then
        if action.remaining_order[action.current_idx] ~= player_id then return end

        if payload.confirm == true and type(payload.card_id) == "string" then
            local p = state.players[player_id]
            for i, c in ipairs(p.hand) do
                if c.id == payload.card_id and c.type == "INSTANT_TRICK" and c.subtype == "counterspell" then
                    table.remove(p.hand, i)
                    table.insert(state.discard_pile, c)
                    action.counter_depth = action.counter_depth + 1
                    dispatcher.broadcast_message(11, nk.json_encode({
                        content = p.username .. " 使用了【无懈可击】！"
                    }))
                    break
                end
            end
        end

        -- 推进到下一位（跳过已死亡玩家，每人浪费 15s）
        repeat
            action.current_idx = action.current_idx + 1
        until action.current_idx > #action.remaining_order
            or (state.players[action.remaining_order[action.current_idx]]
                and state.players[action.remaining_order[action.current_idx]].health > 0)
        if action.current_idx <= #action.remaining_order then
            action.current_target = action.remaining_order[action.current_idx]
            action.deadline = os.time() + 15
            M.notify_counter_target(dispatcher, state)
        else
            -- 窗口结束或无存活目标
            state.pending_action = nil
            if action.counter_depth % 2 == 1 then
                -- 奇数 → 被无懈可击抵消
                local pt = state.pending_trick
                state.pending_trick = nil
                table.insert(state.discard_pile, pt.card)
                dispatcher.broadcast_message(11, nk.json_encode({
                    content = "【" .. pt.card.name .. "】被无懈可击抵消！"
                }))
            else
                -- 偶数 → 锦囊生效
                M.resolve_pending_trick(dispatcher, state)
            end
            M.broadcast_update(dispatcher, state)
        end

    -- ==================== 借刀杀人：出杀或交武器 ====================
    elseif action.type == "WAITING_FOR_BORROW_WEAPON" then
        if player_id ~= action.target_id then return end
        local target_p = state.players[action.target_id]
        if not target_p then state.pending_action = nil; M.broadcast_update(dispatcher, state); return end

        if payload.confirm == true and type(payload.card_id) == "string" then
            -- 试图出杀
            for i, c in ipairs(target_p.hand) do
                if c.id == payload.card_id and c.type == "ATTACK" then
                    -- 先检查距离
                    if M.can_attack(state, action.target_id, action.attack_target) then
                        table.remove(target_p.hand, i)
                        table.insert(state.discard_pile, c)
                        state.pending_action = nil
                        dispatcher.broadcast_message(11, nk.json_encode({
                            content = target_p.username .. " 对 " .. state.players[action.attack_target].username
                                .. " 使出借刀杀人之【杀】！"
                        }))
                        CARD_EFFECTS["ATTACK"](dispatcher, state, action.target_id, action.attack_target, c)
                        M.broadcast_update(dispatcher, state)
                        return
                    end
                    break
                end
            end
        end

        -- 无法/不愿出杀 → 交出武器
        state.pending_action = nil
        if target_p.equipment.weapon then
            local weapon = target_p.equipment.weapon
            target_p.equipment.weapon = nil
            table.insert(state.players[action.caster_id].hand, weapon)
            dispatcher.broadcast_message(11, nk.json_encode({
                content = target_p.username .. " 将【" .. weapon.name .. "】交给了 "
                    .. state.players[action.caster_id].username
            }))
        end
        M.broadcast_update(dispatcher, state)

    -- ==================== 火攻猜花色 ====================
    elseif action.type == "WAITING_FOR_FIRE_GUESS" then
        if player_id ~= action.caster_id then return end

        state.pending_action = nil
        local target = state.players[action.target_id]
        local revealed_card = action.revealed_card
        local guessed = type(payload.guess) == "string" and payload.guess
        if guessed and guessed == revealed_card.suit then
            dispatcher.broadcast_message(11, nk.json_encode({
                content = state.players[action.caster_id].username
                    .. " 猜中了花色（" .. revealed_card.suit .. "），"
                    .. target.username .. " 受到 1 点火焰伤害！"
            }))
            M.apply_damage(dispatcher, state, action.target_id, 1, action.caster_id, "fire")
        else
            dispatcher.broadcast_message(11, nk.json_encode({
                content = state.players[action.caster_id].username
                    .. (guessed and (" 猜错了（猜了" .. guessed .. "，实际是" .. revealed_card.suit .. "）")
                        or " 放弃猜测花色")
            }))
        end
        M.broadcast_update(dispatcher, state)
    end
end

-- 防御成功后续逻辑
function M.handle_defense_success(dispatcher, state, attacker_id, defender_id)
    log_info(state, "防御成功，正在检查攻击者是否有追击技能...")
    local hero_mgr = require("hero_manager")
    local suspended = hero_mgr.trigger("on_attack_defended", dispatcher, state, defender_id, attacker_id)
    if not suspended then
        dispatcher.broadcast_message(11, nk.json_encode({content = "防御成功！"}))
        M.broadcast_update(dispatcher, state)
        -- 攻击链完全结束，通知 hook（双角王【远疆-西行】额外目标）
        hero_mgr.trigger("on_attack_resolved", dispatcher, state, attacker_id)
    end
end

function M.apply_damage(dispatcher, state, target_id, amount, source_id, dmg_type)
    dmg_type = dmg_type or "normal"
    local target = state.players[target_id]
    if not target or target.health <= 0 then return end

    -- 计算攻击加成（来源方装备+酒牌），固定伤害场景跳过
    local source = source_id and state.players[source_id]
    if source and not state._fixed_damage then
        -- 酒牌buff：仅对普通攻击生效，AOE/锦囊不触发
        local is_special = state.pending_action and (
            state.pending_action.type == "WAITING_FOR_AOE"
            or state.pending_action.type == "WAITING_FOR_DUEL"
        )
        if source.weapon_buff and not is_special then
            amount = amount + (state.config and state.config.combat.wine_damage_bonus or 1)
            source.weapon_buff = nil
        end
    end

    -- 藤甲：火焰伤害+1，普通伤害-1
    if target.equipment.armor and target.equipment.armor.subtype == "fire_weakness" then
        if dmg_type == "fire" then
            amount = amount + 1
            dispatcher.broadcast_message(11, nk.json_encode({
                content = target.username .. " 的【藤甲】被火焰灼烧，伤害+1！"
            }))
        else
            amount = math.max(0, amount - 1)
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

    dispatcher.broadcast_message(20, nk.json_encode({
        event = "damage", target = target_id, source = source_id, amount = amount, dmg_type = dmg_type
    }))

    -- 铁索连环：属性伤害传导（传导前先解除所有连环，防无限递归）
    if amount > 0 and dmg_type ~= "normal" and target.iron_chained then
        local chained = {}
        for uid, p in pairs(state.players) do
            if uid ~= target_id and p.health > 0 and p.iron_chained then
                table.insert(chained, uid)
                p.iron_chained = nil
            end
        end
        if #chained > 0 then
            target.iron_chained = nil
            for _, uid in ipairs(chained) do
                dispatcher.broadcast_message(11, nk.json_encode({
                    content = "【铁索连环】传导，" .. state.players[uid].username .. " 受到等量伤害！"
                }))
                M.apply_damage(dispatcher, state, uid, amount, source_id, dmg_type)
            end
        end
    end

    if target.health <= 0 then
        -- 进入濒死求救流程
        local rescuers = { target_id }
        local start_idx
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
            execute_death(dispatcher, state, target_id, source_id)
            state.pending_action = parent
        end
    end
end

-- ==========================================
-- 7. 状态广播（身份迷雾版）
-- ==========================================
function M.broadcast_update(dispatcher, state)
    for uid, presence in pairs(state.presences) do
        local p_data = state.players[uid]
        local payload = {
            current_turn = state.current_turn_id,
            pending = state.pending_action and {
                type = state.pending_action.type,
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
                seat_idx        = p_data.seat_idx,
            },
            others = {}
        }
        for other_id, other_p in pairs(state.players) do
            if other_id ~= uid then
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
                    seat_idx   = other_p.seat_idx,
                })
            end
        end
        dispatcher.broadcast_message(10, nk.json_encode(payload), {presence})

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

-- ==========================================
-- 8. 判定系统
-- ==========================================

-- 抽取判定牌（从牌堆顶取一张）
function M.execute_judgment(state)
    if #state.deck == 0 then
        if #state.discard_pile == 0 then
            return {id="dummy_judge", type="DEFENSE", suit="HEART", number=1, name="虚判"}
        end
        state.deck = M.shuffle(state.discard_pile)
        state.discard_pile = {}
    end
    local judge_card = table.remove(state.deck, 1)
    table.insert(state.discard_pile, judge_card)
    return judge_card
end

-- 处理延时锦囊判定
-- 返回值: true=已由本函数处理完毕 / false=效果未生效需要外部继续处理
function M.process_delayed_judgment(dispatcher, state, player, eff)
    if eff.subtype == "skip_play" then
        -- 乐不思蜀：判定牌非HEART则跳过出牌阶段
        local judge_card = M.execute_judgment(state)
        local skip = judge_card.suit ~= "HEART"
        dispatcher.broadcast_message(11, nk.json_encode({
            content = player.username .. " 的【乐不思蜀】判定："
                .. (judge_card.suit or "?") .. (judge_card.number or "?")
                .. "（" .. (skip and "跳过出牌阶段" or "判定成功，不出局") .. "）"
        }))
        if skip then
            player.skip_play_phase = true
        end
        return true

    elseif eff.subtype == "skip_draw" then
        -- 兵粮寸断：判定牌非CLUB则跳过摸牌阶段
        local judge_card = M.execute_judgment(state)
        local skip = judge_card.suit ~= "CLUB"
        dispatcher.broadcast_message(11, nk.json_encode({
            content = player.username .. " 的【兵粮寸断】判定："
                .. (judge_card.suit or "?") .. (judge_card.number or "?")
                .. "（" .. (skip and "跳过摸牌阶段" or "判定成功，正常摸牌") .. "）"
        }))
        if skip then
            player.skip_draw_phase = true
        end
        return true

    elseif eff.subtype == "lightning" then
        -- 闪电：判定黑桃2-9则受3点雷电伤害，否则传给下家
        local judge_card = M.execute_judgment(state)
        local hit = (judge_card.suit == "SPADE" and judge_card.number >= 2 and judge_card.number <= 9)
        dispatcher.broadcast_message(11, nk.json_encode({
            content = player.username .. " 的【闪电】判定："
                .. (judge_card.suit or "?") .. (judge_card.number or "?")
                .. "（" .. (hit and "闪电命中！" or "未命中，传给下家") .. "）"
        }))
        if hit then
            state._in_judgment_phase = true
            local dmg = state.config and state.config.combat.lightning_damage or 3
            M.apply_damage(dispatcher, state, player.id, dmg, nil, "lightning")
            state._in_judgment_phase = false
            return true
        else
            -- 传给下家
            local next_uid = M.get_next_player_id(state)
            if next_uid == player.id then
                -- 绕一圈回到自己：闪电消失
                dispatcher.broadcast_message(11, nk.json_encode({
                    content = "【闪电】绕了一圈无人中，自行消散"
                }))
                return true
            end
            local next_p = state.players[next_uid]
            if next_p then
                table.insert(next_p.delayed_effects, {
                    id = eff.id,
                    name = eff.name,
                    subtype = eff.subtype,
                    suit = eff.suit,
                    number = eff.number,
                    from = eff.from,
                })
            end
            return true
        end
    end

    -- 未知 subtype，返回 false 让调用者处理
    return false
end

-- ==========================================
-- 8. 无懈可击/锦囊解析系统
-- ==========================================

-- 执行被保存的 pending_trick（无懈可击窗口通过后）
function M.resolve_pending_trick(dispatcher, state)
    local pt = state.pending_trick
    if not pt then return end
    state.pending_trick = nil

    -- 弃牌后再执行效果
    local is_equipment = pt.card.type == "WEAPON" or pt.card.type == "ARMOR" or pt.card.type == "HORSE"
    if not is_equipment then
        table.insert(state.discard_pile, pt.card)
    end

    if CARD_EFFECTS[pt.card.type] then
        CARD_EFFECTS[pt.card.type](dispatcher, state, pt.source_id, pt.target_id, pt.card)
    end
end

-- 通知当前玩家回复是否使用无懈可击
function M.notify_counter_target(dispatcher, state)
    local action = state.pending_action
    if not action or action.type ~= "WAITING_FOR_COUNTER" then return end
    local target_id = action.current_target
    if not target_id then return end

    local presence = state.presences[target_id]
    if not presence then return end
    dispatcher.broadcast_message(105, nk.json_encode({
        type = "counter_opportunity",
        target = target_id,
        msg = "是否使用【无懈可击】抵消锦囊？"
    }), {presence})
end

return M

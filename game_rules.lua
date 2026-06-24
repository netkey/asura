local nk = require("nakama")
local local_mgr = require("localization_manager")
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
            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("card_continuation_nullify", {
                username = state.players[target_id].username
            })))
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

        -- 双刃剑：无视防具
        local has_ignore_armor = p and p.equipment.weapon and p.equipment.weapon.subtype == "ignore_armor"

        -- 仁王盾：黑色攻击被封锁
        if not has_ignore_armor and target.equipment.armor and target.equipment.armor.subtype == "block_black_attack" then
            if card.suit == "SPADE" or card.suit == "CLUB" then
                dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("card_benevolence_shield_block", {
                    username = target.username
                })))
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

        local dmg_type = "normal"

        -- 八卦阵：先判定
        if target.equipment.armor and target.equipment.armor.subtype == "dodge_judgment" then
            local judge_card = M.execute_judgment(state)
            local is_red = judge_card.suit == "HEART" or judge_card.suit == "DIAMOND"
            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("card_eight_trigrams_judgment", {
                username = target.username,
                suit = judge_card.suit or "?",
                number = judge_card.number or "?",
                color = is_red and "red" or "black",
            })))
            if is_red then
                -- 红色=自动闪避
                dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("card_eight_trigrams_success", {
                    username = target.username,
                })))
                return
            end
            -- 黑色=八卦阵无效，继续走防御
            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("card_eight_trigrams_failed", {
                username = target.username,
            })))
        end

        -- 防御性检查：目标玩家在此过程中死亡（on_before_attack 等钩子可能已导致目标死亡）
        if target.health <= 0 then return end

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
        local m = local_mgr.bc("prompt_under_attack")
        m.attacker = source_id
        m.target = target_id
        m.damage = dmg
        dispatcher.broadcast_message(105, nk.json_encode(m))
    end,

    -- 桃 — 恢复 1 点生命值
    ["HEAL"] = function(dispatcher, state, source_id, _, card)
        local p = state.players[source_id]
        if p.health < p.max_health then
            p.health = p.health + 1
            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_use_heal", {
                username = p.username,
                card_id = card and card.id or "heal",
            })))
        end
    end,

    -- 酒 — 标记 weapon_buff，下次攻击伤害+1
    ["WINE"] = function(dispatcher, state, source_id, _, card)
        local p = state.players[source_id]
        -- weapon_buff 由 handle_play_card 统一维护
        local bc_msg = local_mgr.bc("game_use_wine", {
            username = p.username,
            card_id = card.id,
        })
        bc_msg.card = card
        dispatcher.broadcast_message(11, nk.json_encode(bc_msg))
    end,

    -- 武器 — 装备到武器槽，替换旧武器
    ["WEAPON"] = function(dispatcher, state, source_id, _, card)
        local p = state.players[source_id]
        local old = p.equipment.weapon
        if old then
            table.insert(state.discard_pile, old)
        end
        p.equipment.weapon = card
        local bc_msg = local_mgr.bc("game_equip_card", {
            username = p.username,
            card_id = card.id,
        })
        bc_msg.card = card
        dispatcher.broadcast_message(11, nk.json_encode(bc_msg))
    end,

    -- 防具 — 装备到防具槽，替换旧防具
    ["ARMOR"] = function(dispatcher, state, source_id, _, card)
        local p = state.players[source_id]
        local old = p.equipment.armor
        if old then
            table.insert(state.discard_pile, old)
        end
        p.equipment.armor = card
        local bc_msg = local_mgr.bc("game_equip_card", {
            username = p.username,
            card_id = card.id,
        })
        bc_msg.card = card
        dispatcher.broadcast_message(11, nk.json_encode(bc_msg))
    end,

    -- 马牌 — 装备到马槽，替换旧马
    ["HORSE"] = function(dispatcher, state, source_id, _, card)
        local p = state.players[source_id]
        local old = p.equipment.horse
        if old then
            table.insert(state.discard_pile, old)
        end
        p.equipment.horse = card
        local bc_msg = local_mgr.bc("game_equip_card", {
            username = p.username,
            card_id = card.id,
        })
        bc_msg.card = card
        dispatcher.broadcast_message(11, nk.json_encode(bc_msg))
    end,

    -- 即时锦囊
    ["INSTANT_TRICK"] = function(dispatcher, state, source_id, target_id, card)
        local p = state.players[source_id]

        if card.subtype == "draw_two" then
            -- 无中生有
            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_use_draw_two", {
                username = p.username,
                card_type = card.type,
            })))
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
            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_aoe_attack", {
                username = p.username,
            })))
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
            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_aoe_defense", {
                username = p.username,
            })))
            M.notify_aoe_target(dispatcher, state)

        elseif card.subtype == "duel" then
            -- 决斗
            local target = state.players[target_id]
            if not target then return end

            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_duel_start", {
                username = p.username,
                target = target.username,
            })))

            -- 检查目标是否有杀
            local has_attack = false
            for _, c in ipairs(target.hand) do
                if c.type == "ATTACK" then has_attack = true; break end
            end
            if not has_attack then
                -- 无杀立即受伤害
                dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_duel_no_attack", {
                    target = target.username,
                })))
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
            local m = local_mgr.bc("prompt_duel_require_attack")
            m.event = "duel_require_attack"
            m.target_id = target_id
            dispatcher.broadcast_message(105, nk.json_encode(m))

        elseif card.subtype == "discard_one" then
            -- 过河拆桥
            local target = state.players[target_id]
            if not target then return end
            if #target.hand == 0 and not target.equipment.weapon
                and not target.equipment.armor and not target.equipment.horse then
                return  -- 无可弃牌
            end

            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_use_dismantle", {
                username = p.username,
                target = target.username,
            })))

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

            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_use_pilfer", {
                username = p.username,
                target = target.username,
            })))

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
            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_use_mass_heal", {
                username = p.username,
            })))
            for _, p2 in pairs(state.players) do
                if p2.health > 0 and p2.health < p2.max_health then
                    p2.health = p2.health + 1
                end
            end
            M.broadcast_update(dispatcher, state)

        elseif card.subtype == "mass_draw" then
            -- 五谷丰登：按座次各摸1张
            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_use_bounty", {
                username = p.username,
            })))
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
                dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_borrow_blade_no_weapon")))
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
                dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_borrow_blade_no_target")))
                return
            end

            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_use_borrow_blade", {
                username = p.username,
                target = target.username,
            })))

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
                dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_fire_attack_no_hand")))
                return
            end

            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_use_fire_attack", {
                username = p.username,
                target = target.username,
            })))

            -- 随机选一张展示（或让目标选择——当前简化版随机）
            local show_idx = math.random(#target.hand)
            local revealed = target.hand[show_idx]
            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_fire_attack_reveal", {
                target = target.username,
                card_id = revealed.id,
                suit = revealed.suit,
            })))

            state.pending_action = {
                type = "WAITING_FOR_FIRE_GUESS",
                caster_id = source_id,
                target_id = target_id,
                revealed_card = revealed,
                deadline = os.time() + 15,
            }
            if state.presences[source_id] then
                local m = local_mgr.bc("prompt_fire_guess")
                m.event = "fire_guess"
                m.target_hand = revealed.suit
                dispatcher.broadcast_message(106, nk.json_encode(m), {state.presences[source_id]})
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
        local bc_msg = local_mgr.bc("game_receive_delayed", {
            target = target.username,
            card_id = card.id,
        })
        bc_msg.card = card
        dispatcher.broadcast_message(11, nk.json_encode(bc_msg))
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

    local required_name = action.required_response == "ATTACK" and "[Attack]" or "[Defense]"
    local m = local_mgr.bc("prompt_aoe", { required_name = required_name })
    m.attacker = action.attacker_id
    m.target   = target_id
    m.required = action.required_response
    dispatcher.broadcast_message(105, nk.json_encode(m))
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
        reattempt_discard2= 2,
        reattempt_attack  = 2,
        spear_discard2    = 2,
        ignore_armor      = 2,
        bow_strip_horse   = 3,
    }
    local range = ranges[p.equipment.weapon.subtype]
    if not range then
        nk.logger_warn(string.format("weapon_range: unknown subtype=%s, defaulting to range 1", p.equipment.weapon.subtype))
        return 1
    end
    return range
end

-- 丈八蛇矛：将2张手牌当【杀】使用
function M._handle_spear_skill(dispatcher, state, player_id, payload)
    local player = state.players[player_id]
    if not player or player.health <= 0 then return false end
    if not player.equipment.weapon or player.equipment.weapon.subtype ~= "spear_discard2" then
        return false
    end
    if type(payload.card_ids) ~= "table" or #payload.card_ids ~= 2 then
        return false
    end
    if type(payload.target_id) ~= "string" then return false end
    local target = state.players[payload.target_id]
    if not target or target.health <= 0 then return false end
    if not M.can_attack(state, player_id, payload.target_id) then
        dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_out_of_range", {
            username = player.username,
        })))
        return false
    end

    -- 从手牌中移除2张指定牌
    local card_ids = payload.card_ids
    local seen = {}
    local removed = 0
    for _, cid in ipairs(card_ids) do
        if seen[cid] then return false end
        seen[cid] = true
        for i, c in ipairs(player.hand) do
            if c.id == cid then
                table.insert(state.discard_pile, table.remove(player.hand, i))
                removed = removed + 1
                break
            end
        end
    end
    if removed < 2 then return false end

    -- 攻击次数限制（连弩机无视）
    local has_unlimited = player.equipment.weapon and player.equipment.weapon.subtype == "unlimited_attack"
    if (player.attacks_this_turn or 0) >= 1 and not has_unlimited then
        return false
    end
    player.attacks_this_turn = (player.attacks_this_turn or 0) + 1

    dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_spear_skill", {
        username = player.username,
    })))

    -- 构造一张虚拟的杀牌
    local virtual_card = { id = "spear_attack", type = "ATTACK", suit = "SPADE", number = 1, name = "Spear Attack" }
    CARD_EFFECTS["ATTACK"](dispatcher, state, player_id, payload.target_id, virtual_card)
    M.broadcast_update(dispatcher, state)
    return true
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
        dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("reward_kill_rebel", {
            username = killer.username,
            count = reward,
        })))
    elseif victim.role == "MINISTER" and killer.role == "MONARCH" then
        killer.hand = {}
        dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("reward_monarch_kill_loyalist")))
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

    -- 丈八蛇矛：可将2张手牌当【杀】使用
    if payload.weapon_skill == "spear_discard2" then
        return M._handle_spear_skill(dispatcher, state, player_id, payload)
    end

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
            if pa.caster_id == player_id then
                blocked = true
            else
                -- 在询问列表中且尚未 pass 的玩家被阻塞（防止出其他牌）
                for _, uid in ipairs(pa.remaining_order) do
                    if uid == player_id and not pa.responded[uid] then
                        blocked = true
                        break
                    end
                end
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

    -- 苏莱曼【敕令】：检查封锁
    if state.suleiman_chi_ling and state.suleiman_chi_ling.target_id == player_id
        and card.type == state.suleiman_chi_ling.blocked_type then
        local bc_msg = local_mgr.bc("blocked_decree", {
            username = player.username,
            card_id = card.id,
        })
        bc_msg.hero = "suleiman"
        bc_msg.skill = "chi_ling"
        dispatcher.broadcast_message(11, nk.json_encode(bc_msg))
        return false
    end

    -- 酒每回合限1次（增伤用）
    if card.type == "WINE" and player.wine_used_this_turn then
        dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("blocked_wine_already_used", {
            username = player.username,
        })))
        return false
    end

    -- 攻击次数限制（连弩机无视）
    if card.type == "ATTACK" then
        local has_unlimited = player.equipment.weapon
            and player.equipment.weapon.subtype == "unlimited_attack"
        if (player.attacks_this_turn or 0) >= 1 and not has_unlimited then
            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("blocked_attack_already_used", {
                username = player.username,
            })))
            return false
        end
    end

    -- 距离检查（杀/顺手牵羊）
    if card.type == "ATTACK" and target_id then
        if not M.can_attack(state, player_id, target_id) then
            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_out_of_range_attack", {
                username = player.username,
                target = state.players[target_id].username,
            })))
            return false
        end
    end

    -- 顺手牵羊也需要距离检查（默认距离1）
    if card.type == "INSTANT_TRICK" and card.subtype == "steal_one" and target_id then
        local dist = M.seat_distance(state, player_id, target_id)
        if dist > 1 then
            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_out_of_range_pilfer", {
                username = player.username,
                target = state.players[target_id].username,
            })))
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
                responded = {},
                counter_depth = 0,
                round = 0,
                deadline = os.time() + 15,
            }
            M.notify_counter_all(dispatcher, state)
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
-- 检查 counter 链中所有存活玩家是否均已 pass
local function counter_all_responded(action)
    for _, uid in ipairs(action.remaining_order) do
        if not action.responded[uid] then return false end
    end
    return true
end

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
    hero_mgr.trigger("on_death", dispatcher, state, target_id)
    log_info(state, target.username .. " defeated, role: " .. target.role)
    local ROLE_TAG = { MONARCH="Monarch", MINISTER="Loyalist", REBEL="Rebel", TRAITOR="Traitor" }
    local role_tag = ROLE_TAG[target.role]
    local bc_msg = local_mgr.bc("death_announce", {
        username = target.username,
        role = role_tag or target.role,
    })
    bc_msg.event = "player_death"
    bc_msg.player_id = target_id
    bc_msg.role = target.role
    dispatcher.broadcast_message(11, nk.json_encode(bc_msg))
    M.handle_role_reward(dispatcher, state, source_id, target_id)

    -- 清理 pending_action 中对死亡玩家的引用（防止死锁）
    if state.pending_action then
        local pa = state.pending_action
        -- 类型 1：死者是当前响应者 → 自动确认失败，推进链
        if (pa.type == "WAITING_FOR_DEFENSE" and pa.target_id == target_id)
            or (pa.type == "WAITING_FOR_AOE" and pa.current_target == target_id)
            or (pa.type == "WAITING_FOR_DUEL"
                and (pa.attacker_id == target_id or pa.target_id == target_id))
            or (pa.type == "WAITING_FOR_BORROW_WEAPON" and pa.target_id == target_id)
            or (pa.type == "WAITING_FOR_TRICK_SELECT" and pa.source_id == target_id)
            or (pa.type == "WAITING_FOR_FIRE_GUESS" and pa.caster_id == target_id)
            or (pa.type == "WEAPON_QINGLONG_DAO" and pa.attacker_id == target_id)
            or (pa.type == "WEAPON_CHUANGSHI_FU" and pa.attacker_id == target_id) then
            M.handle_response(dispatcher, state, target_id, {confirm = false})
        -- 类型 2：死者是链中的一员 → 从链中移除
        elseif pa.type == "WAITING_FOR_RESCUE" and pa.rescuers then
            local new_rescuers = {}
            for _, uid in ipairs(pa.rescuers) do
                if uid ~= target_id then table.insert(new_rescuers, uid) end
            end
            pa.rescuers = new_rescuers
            if #new_rescuers == 0 then
                state.pending_action = nil
                M.broadcast_update(dispatcher, state)
            end
        -- 类型 3：死者在 COUNTER 链中 → 自动 pass（如尚未响应）并从链中移除
        elseif pa.type == "WAITING_FOR_COUNTER" and pa.remaining_order then
            -- 如果死者尚未 pass，先代为 pass（可能触发链结束）
            if not pa.responded[target_id] then
                M.handle_response(dispatcher, state, target_id, {confirm = false})
            end
            -- 从链中移除死者（handle_response 可能已将链结束，需重判）
            if state.pending_action == pa then
                local removed = false
                local new_order = {}
                for i, uid in ipairs(pa.remaining_order) do
                    if uid == target_id then
                        removed = true
                    else
                        table.insert(new_order, uid)
                    end
                end
                if removed then
                    pa.remaining_order = new_order
                    pa.responded[target_id] = nil
                    if #new_order == 0 then
                        -- 链中已无存活玩家，结束窗口
                        state.pending_action = nil
                        local pt = state.pending_trick
                        state.pending_trick = nil
                        if pt and pt.card then
                            table.insert(state.discard_pile, pt.card)
                        end
                        M.broadcast_update(dispatcher, state)
                    end
                end
            end
        -- 类型 4：死者是 pending_action 发起者（hero-specific 技能如 HAKIM_XING_XIANG/SCHEHERAZADE_QIANYE 等）
        -- 类型 1-3 已覆盖所有「链式推进」场景，此处处理发起者死亡后无人可响应的残留
        elseif pa.player_id == target_id then
            state.pending_action = nil
            local pt = state.pending_trick
            state.pending_trick = nil
            if pt and pt.card then
                table.insert(state.discard_pile, pt.card)
            end
            M.broadcast_update(dispatcher, state)
        end
    end
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
                if card_idx then
                    table.insert(state.discard_pile, table.remove(defender.hand, card_idx))
                    state.pending_action = nil
                    dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("card_jafar_poison_block", {
                        username = defender.username,
                    })))
                    M.handle_defense_success(dispatcher, state, action.attacker_id, player_id, action.damage)
                else
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
            if not card_idx then
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
                local m = local_mgr.bc("prompt_jafar_poison_plot")
                m.attacker = action.attacker_id
                m.target = action.target_id
                m.damage = action.damage
                dispatcher.broadcast_message(105, nk.json_encode(m))
                return
            end

            -- 正常防御成功
            state.pending_action = nil
            M.handle_defense_success(dispatcher, state, action.attacker_id, player_id, action.damage)
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
                dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_duel_play_attack", {
                    username = p.username,
                    card_id = played.id,
                })))

                -- 切换攻防方
                action.is_attackers_turn = not action.is_attackers_turn
                action.deadline = os.time() + 15

                local next_id = action.is_attackers_turn and action.attacker_id or action.target_id
                local m = local_mgr.bc("prompt_duel_forfeit")
                m.event = "duel_require_attack"
                m.target_id = next_id
                dispatcher.broadcast_message(105, nk.json_encode(m))
                return
            end
        end

        -- 无法出杀：受到1点伤害
        state.pending_action = nil
        local victim = state.players[player_id]
        dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_duel_lost", {
            username = victim.username,
        })))
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
            for i, card in ipairs(rescuer.hand) do
                -- 仅【桃】可以救人（酒只增伤不可救人）
                local hero_mgr = require("hero_manager")
                local can_rescue = card.type == "HEAL"
                    or hero_mgr.can_rescue_with(rescuer.hero, card)
                if card.id == payload.card_id and can_rescue then
                    table.remove(rescuer.hand, i)
                    table.insert(state.discard_pile, card)
                    state.players[dying_id].health = 1
                    rescued = true
                    local bc_msg = local_mgr.bc("rescue_success", {
                        username = rescuer.username,
                        target = state.players[dying_id].username,
                    })
                    bc_msg.event = "rescue_success"
                    bc_msg.rescuer_id = player_id
                    bc_msg.dying_player_id = dying_id
                    dispatcher.broadcast_message(11, nk.json_encode(bc_msg))
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
                local bc_msg = local_mgr.bc("rescue_next", {
                    target = state.players[dying_id].username,
                    rescuer = state.players[next_id].username,
                })
                bc_msg.event = "rescue_needed"
                bc_msg.dying_player_id = dying_id
                bc_msg.rescuer_id = next_id
                dispatcher.broadcast_message(11, nk.json_encode(bc_msg))
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
                            local m = local_mgr.bc("prompt_borrow_weapon_choice")
                            m.event = "borrow_weapon_choice"
                            m.attack_target = chosen
                            dispatcher.broadcast_message(106, nk.json_encode(m), {state.presences[action.target_id]})
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
        local target_p_name = state.players[action.target_id] and state.players[action.target_id].username or "?"
        local trick_key = action.subtype == "discard_one" and "game_use_dismantle" or "game_use_pilfer"
        dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc(trick_key, {
            username = source_p and source_p.username or "?",
            target = target_p_name,
        })))

        state.pending_action = nil
        M.broadcast_update(dispatcher, state)
        -- 锦囊效果已执行（过河拆桥/顺手牵羊），通知 hook（双角王【远疆-东行】额外目标）
        if action.subtype ~= "borrow_weapon" then
            local hero_mgr = require("hero_manager")
            hero_mgr.trigger("on_trick_resolved", dispatcher, state, action.source_id, action.subtype)
        end

    -- ==================== 无懈可击窗口（并行模式）====================
    elseif action.type == "WAITING_FOR_COUNTER" then
        -- 守卫：玩家必须在询问列表中且本轮尚未 pass
        local in_chain = false
        for _, uid in ipairs(action.remaining_order) do
            if uid == player_id then in_chain = true; break end
        end
        if not in_chain then return end
        if action.responded[player_id] then return end
        -- 拒绝上一轮的 stale 响应（未收到新一轮通知就发出的 pass/counterspell）
        if type(payload.round) == "number" and payload.round ~= action.round then return end

        if payload.confirm == true and type(payload.card_id) == "string" then
            local p = state.players[player_id]
            local card_found = false
            for i, c in ipairs(p.hand) do
                if c.id == payload.card_id and c.type == "INSTANT_TRICK" and c.subtype == "counterspell" then
                    table.remove(p.hand, i)
                    table.insert(state.discard_pile, c)
                    action.counter_depth = action.counter_depth + 1
                    dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_use_counterspell", {
                        username = p.username,
                    })))
                    card_found = true
                    break
                end
            end
            if card_found then
                -- 进入新轮次：清空已 pass 列表，重置共享 deadline，重通知所有人
                action.round = action.round + 1
                action.responded = {}
                action.deadline = os.time() + 15
                M.notify_counter_all(dispatcher, state)
                M.broadcast_update(dispatcher, state)
                return
            end
            -- card_id 无效：静默忽略，不推进链（等待玩家重新响应或超时）
        end

        action.responded[player_id] = true

        if counter_all_responded(action) then
            -- 窗口结束
            state.pending_action = nil
            if action.counter_depth % 2 == 1 then
                -- 奇数 → 被无懈可击抵消
                local pt = state.pending_trick
                state.pending_trick = nil
                table.insert(state.discard_pile, pt.card)
                dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_card_countered", {
                    card_id = pt.card.id,
                })))
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
                        dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("card_borrow_weapon_attack", {
                            username = target_p.username,
                            target = state.players[action.attack_target].username,
                        })))
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
            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("card_give_weapon", {
                username = target_p.username,
                card_id = local_mgr.card_lookup_key(weapon.name),
                caster = state.players[action.caster_id].username,
            })))
        end
        M.broadcast_update(dispatcher, state)

    -- ==================== 火攻猜花色 ====================
    elseif action.type == "WAITING_FOR_FIRE_GUESS" then
        if player_id ~= action.caster_id then return end

        state.pending_action = nil
        local target = state.players[action.target_id]
        local revealed_card = action.revealed_card
        local guessed = type(payload.guess) == "string" and payload.guess
        local caster_username = state.players[action.caster_id].username
        if guessed and guessed == revealed_card.suit then
            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_fire_guess_right", {
                username = caster_username,
                suit = revealed_card.suit,
                target = target.username,
            })))
            M.apply_damage(dispatcher, state, action.target_id, 1, action.caster_id, "fire")
        elseif guessed then
            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_fire_guess_wrong", {
                username = caster_username,
                guess = guessed,
                actual = revealed_card.suit,
            })))
        else
            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_fire_guess_gave_up", {
                username = caster_username,
            })))
        end
        M.broadcast_update(dispatcher, state)

    -- ==================== 贯石斧：弃2张牌强制命中 ====================
    elseif action.type == "WEAPON_CHUANGSHI_FU" then
        if player_id ~= action.player_id then return end
        state.pending_action = nil

        if payload.confirm ~= true then
            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_defense_success")))
            M.broadcast_update(dispatcher, state)
            local hero_mgr = require("hero_manager")
            hero_mgr.trigger("on_attack_resolved", dispatcher, state, action.attacker_id)
            return
        end

        local attacker = state.players[action.attacker_id]
        if not attacker or attacker.health <= 0 then
            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_defense_success")))
            M.broadcast_update(dispatcher, state)
            return
        end

        -- 弃2张牌
        local discarded = 0
        for i = #attacker.hand, 1, -1 do
            if discarded >= 2 then break end
            table.insert(state.discard_pile, table.remove(attacker.hand, i))
            discarded = discarded + 1
        end
        if discarded < 2 then
            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_defense_success")))
            M.broadcast_update(dispatcher, state)
            return
        end

        dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("card_splitting_axe", {
            username = attacker.username,
            target = state.players[action.target_id].username,
        })))
        M.apply_damage(dispatcher, state, action.target_id, action.damage or 1, action.attacker_id, "normal")
        if not (state.pending_action and state.pending_action.type == "WAITING_FOR_RESCUE") then
            M.broadcast_update(dispatcher, state)
            local hero_mgr = require("hero_manager")
            hero_mgr.trigger("on_attack_resolved", dispatcher, state, action.attacker_id)
        end

    -- ==================== 青龙偃月刀：追击同一目标 ====================
    elseif action.type == "WEAPON_QINGLONG_DAO" then
        if player_id ~= action.player_id then return end
        state.pending_action = nil

        if payload.confirm ~= true or type(payload.card_id) ~= "string" then
            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_defense_success")))
            M.broadcast_update(dispatcher, state)
            local hero_mgr = require("hero_manager")
            hero_mgr.trigger("on_attack_resolved", dispatcher, state, action.attacker_id)
            return
        end

        local attacker = state.players[action.attacker_id]
        if not attacker or attacker.health <= 0 then
            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_defense_success")))
            M.broadcast_update(dispatcher, state)
            return
        end

        -- 找一张杀追击
        local attack_card
        for i, c in ipairs(attacker.hand) do
            if c.id == payload.card_id and c.type == "ATTACK" then
                attack_card = table.remove(attacker.hand, i)
                break
            end
        end
        if not attack_card then
            M.broadcast_update(dispatcher, state)
            return
        end

        table.insert(state.discard_pile, attack_card)
        dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("card_green_dragon_blade", {
            username = attacker.username,
            target = state.players[action.target_id].username,
        })))
        -- 重新触发攻击效果（会自动设置 WAITING_FOR_DEFENSE）
        CARD_EFFECTS["ATTACK"](dispatcher, state, action.attacker_id, action.target_id, attack_card)
        M.broadcast_update(dispatcher, state)
    end
end

-- 防御成功后续逻辑
function M.handle_defense_success(dispatcher, state, attacker_id, defender_id, damage)
    log_info(state, "Defense successful, checking attacker pursuit skills...")
    local hero_mgr = require("hero_manager")
    local suspended = hero_mgr.trigger("on_attack_defended", dispatcher, state, defender_id, attacker_id)
    if suspended then return end

    local attacker = state.players[attacker_id]

    -- 贯石斧：杀被闪后可弃2张牌强制命中
    if attacker and attacker.health > 0 and attacker.equipment.weapon
        and attacker.equipment.weapon.subtype == "reattempt_discard2"
        and #attacker.hand >= 2 then
        state.pending_action = {
            type        = "WEAPON_CHUANGSHI_FU",
            player_id   = attacker_id,
            attacker_id = attacker_id,
            target_id   = defender_id,
            damage      = damage or 1,
            deadline    = os.time() + 15,
        }
        local m = local_mgr.bc("prompt_weapon_force_hit")
        m.type = "weapon_skill"
        m.skill = "chuangshi_fu"
        dispatcher.broadcast_message(101, nk.json_encode(m), {state.presences[attacker_id]})
        return
    end

    -- 青龙偃月刀：杀被闪后可立即追击
    if attacker and attacker.health > 0 and attacker.equipment.weapon
        and attacker.equipment.weapon.subtype == "reattempt_attack" then
        local can_pursue = false
        for _, c in ipairs(attacker.hand) do
            if c.type == "ATTACK" then can_pursue = true; break end
        end
        if can_pursue then
            state.pending_action = {
                type        = "WEAPON_QINGLONG_DAO",
                player_id   = attacker_id,
                attacker_id = attacker_id,
                target_id   = defender_id,
                deadline    = os.time() + 15,
            }
            local m = local_mgr.bc("prompt_weapon_pursue")
            m.type = "weapon_skill"
            m.skill = "qinglong_dao"
            dispatcher.broadcast_message(101, nk.json_encode(m), {state.presences[attacker_id]})
            return
        end
    end

    dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("game_defense_success")))
    M.broadcast_update(dispatcher, state)
    hero_mgr.trigger("on_attack_resolved", dispatcher, state, attacker_id)
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

    -- 麒麟弓：杀中后可弃目标马牌
    if amount > 0 and source_id and source and source.equipment.weapon
        and source.equipment.weapon.subtype == "bow_strip_horse"
        and target.equipment.horse then
        local horse = target.equipment.horse
        target.equipment.horse = nil
        table.insert(state.discard_pile, horse)
        dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("card_qilin_bow", {
            username = source.username,
            target = target.username,
            card_id = local_mgr.card_lookup_key(horse.name),
        })))
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
            local bc_msg = local_mgr.bc("rescue_dying", {
                username = target.username,
            })
            bc_msg.event = "rescue_needed"
            bc_msg.dying_player_id = target_id
            bc_msg.rescuer_id = rescuers[1]
            dispatcher.broadcast_message(11, nk.json_encode(bc_msg))
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
                hand              = p_data.hand,
                hp                = p_data.health,
                max_health        = p_data.max_health,
                hero              = p_data.hero,
                role              = p_data.role,
                equipment         = p_data.equipment,
                delayed_effects   = p_data.delayed_effects,
                weapon_buff       = p_data.weapon_buff,
                skin_id           = p_data.skin_id,
                seat_idx          = p_data.seat_idx,
                attacks_this_turn = p_data.attacks_this_turn or 0,
                wine_used_this_turn = p_data.wine_used_this_turn or false,
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
                    max_health = other_p.max_health,
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
            return {id="dummy_judge", type="DEFENSE", suit="HEART", number=1, name="Dummy Judge"}
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
        dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("turn_skip_play_judgment", {
            username = player.username,
            suit = judge_card.suit or "?",
            number = judge_card.number or "?",
            result = skip and "skip play phase" or "judgment passed, normal",
        })))
        if skip then
            player.skip_play_phase = true
        end
        return true

    elseif eff.subtype == "skip_draw" then
        -- 兵粮寸断：判定牌非CLUB则跳过摸牌阶段
        local judge_card = M.execute_judgment(state)
        local skip = judge_card.suit ~= "CLUB"
        dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("turn_skip_draw_judgment", {
            username = player.username,
            suit = judge_card.suit or "?",
            number = judge_card.number or "?",
            result = skip and "skip draw phase" or "judgment passed, normal draw",
        })))
        if skip then
            player.skip_draw_phase = true
        end
        return true

    elseif eff.subtype == "lightning" then
        -- 闪电：判定黑桃2-9则受3点雷电伤害，否则传给下家
        local judge_card = M.execute_judgment(state)
        local hit = (judge_card.suit == "SPADE" and judge_card.number >= 2 and judge_card.number <= 9)
        dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("turn_lightning_judgment", {
            username = player.username,
            suit = judge_card.suit or "?",
            number = judge_card.number or "?",
            result = hit and "HIT!" or "missed, passes to next",
        })))
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
                dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("turn_lightning_dissipate")))
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

-- 通知所有待响应玩家：是否使用无懈可击（并行广播）
function M.notify_counter_all(dispatcher, state)
    local action = state.pending_action
    if not action or action.type ~= "WAITING_FOR_COUNTER" then return end

    for _, uid in ipairs(action.remaining_order) do
        if not action.responded[uid] then
            local presence = state.presences[uid]
            if presence then
                local m = local_mgr.bc("prompt_counterspell_counter")
                m.type = "counter_opportunity"
                m.target = uid
                m.round = action.round
                dispatcher.broadcast_message(105, nk.json_encode(m), {presence})
            end
        end
    end
end

return M

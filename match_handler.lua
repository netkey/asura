local nk        = require("nakama")
local hero_mgr  = require("hero_manager")
local catalog   = require("hero_catalog")
local rules     = require("game_rules")
local config    = require("game_config")
local local_mgr = require("localization_manager")
local season_mgr = require("season_manager")
local skin_catalog  = require("skin_catalog")
local local_mgr = require("localization_manager")

local M = {}

-- 辅助：调用阶段钩子，若返回 true（技能创建了 pending_action），
-- 设置 continuation + broadcast 后返回 true，由 match_loop 下轮恢复
local function trigger_phase_hook(dispatcher, state, uid, hook_name, continuation_key)
    local suspended = hero_mgr.trigger(hook_name, dispatcher, state, uid)
    if suspended then
        if continuation_key then
            state[continuation_key] = {uid = uid}
        end
        rules.broadcast_update(dispatcher, state)
        return true
    end
    return false
end

-- 游戏状态定义
local STATE = { WAITING = 0, PLAYING = 1, ENDED = 2 }

-- 结构化日志：附加 match_id/模块上下文
local function log_info(state, msg)
    nk.logger_info(string.format("[match=%s] %s", state.match_id or "?", msg))
end
local function log_warn(state, msg)
    nk.logger_warn(string.format("[match=%s] %s", state.match_id or "?", msg))
end

-- 简易计数器：写 ops/matches 存储（Nakama Lua 无自定义 Prometheus 接口）
local function metric_inc(name)
    local ok, obj = pcall(nk.storage_read, {{
        collection = "ops", key = "matches", user_id = nil
    }})
    local val = ok and #obj > 0 and obj[1].value or {}
    val[name] = (val[name] or 0) + 1
    local ver = ok and #obj > 0 and obj[1].version or "*"
    pcall(nk.storage_write, {{
        collection = "ops", key = "matches", user_id = nil,
        value = val, version = ver,
        permission_read = 1, permission_write = 0,
    }})
    nk.logger_info(string.format("[METRIC] %s=%d", name, val[name]))
end

-- ==========================================
-- 用户在线状态维护（供好友系统查询）
-- status: "waiting"=等待中  "playing"=游戏中
-- ==========================================
local function write_user_status(uid, match_id, status, mode, current_players, max_players)
    local data = {
        match_id        = match_id,
        status          = status,
        mode            = mode,
        current_players = current_players,
        max_players     = max_players,
        updated_at      = os.time(),
    }
    -- 持久化到 storage（供 get_friends_status RPC 兜底拉取）
    pcall(nk.storage_write, {{
        collection       = "user_status",
        key              = "current_match",
        user_id          = uid,
        value            = data,
        permission_read  = 1,
        permission_write = 0,
    }})
    -- 实时推送给已订阅该用户状态的好友（WebSocket StatusPresenceEvent）
    pcall(nk.status_update, uid, nk.json_encode(data))
end

local function clear_user_status(uid)
    nk.storage_delete({{
        collection = "user_status",
        key        = "current_match",
        user_id    = uid,
    }})
    -- 清空实时状态，好友端收到空状态即视为 idle
    pcall(nk.status_update, uid, nil)
end

-- 清除所有玩家在线状态（在多个地方复用：排空超时、等待超时、胜负判定、关闭对局）
local function clear_all_player_status(state)
    for uid, _ in pairs(state.players) do
        clear_user_status(uid)
    end
end

-- ==========================================
-- 内部工具：分配身份
-- pvp 模式无身份，identity 模式按人数分配
-- ==========================================
local function assign_roles(player_count, mode)
    if mode == "pvp" then return {} end
    if player_count == 5 then
        return rules.shuffle({"MONARCH", "MINISTER", "REBEL", "REBEL", "TRAITOR"})
    else
        -- 非法人数优雅回退到 pvp
        nk.logger_warn(string.format("identity 模式仅支持 5 人局，收到 %d 人，回退到 pvp", player_count))
        return {}
    end
end

-- ==========================================
-- 初始化
-- ==========================================
function M.match_init(context, params)
    local max_players = params.max_players or 2
    if type(max_players) ~= "number" or max_players < 1 or max_players > 10 then
        error("max_players must be 1-10")
    end
    -- 2人局默认 pvp（公平对战），5人局默认 identity（身份局）
    local mode = params.mode or (max_players == 2 and "pvp" or "identity")
    local state = {
        status = STATE.WAITING,
        waiting_since = os.time(),  -- 等待超时自动清理
        max_players = max_players,
		mode = mode,				-- 记录模式，方便后续更新 label
        players = {},      			-- 存储玩家详细战斗数据
        presences = {},				-- 存储在线状态引用
        presence_ids = {}, 			-- 记录加入顺序，方便分配身份

		--战斗数据
        deck = rules.create_deck(),
        discard_pile = {},
        current_turn_id = nil,
        pending_action = nil,		-- 用于挂起等待技能响应

        -- 观战
        spectators         = {},    -- user_id → presence
        pending_spectators = {},    -- 跨 join_attempt→join 传递旁观者标记
        pending_heroes     = {},    -- 跨 join_attempt→join 传递客户端英雄选择
        pending_skins     = {},    -- 跨 join_attempt→join 传递客户端皮肤选择

		-- 高并发与托管系统配置
        current_turn_elapsed = 0,   -- 当前玩家已思考的时间
        consecutive_autoplay = 0,   -- 连续托管次数（用于加速全托管对局）
    }
    -- 加载服务端配置（首局对局初始化时读取，整局复用）
    local cfg = config.load(nk)
    state.config       = cfg
    state.turn_timeout = cfg.match.turn_timeout
	local label = {
        mode = mode,
        open = 1, -- 1表示开放，0表示关闭
        max = max_players,
        group_id = params.group_id or "",
    }
    return state, 1, nk.json_encode(label)
    --local label = nk.json_encode({ mode = params.mode, max = max_players })
    --return state, state.tick_rate, label
end

function M.match_join(context, dispatcher, tick, state, presences)
    state.match_id = context.match_id  -- 结构化日志用
    for _, p in ipairs(presences) do
        -- 旁观者分流：pending_spectators 由 match_join_attempt 标记
        if state.pending_spectators[p.user_id] then
            local spec_info = state.pending_spectators[p.user_id]
            state.pending_spectators[p.user_id] = nil
            -- 旁观目标：优先使用请求中的 target_player_id，否则默认第一个玩家
            local target_id = spec_info.target_player_id
            if not target_id or not state.players[target_id] then
                target_id = state.presence_ids[1]
            end
            state.spectators[p.user_id] = { presence = p, target_player_id = target_id }
            M.send_spectator_state(dispatcher, state, p, target_id)
            log_info(state, "旁观者 " .. p.username .. " 加入观战，跟随 " .. tostring(target_id))

        else
        -- 1. 更新 Presence 引用，确保后续消息能发给他
        state.presences[p.user_id] = p

        -- 2. 如果是重连玩家（已经在 players 列表里）
        if state.status == STATE.PLAYING then
            -- 立即单独发一份全量数据给他，同步当前战场
            M.send_full_state_to_player(dispatcher, state, p)
            log_info(state, "已为重连玩家 " .. p.username .. " 同步战场状态")
        else
            -- 正常加入逻辑（第一次进入房间）
            table.insert(state.presence_ids, p.user_id)

            -- 读取英雄库存 + 已购皮肤
            local unlocked_heroes = { aladdin = true }
            local owned_skins     = {}
            local inv_objects = nk.storage_read({
                { collection = "hero_inventory", key = "unlocked_heroes", user_id = p.user_id },
                { collection = "skin_inventory", key = "owned_skins",     user_id = p.user_id },
            })
            for _, obj in ipairs(inv_objects) do
                if obj.key == "unlocked_heroes" then unlocked_heroes = obj.value end
                if obj.key == "owned_skins"     then owned_skins     = obj.value end
            end
            -- owned_skins 是数组，转为 set 方便 O(1) 查询
            local owned_skin_set = {}
            for _, sid in ipairs(owned_skins) do owned_skin_set[sid] = true end

            -- 读取全局限时免费活动（user_id=nil，独立调用）
            local free_events = {}
            local fe_objects = nk.storage_read({
                { collection = "events", key = "free_heroes", user_id = nil },
            })
            if #fe_objects > 0 then free_events = fe_objects[1].value or {} end

            -- 从 join 时的 metadata 读取英雄选择，未携带则默认阿拉丁
            local requested = state.pending_heroes[p.user_id]
            state.pending_heroes[p.user_id] = nil
            local want_hero = "aladdin"
            if type(requested) == "string" and catalog.HEROES[requested] then
                if unlocked_heroes[requested] then
                    want_hero = requested
                else
                    -- 限时免费活动期间无需购买也可使用
                    local ev = free_events[requested]
                    if ev then
                        local now = os.time()
                        if now >= ev.start_time and now <= ev.end_time then
                            want_hero = requested
                        end
                    end
                end
                if want_hero ~= requested then
                    log_warn(state, "玩家 " .. p.username .. " 请求英雄 " .. tostring(requested) .. " 不可用，重置为阿拉丁")
                end
            end

            -- 从 join 时的 metadata 读取皮肤选择，校验归属和拥有权
            local want_skin_id = state.pending_skins[p.user_id]
            state.pending_skins[p.user_id] = nil
            local skin_id = nil  -- nil = 默认皮肤
            if type(want_skin_id) == "string" and skin_catalog.exists(want_skin_id) then
                local skin_info = skin_catalog.SKINS[want_skin_id]
                -- 皮肤必须属于当前选择的英雄
                if skin_info.hero_id == want_hero then
                    -- 默认皮肤无需拥有权检查，付费皮肤需已购买
                    if skin_info.is_default or owned_skin_set[want_skin_id] then
                        skin_id = want_skin_id
                    else
                        log_warn(state, "玩家 " .. p.username .. " 未拥有皮肤 " .. want_skin_id .. "，回退默认皮肤")
                    end
                else
                    log_warn(state, "皮肤 " .. want_skin_id .. " 不属于英雄 " .. want_hero .. "，回退默认皮肤")
                end
            end

            local ph = state.config.match.player_health
            state.players[p.user_id] = {
                id = p.user_id,
                username = p.username,
                health = ph,
                max_health = ph,
                seat_idx = #state.presence_ids - 1,  -- 座位号（0-indexed），整局不变
                hand = {},
                hero = want_hero,
                skin_id = skin_id,                   -- 选择的皮肤（nil=默认）
                role = "NONE",        -- pvp 模式为 "NONE"，identity 模式后续覆写
                judgments = {},
                equipment = {
                    weapon = nil,
                    armor = nil,
                    horse = nil
                },
                weapon_buff = false,
                delayed_effects = {},
                attacks_this_turn = 0,
                damage_dealt = 0,
                damage_received = 0,
            }
            -- 写入等待中状态，好友列表可查
            write_user_status(p.user_id, context.match_id, "waiting",
                state.mode, #state.presence_ids, state.max_players)
			log_info(state, "Player " .. p.username .. " joined, Location: " .. #state.presence_ids)
        end
        end -- spectator else 分支结束
    end

    -- 检查是否达到设定的最大人数
    local current_count = #state.presence_ids
    if state.status == STATE.WAITING and current_count >= state.max_players then
        state.status = STATE.PLAYING
        metric_inc("matches_started")


		-- 【核心修改：更新房间标签】
        -- 将 open 设为 0，这样 match_list 的查询语句 +label.open:1 就搜不到这个房间了
        local new_label = {
            mode        = state.mode,
            open        = 0,
            max         = state.max_players,
            spectatable = 1,  -- 对局开始后允许旁观者加入
            status      = "playing",
            players     = #state.presence_ids,
            started_at  = os.time(),
        }
        dispatcher.match_label_update(nk.json_encode(new_label))

		-- 随机分配英雄（从 hero_catalog 动态取，避免双维护）
		local hero_list = {}
        for id in pairs(catalog.HEROES) do
            table.insert(hero_list, id)
        end
        for _, p in pairs(state.players) do
            -- 保留玩家在 join 时自选的英雄；未选择或选择无效则随机分配
            if not p.hero or not catalog.HEROES[p.hero] then
                p.hero = hero_list[math.random(#hero_list)]
                p.skin_id = nil  -- 英雄被重分配，重置为默认皮肤
            end
            -- 自选英雄不变时，skin_id 已在 match_join 中校验完毕，无需改动
        end
        -- 身份分配（pvp 模式跳过，identity 模式按角色分配）
        local roles = assign_roles(current_count, state.mode)
        for i, uid in ipairs(state.presence_ids) do
            local p = state.players[uid]
            if roles[i] then
                p.role = roles[i]
                if p.role == "MONARCH" then
                    local mh = state.config.match.monarch_health
                    p.health = mh
                    p.max_health = mh
                    state.current_turn_id = uid
                end
            end
        end
        -- pvp 模式无主公，第一个加入的玩家先手
        if state.mode == "pvp" and not state.current_turn_id then
            state.current_turn_id = state.presence_ids[1]
        end

        -- 所有玩家状态升级为 playing，好友可进入观战
        for _, uid in ipairs(state.presence_ids) do
            write_user_status(uid, context.match_id, "playing",
                state.mode, current_count, state.max_players)
        end

        rules.start_game(dispatcher, state)
        M.do_judgment_and_draw_phase(dispatcher, state)
        rules.broadcast_update(dispatcher, state)
        log_info(state, "对局正式启动！总人数：" .. current_count)
    end
    return state
end

-- 托管防御决策：致命伤才出防御牌，否则放弃
local function auto_defend(dispatcher, state, defender_id, incoming_damage, required_type)
    local defender = state.players[defender_id]
    if not defender or defender.health <= 0 then
        -- 目标已死亡，使用 confirm=false 推进 pending（防止 WAITING_FOR_DEFENSE/AOE 卡死）
        rules.handle_response(dispatcher, state, defender_id, { confirm = false })
        return
    end

    if incoming_damage >= defender.health then
        -- 找一张所需类型的牌（required_type 必须传，不设后备默认值）
        for _, card in ipairs(defender.hand) do
            if card.type == required_type then
                rules.handle_response(dispatcher, state, defender_id, { confirm = true, card_id = card.id })
                return
            end
        end
    end
    -- 非致命 or 无所需牌：放弃
    rules.handle_response(dispatcher, state, defender_id, { confirm = false })
end

-- 离线/超时自动弃牌：从手牌末尾移除
local function auto_discard_from_end(dispatcher, state, uid, discard_count)
    local ep = state.players[uid]
    local discarded = {}
    for _ = 1, discard_count do
        local card = table.remove(ep.hand)
        if not card then break end  -- 手牌已空（防御性保护）
        table.insert(state.discard_pile, card)
        table.insert(discarded, card.name or card.type)
    end
    dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("match_discard_phase", {
        username = ep.username,
        count = tostring(#discarded),
        card_list = table.concat(discarded, ", "),
    })))
end

-- 托管 AI 辅助：解决当前 pending_action（一层），为不支持复杂交互的托管提供默认选择
local function auto_resolve_pending(dispatcher, state)
    local act = state.pending_action
    if not act then return end

    if act.type == "WAITING_FOR_DEFENSE" then
        auto_defend(dispatcher, state, act.target_id, act.damage or 1, "DEFENSE")
    elseif act.type == "WAITING_FOR_AOE" then
        auto_defend(dispatcher, state, act.current_target, 1, act.required_response)
    elseif act.type == "WAITING_FOR_RESCUE" then
        local rescuer_id = act.rescuers and act.rescuers[act.current_rescuer_idx]
        local rescuer = rescuer_id and state.players[rescuer_id]
        if rescuer then
            local dying_id = act.dying_player_id
            local is_self = (rescuer_id == dying_id)
            local found
            for _, c in ipairs(rescuer.hand) do
                if c.type == "HEAL" or (is_self and c.type == "WINE")
                    or hero_mgr.can_rescue_with(rescuer.hero, c) then
                    rules.handle_response(dispatcher, state, rescuer_id, { confirm = true, card_id = c.id })
                    found = true
                    break
                end
            end
            if not found then
                rules.handle_response(dispatcher, state, rescuer_id, { confirm = false })
            end
        elseif rescuer_id then  -- 救援者已死亡，跳过并继续链中的下一个救援者
            rules.handle_response(dispatcher, state, rescuer_id, { confirm = false })
        end
    elseif act.type == "WAITING_FOR_TRICK_SELECT" then
        rules.handle_response(dispatcher, state, act.source_id, { confirm = false })
    elseif act.type == "WAITING_FOR_DUEL" then
        local duel_id = act.is_attackers_turn and act.attacker_id or act.target_id
        rules.handle_response(dispatcher, state, duel_id, { confirm = false })
    elseif act.type == "WAITING_FOR_COUNTER" then
        -- 并行模式：超时后所有未 pass 玩家自动 pass
        -- handle_response 内部会检查 in_chain + responded，重复调用无害
        for _, uid in ipairs(act.remaining_order) do
            if not act.responded[uid] then
                rules.handle_response(dispatcher, state, uid, { confirm = false })
            end
            if not state.pending_action then break end
        end
    elseif act.type == "WAITING_FOR_BORROW_WEAPON" then
        rules.handle_response(dispatcher, state, act.target_id, { confirm = false })
    elseif act.type == "WAITING_FOR_FIRE_GUESS" then
        local guess = act.revealed_card and act.revealed_card.suit or "HEART"
        rules.handle_response(dispatcher, state, act.caster_id, { confirm = true, guess = guess })
    elseif act.type == "WEAPON_CHUANGSHI_FU" or act.type == "WEAPON_QINGLONG_DAO" then
        -- 武器技能超时：放弃使用
        rules.handle_response(dispatcher, state, act.player_id, { confirm = false })
    elseif act.type == "WAITING_FOR_DISCARD" then
        -- 超时自动弃牌：从末尾弃
        auto_discard_from_end(dispatcher, state, act.player_id, act.discard_count)
        state.pending_action = nil
        state.pending_discard_continuation = {uid = act.player_id}
    else
        -- 英雄技能超时：如果相关玩家（响应者或目标）已死亡，直接清除 pending
        local dead_related = false
        local check_ids = { act.player_id, act.target_id }
        for _, pid in ipairs(check_ids) do
            if pid and state.players[pid] and state.players[pid].health <= 0 then
                dead_related = true
                break
            end
        end
        if dead_related then
            state.pending_action = nil
            rules.broadcast_update(dispatcher, state)
            return
        end
        hero_mgr.handle_timeout(dispatcher, state)
    end
end

--自动托管系统出牌逻辑
function M.perform_auto_play(dispatcher, state)
    local uid = state.current_turn_id
    if not uid then return end

    state.consecutive_autoplay = (state.consecutive_autoplay or 0) + 1

    local player = state.players[uid]

    -- 1. 清理挂起的技能选择或弃牌等待（兜底清理）
    if state.pending_action and state.pending_action.player_id == uid then
        if state.pending_action.type == "WAITING_FOR_DISCARD" then
            auto_discard_from_end(dispatcher, state, uid, state.pending_action.discard_count)
            state.pending_action = nil
        else
            -- 技能选择超时（如 HARUN_SELECT_TARGET），
            -- 交由 auto_resolve_pending 按技能规则处理，而非 draw_cards 武断清空
            auto_resolve_pending(dispatcher, state)
        end
    end
    -- perform_auto_play 将自行调用 next_turn 推进回合，清除任何挂起的弃牌续接标记
    state.pending_discard_continuation = nil

    if not player or player.health <= 0 then
        M.next_turn(dispatcher, state)
        return
    end

    -- 辅助：在手牌中找第一张匹配类型的牌
    local function find_card(type)
        for _, c in ipairs(player.hand) do
            if c.type == type then return c end
        end
    end

    -- 辅助：出牌后自动处理技能触发的 pending_action（最多解 5 层防环）
    local function play_and_resolve(args)
        rules.handle_play_card(dispatcher, state, uid, args)
        for _ = 1, 5 do
            if not state.pending_action then break end
            auto_resolve_pending(dispatcher, state)
        end
    end

    -- 2. 装备：先上武器，再上防具
    for _, equip_type in ipairs({"WEAPON", "ARMOR", "HORSE"}) do
        local c = find_card(equip_type)
        if c then
            play_and_resolve({ card_id = c.id })
        end
    end

    -- 3. 治疗：血量不满才吃
    if player.health < player.max_health then
        local c = find_card("HEAL")
        if c then
            play_and_resolve({ card_id = c.id })
        end
    end

    -- 4. AOE：有群伤先放（南蛮入侵或万箭齐发）
    local function find_trick(subtype)
        for _, c in ipairs(player.hand) do
            if c.type == "INSTANT_TRICK" and c.subtype == subtype then return c end
        end
    end
    local aoe_card = find_trick("aoe_attack") or find_trick("aoe_defense")
    if aoe_card then
        play_and_resolve({ card_id = aoe_card.id })
    end

    -- 5. 喝酒：有酒且手里还有杀才喝（避免白喝）
    local has_attack = find_card("ATTACK")
    if has_attack then
        local wine = find_card("WINE")
        if wine then
            play_and_resolve({ card_id = wine.id })
        end
    end

    -- 6. 攻击：优先打血量最少的存活敌方
    local attack_played = false
    local atk = find_card("ATTACK")
    if atk then
        local target_id, min_hp = nil, math.huge
        for other_id, other_p in pairs(state.players) do
            if other_id ~= uid and other_p.health > 0
                and other_p.health < min_hp
                and rules.can_attack(state, uid, other_id) then
                target_id = other_id
                min_hp = other_p.health
            end
        end
        if target_id then
            play_and_resolve({ card_id = atk.id, target_id = target_id })
            attack_played = true
        end
    end

    -- 追踪连续空过回合：成功出杀则归零，空过则递增（供 match_loop 全 stuck 检测用）
    player._no_attack_count = attack_played and 0 or ((player._no_attack_count or 0) + 1)

    log_info(state, "托管结束，切换到下一位玩家")
    M.next_turn(dispatcher, state)
end


function M.match_loop(context, dispatcher, tick, state, messages)
    -- 如果游戏已结束，返回 nil 销毁对局实例，释放服务器内存
    if state.status == STATE.ENDED then return nil end

    -- 服务器关闭排空：grace 到期强制结束
    if state.pending_shutdown and os.time() >= state.pending_shutdown then
        log_info(state, "排空超时，强制结束对局")
        clear_all_player_status(state)
        return nil
    end

    -- 每个 tick 开始时重置 next_turn 递归深度计数器
    state._turn_depth = 0

    -- ==========================================
    -- 0. 等待超时清理（5分钟无满员自动解散）
    -- ==========================================
    if state.status == STATE.WAITING and os.time() - (state.waiting_since or 0) > 300 then
        log_info(state, "房间等待超时，自动解散")
        metric_inc("matches_abandoned")
        clear_all_player_status(state)
        return nil
    end

    -- ==========================================
    -- 1. 托管计时逻辑 (新增)
    -- ==========================================
    -- 只有在对局进行中才计时
    if state.status == STATE.PLAYING then
        -- 检查 pending_action 超时（防止防御/AOE/求救/弃牌等待永久卡死）
        -- 以及 pending 相关玩家已死亡时不等 deadline，立即自动解决
        local auto_resolve = false
        local act = state.pending_action
        if act and act.deadline and os.time() > act.deadline then
            auto_resolve = true
        elseif act then
            -- WAITING_FOR_DEFENSE 或 WAITING_FOR_AOE 目标已死亡 → 立即解决
            local dead_id = (act.type == "WAITING_FOR_DEFENSE" and act.target_id)
                or (act.type == "WAITING_FOR_AOE" and act.current_target)
            if dead_id and state.players[dead_id] and state.players[dead_id].health <= 0 then
                auto_resolve = true
            end
        end
        if auto_resolve then
            auto_resolve_pending(dispatcher, state)
            -- 连续 auto_resolve 检测：5 次无 turn 变化 → 强制 next_turn 防止死锁
            if state.current_turn_id then
                if state._auto_resolve_turn == state.current_turn_id then
                    state._auto_resolve_count = (state._auto_resolve_count or 0) + 1
                    if state._auto_resolve_count >= 5 then
                        log_warn(state, "auto_resolve stuck after 5 attempts on turn " ..
                            state.current_turn_id .. ", force next_turn")
                        state._auto_resolve_count = 0
                        state.pending_action = nil
                        M.next_turn(dispatcher, state)
                    end
                else
                    state._auto_resolve_count = 0
                end
                state._auto_resolve_turn = state.current_turn_id
            end
            return state
        end

        -- 恢复被弃牌阶段挂起的回合切换（弃牌完成后继续）
        if state.pending_discard_continuation and not state.pending_action then
            local dc = state.pending_discard_continuation
            state.pending_discard_continuation = nil
            M.finish_turn_end_continue(dispatcher, state, dc.uid)
            return state
        end

        -- 恢复被吉尔伽美什【不朽】等回合结束技能挂起的回合切换
        if state.pending_turn_end and not state.pending_action then
            local te = state.pending_turn_end
            state.pending_turn_end = nil
            M.resume_after_turn_end(dispatcher, state, te)
            return state
        end

        -- 恢复被哈基姆【星象】挂起的判定+摸牌阶段
        if state.pending_turn_continuation and not state.pending_action then
            state.pending_turn_continuation = nil
            M.do_judgment_and_draw_phase(dispatcher, state)
            return state
        end

        -- 恢复被摸牌阶段英雄技能挂起的出牌阶段
        if state.pending_draw_continuation and not state.pending_action then
            state.pending_draw_continuation = nil
            local uid = state.current_turn_id
            local current_p = state.players[uid]
            if current_p and current_p.health > 0 then
                if current_p.skip_play_phase then
                    current_p.skip_play_phase = nil
                    M.next_turn(dispatcher, state)
                else
                    trigger_phase_hook(dispatcher, state, uid, "on_play_phase_start")
                end
            end
            return state
        end

        -- 当前回合玩家已死，强制跳回合（决斗反杀/反击等场景）
        local current_p = state.players[state.current_turn_id]
        if not current_p or current_p.health <= 0 then
            M.next_turn(dispatcher, state)
            return state
        end

        state.current_turn_elapsed = state.current_turn_elapsed + 1

        -- 计算有效超时：全断线 → 3s，连续托管≥3 → 5s，否则正常30s
        local effective_timeout = state.turn_timeout
        if state.consecutive_autoplay >= 3 then
            effective_timeout = 5
        end
        -- 全断线加速：所有存活玩家均已掉线时降为3s（优先级更高）
        local all_offline = true
        for pid, p in pairs(state.players) do
            if p.health > 0 and state.presences[pid] then
                all_offline = false
                break
            end
        end
        if all_offline then
            effective_timeout = 3
        end

        -- 单玩家空过加速：当前回合玩家连续 ≥2 轮无出杀（NO_REACHABLE_TARGET 或手中无杀），
        -- 则其出牌阶段无需等待，直接由 auto_play 空过并推进回合
        -- 按玩家独立判定而非全局，修复"一人可攻击拖慢全队"场景
        if effective_timeout > 0 and state.current_turn_id then
            current_p = state.players[state.current_turn_id]
            if current_p and (current_p._no_attack_count or 0) >= 2 then
                effective_timeout = 0
            end
        end

        -- 检查是否思考超时（跨玩家 pending_action 如防御/AOE/决斗由 deadline 处理，不在此超时）
        local has_cross_pending = state.pending_action
            and state.pending_action.player_id ~= state.current_turn_id
        if state.current_turn_elapsed >= effective_timeout and not has_cross_pending then
            log_info(state, "玩家 " .. (state.current_turn_id or "未知") .. " 超时，执行托管")
            M.perform_auto_play(dispatcher, state)
            -- 托管后计时器会在 next_turn 中重置，这里直接返回 state 等待下一秒
            return state
        end
    end

    -- ==========================================
    -- 2. 处理客户端消息
    -- ==========================================
    for _, message in ipairs(messages) do
        local ok, payload = pcall(nk.json_decode, message.data)
        if not ok or type(payload) ~= "table" then goto continue end
        local uid = message.sender.user_id
        if not state.players[uid] or (state.status == STATE.PLAYING and state.players[uid].health <= 0) then goto continue end

        -- 当前回合玩家有任何动作，重置计时器和连续托管计数
        -- 非当前回合玩家（如防御响应）不重置，由 pending_action.deadline 独立计时
        if uid == state.current_turn_id then
            state.current_turn_elapsed = 0
            state.consecutive_autoplay = 0
            state.players[uid]._no_attack_count = 0
        end

        -- 情况 A：处理挂起的技能响应（如哈基姆、阿拉丁）或弃牌选择
        if state.pending_action and state.pending_action.player_id == uid then
            if state.pending_action.type == "WAITING_FOR_DISCARD" then
                M.handle_discard_response(dispatcher, state, uid, payload)
            else
                hero_mgr.handle_response(dispatcher, state, uid, payload)
            end
        else
            -- 情况 B：常规回合操作
            if message.op_code == 3 then -- 出牌
                -- 只有当前回合玩家才能出牌
                if uid == state.current_turn_id then
                    rules.handle_play_card(dispatcher, state, uid, payload)
                end
            elseif message.op_code == 4 then -- 手动结束回合
                -- 只有当前回合玩家才能结束回合
                if uid == state.current_turn_id then
                    M.next_turn(dispatcher, state)
                end
            elseif message.op_code == 5 then -- 防御/AOE 响应 {confirm: true/false}
                rules.handle_response(dispatcher, state, uid, payload)
            end
        end
        ::continue::
    end

    -- ==========================================
    -- 3. 检查胜负判定
    -- ==========================================
    local is_over, winner = rules.check_victory(dispatcher, state)
    if is_over then
        state.status = STATE.ENDED
        metric_inc("matches_completed")

        dispatcher.broadcast_message(30, nk.json_encode({winner = winner}))
        season_mgr.record_match(nk, state, winner)
        clear_all_player_status(state)
        return nil
    end

    return state
end


function M.next_turn(dispatcher, state)
    -- 防止递归过深（极端情况：多人连续死亡 / 全员跳过出牌）
    state._turn_depth = (state._turn_depth or 0) + 1
    if state._turn_depth > 20 then
        log_warn(state, "next_turn 递归深度超限，延至下一 tick")
        state._turn_depth = 0
        state.pending_turn_continuation = {uid = state.current_turn_id}
        return
    end

    local ending_uid = state.current_turn_id
    -- 若轮到的死者有挂起的技能 pending_action，清除之——否则下一玩家的 broadcast_update
    -- 会发出死者的 pending_action.type（如 HARUN_CHOOSE 出现在非哈伦玩家）
    if state.pending_action and state.pending_action.player_id == ending_uid then
        local ep = state.players[ending_uid]
        if not ep or ep.health <= 0 then
            state.pending_action = nil
        end
    end
    -- 清除苏莱曼【敕令】：目标回合结束时清除，或目标死亡时清除
    if state.suleiman_chi_ling then
        local target = state.players[state.suleiman_chi_ling.target_id]
        if state.suleiman_chi_ling.target_id == ending_uid
            or not target or target.health <= 0 then
            state.suleiman_chi_ling = nil
        end
    end
    -- 清除杜尼亚扎德【续篇】免疫（仅持续当前回合）
    state.dunyazad_immune = nil
    if ending_uid then
        -- on_turn_end 钩子（弃牌前触发，辛巴达/纳芙蒂蒂等回合结束技能在此触发）
        -- 若返回 true 表示技能创建了 pending_action（如吉尔伽美什【不朽】），挂起等待响应
        if hero_mgr.trigger("on_turn_end", dispatcher, state, ending_uid) then
            state.pending_turn_end = {uid = ending_uid}
            return
        end
    end
    M.finish_turn_end(dispatcher, state, ending_uid)
end

-- 从 on_turn_end 挂起后恢复（由 match_loop 中 pending_turn_end 检测触发）
function M.resume_after_turn_end(dispatcher, state, te)
    M.finish_turn_end(dispatcher, state, te.uid)
end

-- 回合结束收尾：重置攻击计数 → 弃牌阶段 → 切换到下一玩家
function M.finish_turn_end(dispatcher, state, ending_uid)
    local ep_reset = state.players[ending_uid]
    if ep_reset then
        ep_reset.attacks_this_turn = 0
        ep_reset.wine_used_this_turn = false
        ep_reset.weapon_buff = nil -- 酒伤害加成仅限本回合
    end

    -- 1. 弃牌阶段：手牌数超过当前血量时弃至血量（在线等待选择，离线自动弃牌）
    if ending_uid and M.do_discard_phase(dispatcher, state, ending_uid) then
        return -- 挂起等待玩家选牌
    end

    M.finish_turn_end_continue(dispatcher, state, ending_uid)
end

-- 弃牌阶段：返回 true 表示挂起等待，false 表示已完成（无需弃牌或离线已自动弃牌）
function M.do_discard_phase(dispatcher, state, ending_uid)
    local ep = state.players[ending_uid]
    if not ep or ep.health <= 0 or #ep.hand <= ep.health then
        return false -- 无需弃牌
    end

    local discard_count = #ep.hand - ep.health
    -- 在线且非托管模式的玩家等待手动选择；离线或托管模式（consecutive_autoplay>0）自动弃牌
    if state.presences[ending_uid] and (state.consecutive_autoplay or 0) == 0 then
        state.pending_action = {
            type = "WAITING_FOR_DISCARD",
            player_id = ending_uid,
            discard_count = discard_count,
            deadline = os.time() + state.turn_timeout,
        }
        local m = local_mgr.bc("match_discard_required", { username = ep.username, count = discard_count })
        m.event = "discard_required"
        m.player_id = ending_uid
        m.discard_count = discard_count
        dispatcher.broadcast_message(106, nk.json_encode(m), {state.presences[ending_uid]})
        state.pending_discard_continuation = {uid = ending_uid}
        return true
    end

    -- 离线：自动从末尾弃牌
    auto_discard_from_end(dispatcher, state, ending_uid, discard_count)
    return false
end

-- 处理玩家的弃牌选择（在线手动弃牌）
function M.handle_discard_response(dispatcher, state, uid, payload)
    local act = state.pending_action
    if not act or act.type ~= "WAITING_FOR_DISCARD" or act.player_id ~= uid then return end

    local ep = state.players[uid]
    -- 校验 card_ids 合法性
    if not payload.confirm or type(payload.card_ids) ~= "table"
        or #payload.card_ids ~= act.discard_count then
        -- 无效响应，视为放弃选择，自动从末尾弃
        auto_discard_from_end(dispatcher, state, uid, act.discard_count)
    else
        -- 构建手牌 id→card 映射，同时检测重复 id（重复则校验失败）
        local hand_by_id = {}
        for _, c in ipairs(ep.hand) do
            hand_by_id[c.id] = c
        end
        local valid = true
        local seen = {}
        for _, cid in ipairs(payload.card_ids) do
            if not hand_by_id[cid] or seen[cid] then valid = false; break end
            seen[cid] = true
        end
        if not valid then
            auto_discard_from_end(dispatcher, state, uid, act.discard_count)
        else
            -- 从手牌中移除指定牌
            local discarded = {}
            for _, cid in ipairs(payload.card_ids) do
                local card = hand_by_id[cid]
                for j, hc in ipairs(ep.hand) do
                    if hc.id == cid then
                        table.remove(ep.hand, j)
                        table.insert(state.discard_pile, card)
                        table.insert(discarded, card.name or card.type)
                        break
                    end
                end
            end
            dispatcher.broadcast_message(11, nk.json_encode(local_mgr.bc("match_discard_phase", {
                username = ep.username,
                count = tostring(act.discard_count),
                card_list = table.concat(discarded, ", "),
            })))
        end
    end

    state.pending_action = nil
    state.pending_discard_continuation = {uid = uid}
end

-- 弃牌阶段完成后继续：切换下一玩家 → 判定 → 摸牌
function M.finish_turn_end_continue(dispatcher, state, ending_uid)
    state.current_turn_id = rules.get_next_player_id(state)
    state.current_turn_elapsed = 0
    -- 下一玩家在线则重置连续托管计数，否则保留以触发加速
    if state.presences[state.current_turn_id] then
        state.consecutive_autoplay = 0
    end
    local uid = state.current_turn_id
    local current_p = state.players[uid]

    -- ==========================================
    -- 2. 判定阶段 (判定前触发 + 延时锦囊处理)
    -- ==========================================
    -- 判定阶段前触发哈基姆【星象】（在延时锦囊之前，星象可影响判定牌顺序）
    if trigger_phase_hook(dispatcher, state, uid, "on_judgment_phase_start", "pending_turn_continuation") then return end

    -- 再处理延时锦囊（max_iter 防止无限循环）
    local delayed_iter = 0
    while #current_p.delayed_effects > 0 and current_p.health > 0 and delayed_iter < 20 do
        delayed_iter = delayed_iter + 1
        local d_eff = table.remove(current_p.delayed_effects, 1)
        rules.process_delayed_judgment(dispatcher, state, current_p, d_eff)
        -- 闪电可能造成伤害触发濒死
        if current_p.health <= 0 then
            -- 如果闪电已触发 WAITING_FOR_RESCUE，不要覆盖，让主循环处理救援
            if state.pending_action and state.pending_action.type == "WAITING_FOR_RESCUE" then
                return
            end
            return M.next_turn(dispatcher, state)
        end
    end

    M.do_judgment_and_draw_phase(dispatcher, state)
end

-- 判定阶段 + 摸牌阶段（可从 next_turn 直接调用，也可从 pending_turn_continuation 恢复）
function M.do_judgment_and_draw_phase(dispatcher, state)
    local uid       = state.current_turn_id
    local current_p = state.players[uid]
    if not current_p or current_p.health <= 0 then
        -- 检查是否还有存活玩家，全死则不切回合（下个 tick 胜利判定会结束对局）
        local next_id = rules.get_next_player_id(state)
        if next_id ~= uid then
            return M.next_turn(dispatcher, state)
        end
        return
    end

    -- 重置每回合状态标志
    current_p.attack_debuff = nil

    -- 摸牌阶段
    -- 回合计数（供 season_manager 写入 match_history）
    state.turns = (state.turns or 0) + 1

    if trigger_phase_hook(dispatcher, state, uid, "on_draw_phase_start", "pending_draw_continuation") then return end

    -- 兵粮寸断跳过摸牌阶段
    if current_p.skip_draw_phase then
        current_p.skip_draw_phase = nil
        log_info(state, current_p.username .. " 被兵粮寸断，跳过摸牌阶段")
    else
        local draw_count = state.config and state.config.match.draw_cards_per_turn or 2
        rules.draw_cards(state, uid, draw_count)
    end
    rules.broadcast_update(dispatcher, state)
    -- 乐不思蜀跳过出牌阶段
    if current_p.skip_play_phase then
        current_p.skip_play_phase = nil
        log_info(state, current_p.username .. " 跳过出牌阶段")
        M.next_turn(dispatcher, state)
    else
        if trigger_phase_hook(dispatcher, state, uid, "on_play_phase_start") then return end
    end
end


function M.match_leave(context, dispatcher, tick, state, presences)
    for _, p in ipairs(presences) do
        if state.spectators[p.user_id] then
            state.spectators[p.user_id] = nil
            log_info(state, "旁观者 " .. p.username .. " 离开")
        else
            -- 等待中主动离开：清除状态
            if state.status == STATE.WAITING then
                clear_user_status(p.user_id)
                state.pending_heroes[p.user_id] = nil
                state.players[p.user_id] = nil
                state.presences[p.user_id] = nil
                for i, uid in ipairs(state.presence_ids) do
                    if uid == p.user_id then
                        table.remove(state.presence_ids, i)
                        break
                    end
                end
            else
                -- 游戏中掉线：清理 presence 避免向过期引用发广播，保留 players 供重连
                state.presences[p.user_id] = nil
                state.pending_heroes[p.user_id] = nil
            end
            log_info(state, "玩家 " .. p.username .. " 掉线了")
        end
    end

    -- 游戏中且当前回合玩家掉线：触发托管自动切回合
    if state.status == STATE.PLAYING then
        for _, p in ipairs(presences) do
            if state.players[p.user_id] and p.user_id == state.current_turn_id then
                log_info(state, "当前回合玩家 " .. p.username .. " 掉线，立即托管")
                -- 只处理断线玩家自己的 pending（技能选择等），跨玩家 pending（防御/AOE等）留给目标自行响应
                if state.pending_action and state.pending_action.player_id == p.user_id then
                    auto_resolve_pending(dispatcher, state)
                end
                M.perform_auto_play(dispatcher, state)
                -- 不 break：perform_auto_play 可能将回合切到另一个也在断线列表中的玩家
            end
        end
    end

    return state
end

-- 辅助函数：向旁观者同步当前战场（与目标玩家完全相同的视野）
-- 旁观者使用 OpCode 10，payload 格式与普通玩家一致
function M.send_spectator_state(dispatcher, state, presence, target_player_id)
    local target = state.players[target_player_id]
    if not target then return end

    local payload = {
        is_spectator = true,
        current_turn = state.current_turn_id,
        pending      = state.pending_action and {
            type     = state.pending_action.type,
            deadline = state.pending_action.deadline,
        } or nil,
        me = {  -- 旁观者"以目标视角"看自己
            hand            = target.hand,
            hp              = target.health,
            role            = target.role,
            hero            = target.hero,
            seat_idx        = target.seat_idx,
            equipment       = target.equipment,
            delayed_effects = target.delayed_effects,
            weapon_buff     = target.weapon_buff,
            skin_id         = target.skin_id,
        },
        others = {},
    }
    for other_id, other_p in pairs(state.players) do
        if other_id ~= target_player_id then
            -- 与目标玩家视角相同的迷雾规则
            local visible_role = "UNKNOWN"
            if other_p.role == "MONARCH" or other_p.health <= 0 or state.status == STATE.ENDED then
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
end

-- 辅助函数：专门给重连者同步信息
function M.send_full_state_to_player(dispatcher, state, presence)
    local uid    = presence.user_id
    local p_data = state.players[uid]
    local payload = {
        is_reconnect = true,
        current_turn = state.current_turn_id,
        pending      = state.pending_action,
        me = {
            hand            = p_data.hand,
            hp              = p_data.health,
            role            = p_data.role,
            hero            = p_data.hero,
            equipment       = p_data.equipment,
            delayed_effects = p_data.delayed_effects,
            weapon_buff     = p_data.weapon_buff,
            judgments       = p_data.judgments,
            skin_id         = p_data.skin_id,
            seat_idx        = p_data.seat_idx,
        },
        others = {}
    }
    for other_id, other_p in pairs(state.players) do
        if other_id ~= uid then
            local visible_role = "UNKNOWN"
            if other_p.role == "MONARCH" or other_p.health <= 0 or state.status == STATE.ENDED then
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
end


function M.match_join_attempt(context, dispatcher, tick, state, presence, metadata)
    -- 如果游戏已经结束，不允许任何人再进来
    if state.status == STATE.ENDED then
        return state, false, "游戏已结束"
    end

    -- 核心逻辑：如果是已经在游戏里的玩家回来，无条件允许
    if state.players[presence.user_id] then
        log_info(state, "检测到玩家 " .. presence.username .. " 正在重连...")
        return state, true
    end

    -- 旁观者：对局进行中也允许，标记并记录目标玩家
    if metadata and metadata.is_spectator then
        state.pending_spectators[presence.user_id] = {
            target_player_id = metadata.target_player_id
        }
        return state, true
    end

    -- 如果是新玩家想中途加入已开始的游戏，拒绝
    if state.status == STATE.PLAYING then
        return state, false, "对局已开始，无法中途加入"
    end

    -- 记录客户端期望的英雄和皮肤（match_join 消费）
    if metadata and type(metadata.hero_id) == "string" then
        state.pending_heroes[presence.user_id] = metadata.hero_id
    end
    if metadata and type(metadata.skin_id) == "string" then
        state.pending_skins[presence.user_id] = metadata.skin_id
    end

    return state, true
end


function M.match_terminate(context, dispatcher, tick, state, grace_seconds)
    if grace_seconds <= 0 then
        -- grace 到期（或编排器强制终止），立即清理后结束
        clear_all_player_status(state)
        return nil
    end

    if state.pending_shutdown then
        -- 第二次调用（由 match_loop 兜底或编排器二次通知），清理后结束
        clear_all_player_status(state)
        state.pending_shutdown = nil
        return nil
    end

    -- 首次调用：广播关闭通知
    local sd_msg = local_mgr.bc("match_server_shutdown_hard", { seconds = grace_seconds })
    sd_msg.event = "server_shutdown"
    sd_msg.grace_seconds = grace_seconds
    dispatcher.broadcast_message(99, nk.json_encode(sd_msg))
    state.pending_shutdown = os.time() + grace_seconds

    -- 排空期间保持对局运行，match_loop 中 pending_shutdown 检查到期后自动清理，
    -- 而非在此处直接结束——这样 match_loop 的胜负判定等逻辑仍能正常执行到最终状态。
    log_info(state, string.format("服务器关闭通知已发送，排空剩余 %d 秒", grace_seconds))
    return state
end
function M.match_signal(context, dispatcher, tick, state, data)
    local ok, signal = pcall(nk.json_decode, data)
    if ok and type(signal) == "table" and signal.event == "drain" then
        local grace = tonumber(signal.grace) or 120
        if not state.pending_shutdown then
            state.pending_shutdown = os.time() + grace
            local sd_msg = local_mgr.bc("match_server_shutdown_soft", { seconds = grace })
            sd_msg.event = "server_shutdown"
            sd_msg.grace_seconds = grace
            dispatcher.broadcast_message(99, nk.json_encode(sd_msg))
            log_info(state, string.format("收到 drain 信号，排空剩余 %d 秒", grace))
        end
        return state, "draining"
    end
    return state, data
end

return M

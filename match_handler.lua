local nk        = require("nakama")
local hero_mgr  = require("hero_manager")
local rules     = require("game_rules")
local config    = require("game_config")
local season_mgr = require("season_manager")

local M = {}

-- 游戏状态定义
local STATE = { WAITING = 0, PLAYING = 1, ENDED = 2 }

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
    nk.storage_write({{
        collection       = "user_status",
        key              = "current_match",
        user_id          = uid,
        value            = data,
        permission_read  = 1,
        permission_write = 0,
    }})
    -- 实时推送给已订阅该用户状态的好友（WebSocket StatusPresenceEvent）
    nk.status_update(uid, nk.json_encode(data))
end

local function clear_user_status(uid)
    nk.storage_delete({{
        collection = "user_status",
        key        = "current_match",
        user_id    = uid,
    }})
    -- 清空实时状态，好友端收到空状态即视为 idle
    nk.status_update(uid, nil)
end

-- ==========================================
-- 内部工具：分配身份
-- pvp 模式无身份，identity 模式按人数分配
-- ==========================================
local function assign_roles(player_count, mode)
    if mode == "pvp" then return {} end
    local roles = {}
    if player_count == 5 then
        roles = {"MONARCH", "MINISTER", "REBEL", "REBEL", "TRAITOR"}
    else
        error("identity 模式仅支持 5 人局，收到: " .. tostring(player_count))
    end
    return rules.shuffle(roles)
end

-- ==========================================
-- 初始化
-- ==========================================
function M.match_init(context, params)
    local max_players = params.max_players or 2
    -- 2人局默认 pvp（公平对战），5人局默认 identity（身份局）
    local mode = params.mode or (max_players == 2 and "pvp" or "identity")
    local state = {
        status = STATE.WAITING,
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

		-- 高并发与托管系统配置
		tick_rate = 1,              -- 每秒执行1次 match_loop
        current_turn_elapsed = 0,   -- 当前玩家已思考的时间
    }
    -- 加载服务端配置（首局对局初始化时读取，整局复用）
    local cfg = config.load(nk)
    state.config       = cfg
    state.turn_timeout = cfg.match.turn_timeout
	local label = { 
        mode = mode, 
        open = 1, -- 1表示开放，0表示关闭
        max = max_players 
    }
    return state, state.tick_rate, nk.json_encode(label)
    --local label = nk.json_encode({ mode = params.mode, max = max_players })
    --return state, state.tick_rate, label
end

function M.match_join(context, dispatcher, tick, state, presences)
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
            nk.logger_info("旁观者 " .. p.username .. " 加入观战，跟随 " .. tostring(target_id))

        else
        -- 1. 更新 Presence 引用，确保后续消息能发给他
        state.presences[p.user_id] = p

        -- 2. 如果是重连玩家（已经在 players 列表里）
        if state.status == STATE.PLAYING then
            -- 立即单独发一份全量数据给他，同步当前战场
            M.send_full_state_to_player(dispatcher, state, p)
            nk.logger_info("已为重连玩家 " .. p.username .. " 同步战场状态")
        else
            -- 正常加入逻辑（第一次进入房间）
            table.insert(state.presence_ids, p.user_id)

            -- 批量读取英雄库存 + 皮肤装备（单次 RTT）
            local unlocked_heroes = { aladdin = true }
            local equipped_skins  = {}
            local inv_objects = nk.storage_read({
                { collection = "hero_inventory", key = "unlocked_heroes", user_id = p.user_id },
                { collection = "skin_inventory", key = "equipped_skins",  user_id = p.user_id },
            })
            for _, obj in ipairs(inv_objects) do
                if obj.key == "unlocked_heroes" then unlocked_heroes = obj.value end
                if obj.key == "equipped_skins"  then equipped_skins  = obj.value end
            end

            -- 实际应从客户端 metadata 获取想选的英雄
            local want_hero = "aladdin"
            if not unlocked_heroes[want_hero] then
                nk.logger_warn("玩家 " .. p.username .. " 尝试使用未解锁英雄，重置为阿拉丁")
                want_hero = "aladdin"
            end

            local ph = state.config.match.player_health
            state.players[p.user_id] = {
                id = p.user_id,
                username = p.username,
                health = ph,
                max_health = ph,
                hand = {},
                hero = want_hero,
                skin_id = equipped_skins[want_hero] or nil,   -- 装备的皮肤（nil=默认）
                equipped_skins = equipped_skins,              -- 快照，供随机英雄后查表
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
			nk.logger_info("Player " .. p.username .. " joined, Location: " .. #state.presence_ids)
        end
        end -- spectator else 分支结束
    end

    -- 检查是否达到设定的最大人数
    local current_count = #state.presence_ids
    if state.status == STATE.WAITING and current_count >= state.max_players then
        state.status = STATE.PLAYING

		-- 【核心修改：更新房间标签】
        -- 将 open 设为 0，这样 match_list 的查询语句 +label.open:1 就搜不到这个房间了
        local new_label = {
            mode        = state.mode,
            open        = 0,
            max         = state.max_players,
            spectatable = 1,  -- 对局开始后允许旁观者加入
        }
        dispatcher.match_label_update(nk.json_encode(new_label))

		-- 随机分配英雄
		local hero_list = {
            -- 原版 6 英雄
            "aladdin", "alibaba", "saladin", "hakim", "scheherazade", "jafar",
            -- 第一批 12 英雄
            "ibn_battuta", "al_khwarizmi", "avicenna", "sinbad", "hulagu", "rumi",
            "zubaydah", "al_biruni", "tamerlane", "dunyazad", "antar", "nefertiti",
            -- 第二批 12 英雄
            "harun_al_rashid", "suleiman", "khayyam", "zenobia", "muawiyah", "nizamulmulk",
            "enheduanna", "al_mansur", "gilgamesh", "imru_al_qais", "basira", "dhul_qarnayn"
        }
		for _, p in pairs(state.players) do
			p.hero    = hero_list[math.random(#hero_list)]
            p.skin_id = (p.equipped_skins or {})[p.hero] or nil
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
		rules.broadcast_update(dispatcher, state)
        -- 如果主公已经确定，next_turn 逻辑里会正确从主公开始
        --M.next_turn(dispatcher, state)
		-- 开始第一个回合
        -- 注意：这里不需要再调 next_turn，因为 start_game 已经发过牌了，直接等待主公出牌即可
        nk.logger_info("对局正式启动！总人数：" .. current_count)
    end
    return state
end

--自动托管系统出牌逻辑
function M.perform_auto_play(dispatcher, state)
    local uid = state.current_turn_id
    if not uid then return end
    
    local player = state.players[uid]

    -- 1. 如果有挂起的技能选择，强行终止并按默认处理
    if state.pending_action and state.pending_action.player_id == uid then
        state.pending_action = nil
        -- 如果是摸牌前的技能被挂起，补摸 2 张牌防止玩家亏牌
        rules.draw_cards(state, uid, 2)
    end

    -- 2. 简单的托管出牌 AI：如果血量不满且有回血牌，自动吃一张
    if player and player.health < player.max_health then
        for i, card in ipairs(player.hand) do
            if card.type == "HEAL" then
                rules.handle_play_card(dispatcher, state, uid, { card_id = card.id })
                break
            end
        end
    end

    -- 3. 强行切入下一个人的回合
    nk.logger_info("托管结束，切换到下一位玩家")
    M.next_turn(dispatcher, state)
end


function M.match_loop(context, dispatcher, tick, state, messages)
    -- 如果游戏已结束，返回 nil 销毁对局实例，释放服务器内存
    if state.status == STATE.ENDED then return nil end

    -- ==========================================
    -- 1. 托管计时逻辑 (新增)
    -- ==========================================
    -- 只有在对局进行中才计时
    if state.status == STATE.PLAYING then
        state.current_turn_elapsed = state.current_turn_elapsed + 1

        -- 检查是否思考超时
        if state.current_turn_elapsed >= state.turn_timeout then
            nk.logger_info("玩家 " .. (state.current_turn_id or "未知") .. " 超时，执行托管")
            M.perform_auto_play(dispatcher, state)
            -- 托管后计时器会在 next_turn 中重置，这里直接返回 state 等待下一秒
            return state
        end
    end

    -- ==========================================
    -- 2. 处理客户端消息
    -- ==========================================
    for _, message in ipairs(messages) do
        local payload = nk.json_decode(message.data)
        local uid = message.sender.user_id

        -- 只要玩家有任何动作，就重置计时器，重新给 30 秒
        state.current_turn_elapsed = 0

        -- 情况 A：处理挂起的技能响应（如哈基姆、阿拉丁）
        if state.pending_action and state.pending_action.player_id == uid then
            hero_mgr.handle_response(dispatcher, state, uid, payload)
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
    end

    -- ==========================================
    -- 3. 检查胜负判定
    -- ==========================================
    local is_over, winner = rules.check_victory(dispatcher, state)
    if is_over then
        state.status = STATE.ENDED
        dispatcher.broadcast_message(30, nk.json_encode({winner = winner}))
        season_mgr.record_match(nk, state, winner)
        -- 对局结束，清除所有玩家在线状态
        for uid, _ in pairs(state.players) do
            clear_user_status(uid)
        end
    end

    return state
end


function M.next_turn(dispatcher, state)
    local ending_uid = state.current_turn_id
    -- 清除苏莱曼【封印】状态（新回合开始时失效）
    state.suleiman_sealed = nil
    if ending_uid then
        -- on_turn_end 钩子（弃牌前触发，辛巴达/纳芙蒂蒂等回合结束技能在此触发）
        hero_mgr.trigger("on_turn_end", dispatcher, state, ending_uid)
        -- 重置本回合攻击计数
        local ep_reset = state.players[ending_uid]
        if ep_reset then ep_reset.attacks_this_turn = 0 end
    end

    -- 1. 弃牌阶段：手牌数超过当前血量时弃至血量
    if ending_uid then
        local ep = state.players[ending_uid]
        if ep and ep.health > 0 and #ep.hand > ep.health then
            local discard_count = #ep.hand - ep.health
            local discarded = {}
            for _ = 1, discard_count do
                local card = table.remove(ep.hand)
                table.insert(state.discard_pile, card)
                table.insert(discarded, card.name or card.type)
            end
            dispatcher.broadcast_message(11, nk.json_encode({
                content = ep.username .. " 弃牌阶段弃置 " .. discard_count ..
                          " 张：" .. table.concat(discarded, "/")
            }))
        end
    end

    -- 2. 切换到下一个存活玩家
    state.current_turn_id = rules.get_next_player_id(state)
    state.current_turn_elapsed = 0
    local uid = state.current_turn_id
    local current_p = state.players[uid]

    -- ==========================================
    -- 2. 判定阶段 (处理所有判定牌 + 延时锦囊)
    -- ==========================================
    -- 先处理延时锦囊
    while #current_p.delayed_effects > 0 and current_p.health > 0 do
        local d_eff = table.remove(current_p.delayed_effects, 1)
        if d_eff.subtype == "discard1_draw2" then
            -- 黑血蛊：弃1张牌，摸2张
            if #current_p.hand > 0 then
                local discarded = table.remove(current_p.hand, math.random(#current_p.hand))
                table.insert(state.discard_pile, discarded)
            end
            rules.draw_cards(state, uid, 2)
            dispatcher.broadcast_message(11, nk.json_encode({
                content = current_p.username .. " 的【黑血蛊】结算：弃1摸2"
            }))
        elseif d_eff.subtype == "skip_play_phase" then
            -- 沙漠诅咒：跳过出牌阶段
            dispatcher.broadcast_message(11, nk.json_encode({
                content = current_p.username .. " 的【沙漠诅咒】结算：跳过出牌阶段"
            }))
            current_p.skip_play_phase = true
        elseif d_eff.subtype == "attack_minus1" then
            -- 虚弱标记：本回合攻击伤害-1
            dispatcher.broadcast_message(11, nk.json_encode({
                content = current_p.username .. " 的【虚弱标记】结算：本回合攻击伤害-1"
            }))
            current_p.attack_debuff = true
        end
    end

    -- 再处理判定牌
    while #current_p.judgments > 0 and current_p.health > 0 do
        local j_card = table.remove(current_p.judgments) -- 弹出最近的判定
        
        -- 核心步骤：执行判定
        local result_card = rules.execute_judgment(state)
        
        -- 【哈基姆改命埋点】：此处如果要做“强制改判定”，需要挂起流程
        -- 暂时按你的基础逻辑：天谴判断
        if j_card.type == "JUDGE_STORM" then
            if result_card.suit == "SPADE" and result_card.number >= 2 and result_card.number <= 9 then
                local jdmg = state.config and state.config.combat.judge_storm_damage or 3
                dispatcher.broadcast_message(11, nk.json_encode({
                    content = "【天谴】爆发！" .. current_p.username .. " 受到 " .. jdmg .. " 点天雷伤害！"
                }))
                rules.apply_damage(dispatcher, state, uid, jdmg, j_card.from)
            else
                dispatcher.broadcast_message(11, nk.json_encode({
                    content = "【天谴】未命中，传送至下一位玩家。"
                }))
                -- 传递给下一个存活玩家
                if state.status == STATE.PLAYING then
                    local next_uid = rules.get_next_player_id(state)
                    table.insert(state.players[next_uid].judgments, j_card)
                end
            end
        end
        
        -- 判定牌进入弃牌堆
        table.insert(state.discard_pile, result_card)
        
        -- 如果判定把人劈死了，直接结束此人回合，切到下一个人
        if current_p.health <= 0 then
            return M.next_turn(dispatcher, state)
        end
    end

    -- 重置每回合状态标志（immortal_used 是每局一次，不在此重置）
    current_p.attack_debuff = nil

    -- ==========================================
    -- 3. 摸牌阶段
    -- ==========================================
    -- 此时触发哈基姆技能，他可以看到接下来的摸牌顺序
    local suspended = hero_mgr.trigger("on_draw_phase_start", dispatcher, state, uid)

    -- 回合计数（供 season_manager 写入 match_history）
    state.turns = (state.turns or 0) + 1

    if not suspended then
        rules.draw_cards(state, uid, 2)
        rules.broadcast_update(dispatcher, state)
        -- 检查沙漠诅咒跳过出牌阶段
        if current_p.skip_play_phase then
            current_p.skip_play_phase = nil
            nk.logger_info(current_p.username .. " 跳过出牌阶段")
            -- 直接进下一个人
            M.next_turn(dispatcher, state)
        else
            hero_mgr.trigger("on_play_phase_start", dispatcher, state, uid)
        end
    end
end


function M.match_leave(context, dispatcher, tick, state, presences)
    for _, p in ipairs(presences) do
        if state.spectators[p.user_id] then
            state.spectators[p.user_id] = nil
            nk.logger_info("旁观者 " .. p.username .. " 离开")
        else
            -- 等待中主动离开：清除状态；游戏中断线保留状态（支持重连）
            if state.status == STATE.WAITING then
                clear_user_status(p.user_id)
            end
            nk.logger_info("玩家 " .. p.username .. " 掉线了")
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
        pending      = state.pending_action,
        me = {  -- 旁观者"以目标视角"看自己
            hand            = target.hand,
            hp              = target.health,
            role            = target.role,
            hero            = target.hero,
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
end

-- 辅助函数：专门给重连者同步信息
function M.send_full_state_to_player(dispatcher, state, presence)
    local p_data = state.players[presence.user_id]
    local payload = {
        is_reconnect = true,
        current_turn = state.current_turn_id,
        me = {
            hand      = p_data.hand,
            hp        = p_data.health,
            role      = p_data.role,
            hero      = p_data.hero,
            judgments = p_data.judgments,
            skin_id   = p_data.skin_id,
        },
        others = {} -- 同样的逻辑，根据权限过滤身份
    }
    -- 填充 others... (复用 broadcast_update 里的逻辑)
    dispatcher.broadcast_message(10, nk.json_encode(payload), {presence})
end


function M.match_join_attempt(context, dispatcher, tick, state, presence, metadata)
    -- 如果游戏已经结束，不允许任何人再进来
    if state.status == 2 then
        return state, false, "游戏已结束"
    end

    -- 核心逻辑：如果是已经在游戏里的玩家回来，无条件允许
    if state.players[presence.user_id] then
        nk.logger_info("检测到玩家 " .. presence.username .. " 正在重连...")
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
    if state.status == 1 then
        return state, false, "对局已开始，无法中途加入"
    end

    return state, true
end


function M.match_terminate(context, dispatcher, tick, state, grace_seconds)
    for uid, _ in pairs(state.players) do
        clear_user_status(uid)
    end
    return state
end
function M.match_signal(context, dispatcher, tick, state, data) return state, data end

return M

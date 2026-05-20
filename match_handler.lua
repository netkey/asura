local nk        = require("nakama")
local hero_mgr  = require("hero_manager")
local catalog   = require("hero_catalog")
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
        pending_heroes     = {},    -- 跨 join_attempt→join 传递客户端英雄选择

		-- 高并发与托管系统配置
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
    return state, 1, nk.json_encode(label)
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

            -- 从 join 时的 metadata 读取英雄选择，未携带则默认阿拉丁
            local requested = state.pending_heroes[p.user_id]
            state.pending_heroes[p.user_id] = nil
            local want_hero = "aladdin"
            if type(requested) == "string" and catalog.HEROES[requested] and unlocked_heroes[requested] then
                want_hero = requested
            elseif requested then
                nk.logger_warn("玩家 " .. p.username .. " 请求英雄 " .. tostring(requested) .. " 不可用，重置为阿拉丁")
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

		-- 随机分配英雄（从 hero_catalog 动态取，避免双维护）
		local hero_list = {}
        for id in pairs(catalog.HEROES) do
            table.insert(hero_list, id)
        end
        for _, p in pairs(state.players) do
            -- 保留玩家在 join 时自选的英雄；未选择或选择无效则随机分配
            if not p.hero or not catalog.HEROES[p.hero] then
                p.hero = hero_list[math.random(#hero_list)]
            end
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

    -- 1. 清理挂起的技能选择
    if state.pending_action and state.pending_action.player_id == uid then
        state.pending_action = nil
        rules.draw_cards(state, uid, 2)
    end

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

    -- 2. 装备：先上武器，再上防具
    for _, equip_type in ipairs({"WEAPON", "ARMOR", "HORSE"}) do
        local c = find_card(equip_type)
        if c then
            rules.handle_play_card(dispatcher, state, uid, { card_id = c.id })
        end
    end

    -- 3. 治疗：血量不满才吃
    if player.health < player.max_health then
        local c = find_card("HEAL")
        if c then
            rules.handle_play_card(dispatcher, state, uid, { card_id = c.id })
        end
    end

    -- 4. AOE：有群伤先放
    local aoe = find_card("AOE_SANDSTORM")
    if aoe then
        rules.handle_play_card(dispatcher, state, uid, { card_id = aoe.id })
    end

    -- 5. 喝酒：有酒且手里还有杀才喝（避免白喝）
    local has_attack = find_card("ATTACK")
    if has_attack then
        local wine = find_card("WINE")
        if wine then
            rules.handle_play_card(dispatcher, state, uid, { card_id = wine.id })
        end
    end

    -- 6. 攻击：优先打血量最少的存活敌方
    local atk = find_card("ATTACK")
    if atk then
        local target_id, min_hp = nil, math.huge
        for other_id, other_p in pairs(state.players) do
            if other_id ~= uid and other_p.health > 0 and other_p.health < min_hp then
                target_id = other_id
                min_hp = other_p.health
            end
        end
        if target_id then
            rules.handle_play_card(dispatcher, state, uid, { card_id = atk.id, target_id = target_id })
        end
    end

    nk.logger_info("托管结束，切换到下一位玩家")
    M.next_turn(dispatcher, state)
end


function M.match_loop(context, dispatcher, tick, state, messages)
    -- 如果游戏已结束，返回 nil 销毁对局实例，释放服务器内存
    if state.status == STATE.ENDED then return nil end

    -- 每个 tick 开始时重置 next_turn 递归深度计数器
    state._turn_depth = 0

    -- ==========================================
    -- 1. 托管计时逻辑 (新增)
    -- ==========================================
    -- 只有在对局进行中才计时
    if state.status == STATE.PLAYING then
        -- 检查 pending_action 超时（防止防御/AOE/求救等待永久卡死）
        if state.pending_action and state.pending_action.deadline and os.time() > state.pending_action.deadline then
            local act   = state.pending_action
            if act.type == "WAITING_FOR_DEFENSE" then
                rules.handle_response(dispatcher, state, act.target_id, {confirm=false})
            elseif act.type == "WAITING_FOR_AOE" then
                rules.handle_response(dispatcher, state, act.current_target, {confirm=false})
            elseif act.type == "WAITING_FOR_RESCUE" then
                rules.handle_response(dispatcher, state, act.rescuers[act.current_rescuer_idx], {confirm=false})
            elseif act.type == "WAITING_FOR_TRICK_SELECT" then
                rules.handle_response(dispatcher, state, act.chooser_id, {confirm=false})
            elseif act.type == "HAKIM_XING_XIANG"
                or act.type == "SULEIMAN_YU_FENG"
                or act.type == "HARUN_SELECT_TARGET"
                or act.type == "HARUN_CHOOSE"
                or act.type == "IBN_BATTUTA_YUAN_XING"
                or act.type == "RUMI_XUANHUI"
                or act.type == "SCHEHERAZADE_QIANYE"
                or act.type == "ALADDIN_LAMP"
                or act.type == "ALIBABA_COUNTER"
                or act.type == "AL_BIRUNI_CELIANG"
                or act.type == "BASIRA_DONG_CHA"
                or act.type == "GILGAMESH_BU_XIU"
                or act.type == "AVICENNA_ZHEN"
                or act.type == "ENHEDUANNA_SONG_CI"
                or act.type == "ENHEDUANNA_SONG_CI_GIVE" then
                local hero_mgr = require("hero_manager")
                hero_mgr.handle_response(dispatcher, state, act.player_id, {confirm=false})
            end
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
                    hero_mgr.trigger("on_play_phase_start", dispatcher, state, uid)
                end
            end
            return state
        end

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
        local ok, payload = pcall(nk.json_decode, message.data)
        if not ok or type(payload) ~= "table" then goto continue end
        local uid = message.sender.user_id
        if not state.players[uid] then goto continue end

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
        ::continue::
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
    -- 防止递归过深（极端情况：多人连续死亡 / 全员跳过出牌）
    state._turn_depth = (state._turn_depth or 0) + 1
    if state._turn_depth > 20 then
        nk.logger_warn("next_turn 递归深度超限，延至下一 tick")
        state._turn_depth = 0
        state.pending_turn_continuation = {uid = state.current_turn_id}
        return
    end

    local ending_uid = state.current_turn_id
    -- 清除苏莱曼【御风】：目标回合结束时清除封锁
    if state.suleiman_yu_feng and state.suleiman_yu_feng.target_id == ending_uid then
        state.suleiman_yu_feng = nil
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
    if ep_reset then ep_reset.attacks_this_turn = 0 end

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
    -- 先处理延时锦囊（max_iter 防止未来扩展时意外无限循环）
    local delayed_iter = 0
    while #current_p.delayed_effects > 0 and current_p.health > 0 and delayed_iter < 20 do
        delayed_iter = delayed_iter + 1
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

    -- 判定阶段前触发哈基姆【星象】：可以在判定前观看并调整牌堆顶
    if #current_p.judgments > 0 then
        local suspended = hero_mgr.trigger("on_judgment_phase_start", dispatcher, state, uid)
        if suspended then
            state.pending_turn_continuation = {uid = uid}
            return
        end
    end

    M.do_judgment_and_draw_phase(dispatcher, state)
end

-- 判定阶段 + 摸牌阶段（可从 next_turn 直接调用，也可从 pending_turn_continuation 恢复）
function M.do_judgment_and_draw_phase(dispatcher, state)
    local uid       = state.current_turn_id
    local current_p = state.players[uid]
    if not current_p or current_p.health <= 0 then
        return M.next_turn(dispatcher, state)
    end

    -- 处理判定牌
    while #current_p.judgments > 0 and current_p.health > 0 do
        local j_card = table.remove(current_p.judgments)
        local result_card = rules.execute_judgment(state)

        if j_card.type == "JUDGE_STORM" then
            if result_card.suit == "SPADE" and result_card.number >= 2 and result_card.number <= 9 then
                local jdmg = state.config and state.config.combat.judge_storm_damage or 3
                dispatcher.broadcast_message(11, nk.json_encode({
                    content = "【天谴】爆发！" .. current_p.username .. " 受到 " .. jdmg .. " 点天雷伤害！"
                }))
                state._in_judgment_phase = true
                rules.apply_damage(dispatcher, state, uid, jdmg, j_card.from)
                state._in_judgment_phase = nil
                if state.pending_action and state.pending_action.type == "WAITING_FOR_RESCUE" then
                    return
                end
            else
                dispatcher.broadcast_message(11, nk.json_encode({
                    content = "【天谴】未命中，传送至下一位玩家。"
                }))
                if state.status == STATE.PLAYING then
                    local next_uid = rules.get_next_player_id(state)
                    table.insert(state.players[next_uid].judgments, j_card)
                end
            end
        end

        table.insert(state.discard_pile, result_card)

        if current_p.health <= 0 then
            return M.next_turn(dispatcher, state)
        end
    end

    -- 重置每回合状态标志
    current_p.attack_debuff = nil

    -- 摸牌阶段
    -- 回合计数（供 season_manager 写入 match_history）
    state.turns = (state.turns or 0) + 1

    local draw_suspended = hero_mgr.trigger("on_draw_phase_start", dispatcher, state, uid)
    if draw_suspended then
        state.pending_draw_continuation = {uid = uid}
        return
    end

    rules.draw_cards(state, uid, 2)
    rules.broadcast_update(dispatcher, state)
    -- 检查沙漠诅咒跳过出牌阶段
    if current_p.skip_play_phase then
        current_p.skip_play_phase = nil
        nk.logger_info(current_p.username .. " 跳过出牌阶段")
        M.next_turn(dispatcher, state)
    else
        hero_mgr.trigger("on_play_phase_start", dispatcher, state, uid)
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
                state.pending_heroes[p.user_id] = nil
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
            })
        end
    end
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

    -- 记录客户端期望的英雄（match_join 消费）
    if metadata and type(metadata.hero_id) == "string" then
        state.pending_heroes[presence.user_id] = metadata.hero_id
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

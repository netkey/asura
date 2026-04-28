local nk = require("nakama")
local hero_mgr = require("hero_manager")
local rules = require("game_rules")

local M = {}

-- 游戏状态定义
local STATE = { WAITING = 0, PLAYING = 1, ENDED = 2 }

-- ==========================================
-- 内部工具：分配身份 (新增)
-- ==========================================
local function assign_roles(player_count)
    local roles = {}
    if player_count == 2 then
        -- 2人局: 主公 + 反贼
        roles = {"MONARCH", "REBEL"}
    elseif player_count == 5 then
        -- 5人局: 主公 + 忠臣 + 反贼x2 + 内奸
        roles = {"MONARCH", "MINISTER", "REBEL", "REBEL", "TRAITOR"}
    else
        -- 仅支持 2/5 人
        error("Unsupported player count: " .. tostring(player_count) .. ". Only 2 or 5 players are supported.")
    end
    return rules.shuffle(roles)
end

-- ==========================================
-- 初始化
-- ==========================================
function M.match_init(context, params)
    local max_players = params.max_players or 2
	local mode = params.mode or "classic"
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

		-- 高并发与托管系统配置
		tick_rate = 1,              -- 每秒执行1次 match_loop
        turn_timeout = 30,          -- 默认思考时限30秒
        current_turn_elapsed = 0,   -- 当前玩家已思考的时间
    }
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

			-- 【新增：读取玩家拥有的英雄列表进行校验】
            local unlocked_heroes = { aladdin = true } -- 默认有阿拉丁
            local objects = nk.storage_read({{
                collection = "hero_inventory",
                key = "unlocked_heroes",
                user_id = p.user_id
            }})
            if #objects > 0 then
                unlocked_heroes = objects[1].value
            end

            -- 假设客户端在 Metadata 中传入了选中的英雄，如 p.metadata.hero
            -- 这里为了演示，我们假设玩家想选 "hakim"，但我们要校验
            local want_hero = "aladdin" -- 实际应从客户端 metadata 获取
            if not unlocked_heroes[want_hero] then
                nk.logger_warn("玩家 " .. p.username .. " 尝试使用未解锁英雄，重置为阿拉丁")
                want_hero = "aladdin"
            end


            state.players[p.user_id] = {
                id = p.user_id,
                username = p.username,
                health = 4,
                max_health = 4,
                hand = {},
                hero = want_hero, 
                role = "UNKNOWN",
                judgments = {}
            }
			nk.logger_info("Player " .. p.username .. " joined, Location: " .. #state.presence_ids)
        end
    end

	-- 检查是否达到设定的最大人数
    local current_count = #state.presence_ids
    if state.status == STATE.WAITING and current_count >= state.max_players then
        state.status = STATE.PLAYING

		-- 【核心修改：更新房间标签】
        -- 将 open 设为 0，这样 match_list 的查询语句 +label.open:1 就搜不到这个房间了
        local new_label = {
            mode = state.mode, -- 建议在 match_init 把 mode 存入 state
			open = 0,
            max = state.max_players
        }
        dispatcher.match_label_update(nk.json_encode(new_label))

		-- 随机分配英雄
		local hero_list = {"aladdin", "alibaba", "saladin", "hakim"}
		for _, p in pairs(state.players) do
			p.hero = hero_list[math.random(#hero_list)]
		end
        -- 【合并：身份分配逻辑】
        local roles = assign_roles(current_count)
        for i, uid in ipairs(state.presence_ids) do
            local p = state.players[uid]
            p.role = roles[i]
            -- 主公特权：血量上限+1，并回满血
            if p.role == "MONARCH" then
                p.health = 5
                p.max_health = 5
                state.current_turn_id = uid -- 主公默认首发
            end
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
                rules.handle_play_card(dispatcher, state, uid, payload)
            elseif message.op_code == 4 then -- 手动结束回合
                M.next_turn(dispatcher, state)
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
        -- 广播游戏结束消息 (OpCode 30)
        dispatcher.broadcast_message(30, nk.json_encode({winner = winner}))
        
        -- 【可选】在这里可以立即调用金币结算逻辑
        -- M.settle_game(dispatcher, state, winner)
    end

    return state
end


function M.next_turn(dispatcher, state)
    -- 1. 弃牌阶段：手牌数超过当前血量时弃至血量
    local ending_uid = state.current_turn_id
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
    -- 2. 判定阶段 (处理所有判定牌)
    -- ==========================================
    -- 英雄改命点 A：某些英雄可以在判定开始前改变判定牌堆（例如哈基姆提前星象）
    -- 但通常我们建议在判定循环内部给改命英雄留出响应空间
    
    while #current_p.judgments > 0 and current_p.health > 0 do
        local j_card = table.remove(current_p.judgments) -- 弹出最近的判定
        
        -- 核心步骤：执行判定
        local result_card = rules.execute_judgment(state)
        
        -- 【哈基姆改命埋点】：此处如果要做“强制改判定”，需要挂起流程
        -- 暂时按你的基础逻辑：天谴判断
        if j_card.type == "JUDGE_STORM" then
            if result_card.suit == "SPADE" and result_card.number >= 2 and result_card.number <= 9 then
                dispatcher.broadcast_message(11, nk.json_encode({
                    content = "【天谴】爆发！" .. current_p.username .. " 受到 3 点天雷伤害！"
                }))
                rules.apply_damage(dispatcher, state, uid, 3, j_card.from)
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

    -- ==========================================
    -- 3. 摸牌阶段
    -- ==========================================
    -- 此时触发哈基姆技能，他可以看到接下来的摸牌顺序
    local suspended = hero_mgr.trigger("on_draw_phase_start", dispatcher, state, uid)

    if not suspended then
        rules.draw_cards(state, uid, 2)
        rules.broadcast_update(dispatcher, state)
    end
end


function M.match_leave(context, dispatcher, tick, state, presences)
    for _, p in ipairs(presences) do
        -- 仅标记为离线，不要从 state.players 中删除, 提供断线重连功能
        -- 这样他的英雄、手牌、血量都会保留在原位
        nk.logger_info("玩家 " .. p.username .. " 掉线了")
    end
    return state
end

-- 辅助函数：专门给重连者同步信息
function M.send_full_state_to_player(dispatcher, state, presence)
    local p_data = state.players[presence.user_id]
    local payload = {
        is_reconnect = true,
        current_turn = state.current_turn_id,
        me = {
            hand = p_data.hand,
            hp = p_data.health,
            role = p_data.role,
            hero = p_data.hero,
            judgments = p_data.judgments
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

    -- 如果是新玩家想中途加入已开始的游戏，拒绝
    if state.status == 1 then
        return state, false, "对局已开始，无法中途加入"
    end

    return state, true
end


function M.match_terminate(context, dispatcher, tick, state, grace_seconds) return state end
function M.match_signal(context, dispatcher, tick, state, data) return state, data end

return M

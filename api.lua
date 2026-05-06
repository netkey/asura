local nk        = require("nakama")
local catalog   = require("hero_catalog")
local gconfig   = require("game_config")
local season_mgr = require("season_manager")

-- ==========================================
-- 内部：统一判断玩家是否可使用某英雄
-- 后期加限时免费活动只需在此处扩展
-- ==========================================
local function is_hero_accessible(hero_id, inventory, free_events)
    local info = catalog.HEROES[hero_id]
    if not info then return false end
    if info.price == 0 then return true end          -- 永久免费
    if inventory[hero_id] then return true end        -- 已购买
    if free_events then                               -- 限时免费活动
        local ev = free_events[hero_id]
        if ev then
            local now = os.time()
            if now >= ev.start_time and now <= ev.end_time then return true end
        end
    end
    return false
end

-- 读取当前生效的限时免费活动（存于服务端全局 storage）
local function load_free_events()
    local objects = nk.storage_read({{
        collection = "events",
        key        = "free_heroes",
        user_id    = nil,
    }})
    return (#objects > 0) and objects[1].value or {}
end

-- ==========================================
-- 匹配系统
-- ==========================================
local function find_or_create_match(context, payload)
    local json  = nk.json_decode(payload)
    local mode  = json.mode or "standard"
    local query = "+label.mode:" .. mode .. " +label.open:1"
    local matches = nk.match_list(10, true, nil, nil, nil, query)
    if #matches > 0 then
        return nk.json_encode({ match_id = matches[1].match_id })
    end
    local match_id = nk.match_create("match_handler", {
        max_players = json.max_players,
        mode = mode
    })
    return nk.json_encode({ match_id = match_id })
end
nk.register_rpc(find_or_create_match, "find_or_create_match")

-- ==========================================
-- 校验英雄使用权
-- ==========================================
local function check_hero_access(context, payload)
    local json    = nk.json_decode(payload)
    local user_id = context.user_id
    local hero_id = json.hero_id

    if not catalog.HEROES[hero_id] then
        return nk.json_encode({ has_access = false, error = "英雄不存在" })
    end

    local objects = nk.storage_read({{
        collection = "hero_inventory",
        key        = "unlocked_heroes",
        user_id    = user_id
    }})
    local inventory = (#objects > 0) and objects[1].value or {}

    return nk.json_encode({ has_access = is_hero_accessible(hero_id, inventory, load_free_events()) })
end
nk.register_rpc(check_hero_access, "check_hero_access")

-- ==========================================
-- 商店列表（含玩家解锁状态）
-- ==========================================
local function get_hero_shop(context, payload)
    local user_id = context.user_id

    local objects = nk.storage_read({{
        collection = "hero_inventory",
        key        = "unlocked_heroes",
        user_id    = user_id
    }})
    local inventory      = (#objects > 0) and objects[1].value or {}
    local free_events    = load_free_events()
    local price_override = gconfig.load(nk).hero_price_overrides

    local heroes = {}
    for id, info in pairs(catalog.HEROES) do
        local ev            = free_events[id]
        local now           = os.time()
        local is_free_event = ev and now >= ev.start_time and now <= ev.end_time
        local effective_price = price_override[id] or info.price
        table.insert(heroes, {
            id            = id,
            name          = info.name,
            price         = effective_price,
            tier          = info.tier,
            description   = info.description,
            owned         = is_hero_accessible(id, inventory, free_events),
            free_until    = is_free_event and ev.end_time or nil,
        })
    end

    -- 按 tier 升序、name 升序，保证展示顺序稳定
    table.sort(heroes, function(a, b)
        if a.tier ~= b.tier then return a.tier < b.tier end
        return a.name < b.name
    end)

    return nk.json_encode({ heroes = heroes })
end
nk.register_rpc(get_hero_shop, "get_hero_shop")

-- ==========================================
-- 余额查询
-- ==========================================
local function get_wallet(context, payload)
    local account = nk.account_get_id(context.user_id)
    local wallet  = nk.json_decode(account.wallet)
    return nk.json_encode({ gold = wallet.gold or 0 })
end
nk.register_rpc(get_wallet, "get_wallet")

-- ==========================================
-- 购买英雄
-- ==========================================
local function buy_hero(context, payload)
    local json    = nk.json_decode(payload)
    local user_id = context.user_id
    local hero_id = json.hero_id

    local info = catalog.HEROES[hero_id]
    if not info then
        return nk.json_encode({ success = false, error = "英雄不存在" })
    end
    -- 优先使用配置覆盖价格（运营活动打折用）
    local price = gconfig.load(nk).hero_price_overrides[hero_id] or info.price
    if price == 0 then
        return nk.json_encode({ success = false, error = "该英雄无需购买" })
    end

    -- 检查是否已拥有（避免重复扣款）
    local objects = nk.storage_read({{
        collection = "hero_inventory",
        key        = "unlocked_heroes",
        user_id    = user_id
    }})
    local inventory = (#objects > 0) and objects[1].value or {}
    if inventory[hero_id] then
        return nk.json_encode({ success = false, error = "already_owned" })
    end

    -- 原子扣款：金币不足时 wallet_update 抛出异常
    local ok, err = pcall(nk.wallet_update, user_id, { gold = -price }, {}, true)
    if not ok then
        return nk.json_encode({ success = false, error = "金币不足" })
    end

    inventory[hero_id] = true
    nk.storage_write({{
        collection       = "hero_inventory",
        key              = "unlocked_heroes",
        user_id          = user_id,
        value            = inventory,
        permission_read  = 1,
        permission_write = 0,
    }})

    return nk.json_encode({ success = true })
end
nk.register_rpc(buy_hero, "buy_hero")

-- ==========================================
-- 管理员充值（仅限服务端 HTTP Key 调用）
-- 客户端调用时 context.user_id 非空，会被拒绝
-- ==========================================
local function admin_grant_gold(context, payload)
    if context.user_id and context.user_id ~= "" then
        return nk.json_encode({ success = false, error = "需要管理员权限" })
    end

    local json   = nk.json_decode(payload)
    local target = json.user_id
    local amount = tonumber(json.amount)

    if not target or not amount or amount <= 0 then
        return nk.json_encode({ success = false, error = "参数无效：需要 user_id 和正整数 amount" })
    end

    nk.wallet_update(target, { gold = amount }, { reason = "admin_grant" }, true)

    local account = nk.account_get_id(target)
    local wallet  = nk.json_decode(account.wallet)

    return nk.json_encode({ success = true, new_balance = wallet.gold or 0 })
end
nk.register_rpc(admin_grant_gold, "admin_grant_gold")

-- ==========================================
-- 管理员设置限时免费活动（仅限服务端调用）
-- payload: { "heroes": ["hakim","hulagu"], "start_time": 1746000000, "end_time": 1746604800 }
-- ==========================================
local function admin_set_free_event(context, payload)
    if context.user_id and context.user_id ~= "" then
        return nk.json_encode({ success = false, error = "需要管理员权限" })
    end

    local json       = nk.json_decode(payload)
    local hero_ids   = json.heroes
    local start_time = tonumber(json.start_time)
    local end_time   = tonumber(json.end_time)

    if not hero_ids or not start_time or not end_time or start_time >= end_time then
        return nk.json_encode({ success = false, error = "参数无效" })
    end

    -- 读取现有活动数据，合并写入（支持多个独立活动并存）
    local objects = nk.storage_read({{
        collection = "events", key = "free_heroes", user_id = nil
    }})
    local events = (#objects > 0) and objects[1].value or {}

    for _, hid in ipairs(hero_ids) do
        if catalog.HEROES[hid] then
            events[hid] = { start_time = start_time, end_time = end_time }
        end
    end

    nk.storage_write({{
        collection       = "events",
        key              = "free_heroes",
        user_id          = nil,
        value            = events,
        permission_read  = 2,  -- 所有人可读（客户端可查询活动列表）
        permission_write = 0,
    }})

    return nk.json_encode({ success = true, active_events = events })
end
nk.register_rpc(admin_set_free_event, "admin_set_free_event")

-- ==========================================
-- 查询当前有效配置（公开，供客户端了解游戏参数）
-- ==========================================
local function get_config(context, payload)
    local cfg = gconfig.load(nk)
    return nk.json_encode({ config = cfg })
end
nk.register_rpc(get_config, "get_config")

-- ==========================================
-- 管理员更新游戏配置（仅限服务端调用）
-- 支持深度部分更新，示例：
--   {"match":{"turn_timeout":60}}
--   {"hero_price_overrides":{"hakim":300}}
--   {"combat":{"rebel_kill_reward":5},"hero_price_overrides":{"hulagu":800}}
-- ==========================================
local function admin_set_config(context, payload)
    if context.user_id and context.user_id ~= "" then
        return nk.json_encode({ success = false, error = "需要管理员权限" })
    end

    local updates = nk.json_decode(payload)
    if not updates or type(updates) ~= "table" then
        return nk.json_encode({ success = false, error = "payload 必须为 JSON 对象" })
    end

    -- 读取当前存储中的覆盖项（不是 DEFAULTS，只存与默认值不同的部分）
    local objects = nk.storage_read({{
        collection = "server_config",
        key        = "game_config",
        user_id    = nil,
    }})
    local stored = (#objects > 0) and objects[1].value or {}

    -- 将本次 updates 深度合并进已存储的覆盖项
    local function deep_merge(base, over)
        local r = {}
        for k, v in pairs(base) do r[k] = v end
        for k, v in pairs(over) do
            if type(v) == "table" and type(r[k]) == "table" then
                r[k] = deep_merge(r[k], v)
            else
                r[k] = v
            end
        end
        return r
    end
    local new_stored = deep_merge(stored, updates)

    nk.storage_write({{
        collection       = "server_config",
        key              = "game_config",
        user_id          = nil,
        value            = new_stored,
        permission_read  = 2,
        permission_write = 0,
    }})

    -- 返回合并 DEFAULTS 后的完整有效配置，便于确认
    local effective = gconfig.load(nk)
    return nk.json_encode({ success = true, effective_config = effective })
end
nk.register_rpc(admin_set_config, "admin_set_config")

-- ==========================================
-- 查询当前赛季信息（公开）
-- ==========================================
local function get_season_info(context, payload)
    local season = season_mgr.get_current_season(nk)
    if not season then
        return nk.json_encode({ active = false })
    end
    return nk.json_encode({ active = true, season = season })
end
nk.register_rpc(get_season_info, "get_season_info")

-- ==========================================
-- 查询当前玩家本赛季统计
-- ==========================================
local function get_my_stats(context, payload)
    local user_id = context.user_id
    local season  = season_mgr.get_current_season(nk)
    if not season then
        return nk.json_encode({ error = "当前无进行中的赛季" })
    end
    local objects = nk.storage_read({{
        collection = "season_stats",
        key        = season.season_id,
        user_id    = user_id,
    }})
    local stats = (#objects > 0) and objects[1].value or {
        season_id = season.season_id, games = 0, wins = 0, losses = 0,
        rating = 1000, best_streak = 0, current_streak = 0,
        hero_stats = {}, role_stats = {},
    }
    return nk.json_encode({ stats = stats })
end
nk.register_rpc(get_my_stats, "get_my_stats")

-- ==========================================
-- 查询对局历史（玩家自身）
-- payload: { "season_id": "2026_Q2" }  可选，默认当前赛季
-- ==========================================
local function get_match_history(context, payload)
    local user_id  = context.user_id
    local json     = nk.json_decode(payload)
    local season   = season_mgr.get_current_season(nk)
    local sid      = (json and json.season_id) or (season and season.season_id)
    if not sid then
        return nk.json_encode({ error = "请指定 season_id 或先开启赛季" })
    end

    local list = nk.storage_list(user_id, "match_history", 50, "")
    local records = {}
    if list then
        -- 筛选本赛季记录，按时间倒序
        for _, item in ipairs(list) do
            if item.value and item.value.season_id == sid then
                table.insert(records, item.value)
            end
        end
        table.sort(records, function(a, b) return (a.timestamp or 0) > (b.timestamp or 0) end)
    end
    return nk.json_encode({ season_id = sid, records = records })
end
nk.register_rpc(get_match_history, "get_match_history")

-- ==========================================
-- 赛季排行榜（公开）
-- payload: { "limit": 20 }
-- ==========================================
local function get_leaderboard(context, payload)
    local season = season_mgr.get_current_season(nk)
    if not season then
        return nk.json_encode({ error = "当前无进行中的赛季" })
    end
    local json  = nk.json_decode(payload)
    local limit = (json and tonumber(json.limit)) or 20
    limit = math.max(1, math.min(limit, 100))

    local records, _, _ = nk.leaderboard_records_list(season.leaderboard_id, nil, limit, nil, 0)
    local board = {}
    if records then
        for i, r in ipairs(records) do
            table.insert(board, {
                rank     = i,
                user_id  = r.owner_id,
                username = r.username,
                rating   = r.score,
            })
        end
    end
    return nk.json_encode({ season_id = season.season_id, leaderboard = board })
end
nk.register_rpc(get_leaderboard, "get_leaderboard")

-- ==========================================
-- 管理员开启新赛季（仅服务端调用）
-- payload: { "name":"2026年第二赛季", "start_time":1746057600, "end_time":1753833600 }
-- ==========================================
local function admin_start_season(context, payload)
    if context.user_id and context.user_id ~= "" then
        return nk.json_encode({ success = false, error = "需要管理员权限" })
    end

    local json       = nk.json_decode(payload)
    local name       = json.name
    local start_time = tonumber(json.start_time)
    local end_time   = tonumber(json.end_time)

    if not name or not start_time or not end_time or start_time >= end_time then
        return nk.json_encode({ success = false, error = "参数无效：需要 name, start_time, end_time" })
    end

    -- 按 start_time 生成赛季 ID（格式 YYYY_QN）
    local t = os.date("*t", start_time)
    local q = math.ceil(t.month / 3)
    local season_id = string.format("%d_Q%d", t.year, q)
    local lb_id     = "season_" .. season_id

    -- 创建 Nakama leaderboard（已存在时忽略错误）
    pcall(nk.leaderboard_create, lb_id, true, "desc", "set", "", {})

    local season = {
        season_id      = season_id,
        name           = name,
        start_time     = start_time,
        end_time       = end_time,
        leaderboard_id = lb_id,
    }
    nk.storage_write({{
        collection       = "season_config",
        key              = "current",
        user_id          = nil,
        value            = season,
        permission_read  = 2,
        permission_write = 0,
    }})

    return nk.json_encode({ success = true, season = season })
end
nk.register_rpc(admin_start_season, "admin_start_season")

-- ==========================================
-- 管理员结束当前赛季（仅服务端调用）
-- ==========================================
local function admin_end_season(context, payload)
    if context.user_id and context.user_id ~= "" then
        return nk.json_encode({ success = false, error = "需要管理员权限" })
    end

    local season = season_mgr.get_current_season(nk)
    if not season then
        return nk.json_encode({ success = false, error = "当前没有进行中的赛季" })
    end

    -- 归档：将当前赛季配置写入历史记录
    nk.storage_write({{
        collection       = "season_config",
        key              = "archive_" .. season.season_id,
        user_id          = nil,
        value            = season,
        permission_read  = 2,
        permission_write = 0,
    }})

    -- 删除 current 赛季配置
    nk.storage_delete({{ collection = "season_config", key = "current", user_id = nil }})

    return nk.json_encode({ success = true, archived_season = season.season_id })
end
nk.register_rpc(admin_end_season, "admin_end_season")

-- ==========================================
-- 好友系统
-- ==========================================

-- 发送好友请求 / 接受请求（Nakama 双向调用自动升为好友）
-- payload: {"username":"xxx"} 或 {"user_id":"xxx"}
local function add_friend(context, payload)
    local json = nk.json_decode(payload)
    if not json or (not json.username and not json.user_id) then
        return nk.json_encode({ success = false, error = "需要 username 或 user_id" })
    end
    local user_ids  = json.user_id  and { json.user_id  } or {}
    local usernames = json.username and { json.username } or {}
    nk.friends_add(context.user_id, user_ids, usernames)
    return nk.json_encode({ success = true })
end
nk.register_rpc(add_friend, "add_friend")

-- 删除好友 / 拒绝请求
-- payload: {"user_id":"xxx"}
local function remove_friend(context, payload)
    local json = nk.json_decode(payload)
    if not json or not json.user_id then
        return nk.json_encode({ success = false, error = "需要 user_id" })
    end
    nk.friends_delete(context.user_id, { json.user_id }, {})
    return nk.json_encode({ success = true })
end
nk.register_rpc(remove_friend, "remove_friend")

-- 屏蔽用户
-- payload: {"user_id":"xxx"}
local function block_user(context, payload)
    local json = nk.json_decode(payload)
    if not json or not json.user_id then
        return nk.json_encode({ success = false, error = "需要 user_id" })
    end
    nk.friends_block(context.user_id, { json.user_id }, {})
    return nk.json_encode({ success = true })
end
nk.register_rpc(block_user, "block_user")

-- 查询好友列表 / 请求列表
-- payload: {"state":0}  0=好友 1=已发请求 2=收到请求 3=已屏蔽，不传则返回全部
local function get_friends(context, payload)
    local json      = nk.json_decode(payload)
    local req_state = json and json["state"]  -- 可为 nil（查全部）

    local result = {}
    local states_to_query = req_state ~= nil and { req_state } or { 0, 1, 2, 3 }

    for _, s in ipairs(states_to_query) do
        local friends, _, _ = nk.friends_list(context.user_id, 100, s, "")
        if friends then
            for _, f in ipairs(friends) do
                table.insert(result, {
                    user_id  = f.user.id,
                    username = f.user.username,
                    state    = s,  -- 0=好友 1=我发出 2=对方发来 3=屏蔽
                })
            end
        end
    end
    return nk.json_encode({ friends = result })
end
nk.register_rpc(get_friends, "get_friends")

-- 邀请好友加入对局（通过 Nakama 通知推送，非持久化）
-- payload: {"user_id":"xxx","match_id":"yyy"}
local function invite_to_match(context, payload)
    local json     = nk.json_decode(payload)
    local target   = json and json.user_id
    local match_id = json and json.match_id
    if not target or not match_id then
        return nk.json_encode({ success = false, error = "需要 user_id 和 match_id" })
    end

    local account  = nk.account_get_id(context.user_id)
    local username = account and account.user and account.user.username or "某人"

    nk.notifications_send({{
        user_id    = target,
        subject    = username .. " 邀请你加入对局",
        content    = { match_id = match_id, from_user_id = context.user_id, from_username = username },
        code       = 1,      -- 1 = 对局邀请
        sender_id  = context.user_id,
        persistent = false,
    }})
    return nk.json_encode({ success = true })
end
nk.register_rpc(invite_to_match, "invite_to_match")

-- ==========================================
-- 观战：查询当前可观战的对局列表
-- payload: {"mode":"pvp"} 可选，不传则返回全部模式
-- ==========================================
local function find_spectatable_match(context, payload)
    local json  = nk.json_decode(payload)
    local mode  = json and json.mode
    local query = "+label.spectatable:1"
    if mode then
        query = query .. " +label.mode:" .. mode
    end
    local matches = nk.match_list(20, true, nil, nil, nil, query)
    local list = {}
    for _, m in ipairs(matches) do
        local label = nk.json_decode(m.label)
        table.insert(list, {
            match_id      = m.match_id,
            mode          = label and label.mode,
            player_count  = m.size,
        })
    end
    return nk.json_encode({ matches = list })
end
nk.register_rpc(find_spectatable_match, "find_spectatable_match")

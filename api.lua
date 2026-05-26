local nk          = require("nakama")
local catalog     = require("hero_catalog")
local gconfig     = require("game_config")
local season_mgr  = require("season_manager")
local ach_mgr     = require("achievement_manager")
local skin_catalog = require("skin_catalog")
local rate_limiter = require("rate_limiter")

-- pcall 包装器：防止 RPC 中未捕获异常导致客户端收到非 JSON 500
local function safe_rpc(fn)
    return function(context, payload)
        local ok, result = pcall(fn, context, payload)
        if not ok then
            nk.logger_error("RPC uncaught error: " .. tostring(result))
            return nk.json_encode({ success = false, error = "internal_error" })
        end
        return result
    end
end

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
local VALID_MODES = {pvp = true, identity = true}
local VALID_PLAYER_COUNTS = {[2] = true, [5] = true}

local function find_or_create_match(context, payload)
    if not rate_limiter.check(nk, context.user_id, "find_or_create_match", 10, 60) then
        return nk.json_encode({ success = false, error = "too_many_requests" })
    end
    local ok, json = pcall(nk.json_decode, payload)
    if not ok or type(json) ~= "table" then
        error("invalid payload", 2)
    end
    local mode = VALID_MODES[json.mode] and json.mode or "pvp"
    local max_players = VALID_PLAYER_COUNTS[json.max_players] and json.max_players or 5
    local query = "+label.mode:" .. mode .. " +label.open:1"
    local matches = nk.match_list(10, true, nil, nil, nil, query)
    if #matches > 0 then
        return nk.json_encode({ match_id = matches[1].match_id })
    end
    -- 二次查询：降低并发时两人各自开房的概率（经典 TOCTOU）
    matches = nk.match_list(10, true, nil, nil, nil, query)
    if #matches > 0 then
        return nk.json_encode({ match_id = matches[1].match_id })
    end
    local match_id = nk.match_create("match_handler", {
        max_players = max_players,
        mode = mode
    })
    return nk.json_encode({ match_id = match_id })
end
nk.register_rpc(safe_rpc(find_or_create_match), "find_or_create_match")

-- ==========================================
-- 校验英雄使用权
-- ==========================================
local function check_hero_access(context, payload)
    local ok, json = pcall(nk.json_decode, payload)
    if not ok or type(json) ~= "table" then
        return nk.json_encode({ accessible = false, error = "参数错误" })
    end
    local user_id = context.user_id
    local hero_id = json.hero_id

    if not rate_limiter.check(nk, user_id, "check_hero_access", 60, 60) then
        return nk.json_encode({ success = false, error = "too_many_requests" })
    end
    if not catalog.HEROES[hero_id] then
        return nk.json_encode({ accessible = false, error = "英雄不存在" })
    end

    local objects = nk.storage_read({{
        collection = "hero_inventory",
        key        = "unlocked_heroes",
        user_id    = user_id
    }})
    local inventory = (#objects > 0) and objects[1].value or {}

    return nk.json_encode({ accessible = is_hero_accessible(hero_id, inventory, load_free_events()) })
end
nk.register_rpc(safe_rpc(check_hero_access), "check_hero_access")

-- ==========================================
-- 商店列表（含玩家解锁状态）
-- ==========================================
local function get_hero_shop(context, payload)
    local user_id = context.user_id

    if not rate_limiter.check(nk, user_id, "get_hero_shop", 60, 60) then
        return nk.json_encode({ success = false, error = "too_many_requests" })
    end
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
nk.register_rpc(safe_rpc(get_hero_shop), "get_hero_shop")

-- ==========================================
-- 统一商城：英雄 + 皮肤一次返回
-- 客户端按 category 字段分类展示，购买仍走各自 RPC
-- ==========================================
local function get_shop(context, payload)
    local user_id = context.user_id

    if not rate_limiter.check(nk, user_id, "get_shop", 60, 60) then
        return nk.json_encode({ success = false, error = "too_many_requests" })
    end
    -- 批量读取英雄库存 + 皮肤库存（单次 RTT）
    local objects = nk.storage_read({
        { collection = "hero_inventory", key = "unlocked_heroes", user_id = user_id },
        { collection = "skin_inventory", key = "owned_skins",     user_id = user_id },
    })
    local hero_inventory, owned_skins = {}, {}
    for _, obj in ipairs(objects) do
        if obj.key == "unlocked_heroes" then hero_inventory = obj.value end
        if obj.key == "owned_skins"     then owned_skins    = obj.value end
    end

    -- 把 owned_skins 数组转成 set，方便 O(1) 查询
    local owned_skin_set = {}
    for _, sid in ipairs(owned_skins) do owned_skin_set[sid] = true end

    local free_events    = load_free_events()
    local price_override = gconfig.load(nk).hero_price_overrides

    -- 英雄商品
    local hero_items = {}
    for id, info in pairs(catalog.HEROES) do
        local ev              = free_events[id]
        local now             = os.time()
        local is_free_event   = ev and now >= ev.start_time and now <= ev.end_time
        local effective_price = price_override[id] or info.price
        table.insert(hero_items, {
            category   = "hero",
            id         = id,
            name       = info.name,
            price      = effective_price,
            tier       = info.tier,
            description = info.description,
            owned      = is_hero_accessible(id, hero_inventory, free_events),
            free_until = is_free_event and ev.end_time or nil,
            buy_rpc    = "buy_hero",      -- 客户端购买时调用的 RPC 名
        })
    end
    table.sort(hero_items, function(a, b)
        if a.tier ~= b.tier then return a.tier < b.tier end
        return a.name < b.name
    end)

    -- 皮肤商品（不含默认皮肤）
    local skin_items = {}
    for skin_id, info in pairs(skin_catalog.SKINS) do
        if not info.is_default then
            table.insert(skin_items, {
                category  = "skin",
                id        = skin_id,
                hero_id   = info.hero_id,
                name      = info.name_cn,
                price     = info.price,
                asset_url = info.asset_url,
                owned     = owned_skin_set[skin_id] == true,
                buy_rpc   = "purchase_skin",  -- 客户端购买时调用的 RPC 名
            })
        end
    end
    table.sort(skin_items, function(a, b)
        if a.hero_id ~= b.hero_id then return a.hero_id < b.hero_id end
        return a.price < b.price
    end)

    return nk.json_encode({ items = hero_items, skins = skin_items })
end
nk.register_rpc(safe_rpc(get_shop), "get_shop")

-- ==========================================
-- 余额查询
-- ==========================================
local function get_wallet(context, payload)
    local uid = context.user_id
    if not rate_limiter.check(nk, uid, "get_wallet", 60, 60) then
        return nk.json_encode({ success = false, error = "too_many_requests" })
    end
    local account = nk.account_get_id(uid)
    local raw     = account and account.wallet or {}
    local wallet  = type(raw) == "string" and nk.json_decode(raw) or raw
    return nk.json_encode({ gold = wallet.gold or 0 })
end
nk.register_rpc(safe_rpc(get_wallet), "get_wallet")

-- ==========================================
-- 购买英雄
-- ==========================================
local function buy_hero(context, payload)
    local json    = (payload and payload ~= "") and nk.json_decode(payload) or nil
    if type(json) ~= "table" or type(json.hero_id) ~= "string" then
        return nk.json_encode({ success = false, error = "bad_request" })
    end
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

    if not rate_limiter.check(nk, user_id, "buy_hero", 10, 60) then
        return nk.json_encode({ success = false, error = "too_many_requests" })
    end

    -- 检查是否已拥有（避免重复扣款），同时记录 version 用于 OCC 写入
    local objects = nk.storage_read({{
        collection = "hero_inventory",
        key        = "unlocked_heroes",
        user_id    = user_id
    }})
    local inv_version = (#objects > 0) and objects[1].version or "*"
    local inventory   = (#objects > 0) and objects[1].value   or {}
    if inventory[hero_id] then
        return nk.json_encode({ success = false, error = "already_owned" })
    end

    -- 原子扣款：金币不足时 wallet_update 抛出异常
    local ok = pcall(nk.wallet_update, user_id, { gold = -price }, {}, true)
    if not ok then
        return nk.json_encode({ success = false, error = "insufficient_gold" })
    end

    inventory[hero_id] = true
    -- OCC 写入：version 不匹配说明并发写入，回滚金币并返回冲突
    local ok2 = pcall(nk.storage_write, {{
        collection       = "hero_inventory",
        key              = "unlocked_heroes",
        user_id          = user_id,
        value            = inventory,
        version          = inv_version,
        permission_read  = 1,
        permission_write = 0,
    }})
    if not ok2 then
        pcall(nk.wallet_update, user_id, { gold = price }, {}, true)
        return nk.json_encode({ success = false, error = "conflict_retry" })
    end

    return nk.json_encode({ success = true })
end
nk.register_rpc(safe_rpc(buy_hero), "buy_hero")

-- ==========================================
-- 管理员充值（仅限服务端 HTTP Key 调用）
-- 客户端调用时 context.user_id 非空，会被拒绝
-- ==========================================
local function admin_grant_gold(context, payload)
    local is_admin = (context.env and context.env["__nakama_admin"] == "true")
        or not context.user_id or context.user_id == ""
    if not is_admin then
        return nk.json_encode({ success = false, error = "需要管理员权限" })
    end

    local json   = nk.json_decode(payload)
    local target = json.user_id
    local amount = tonumber(json.amount)

    if type(target) ~= "string" or not amount or amount <= 0 then
        return nk.json_encode({ success = false, error = "参数无效：需要 user_id 和正整数 amount" })
    end

    local ok, wallet_err = pcall(nk.wallet_update, target, { gold = amount }, { reason = "admin_grant" }, true)
    if not ok then
        return nk.json_encode({ success = false, error = "wallet_update 失败: " .. tostring(wallet_err) })
    end

    local account = nk.account_get_id(target)
    local raw     = account and account.wallet or {}
    local wallet  = type(raw) == "string" and nk.json_decode(raw) or raw

    return nk.json_encode({ success = true, new_balance = wallet.gold or 0 })
end
nk.register_rpc(safe_rpc(admin_grant_gold), "admin_grant_gold")

-- ==========================================
-- 管理员设置限时免费活动（仅限服务端调用）
-- payload: { "heroes": ["hakim","hulagu"], "start_time": 1746000000, "end_time": 1746604800 }
-- ==========================================
local function admin_set_free_event(context, payload)
    local is_admin = (context.env and context.env["__nakama_admin"] == "true")
        or not context.user_id or context.user_id == ""
    if not is_admin then
        return nk.json_encode({ success = false, error = "需要管理员权限" })
    end

    local json       = nk.json_decode(payload)
    local hero_ids   = json.heroes
    local start_time = tonumber(json.start_time)
    local end_time   = tonumber(json.end_time)

    if type(hero_ids) ~= "table" or not start_time or not end_time or start_time >= end_time then
        return nk.json_encode({ success = false, error = "参数无效" })
    end

    -- 读取现有活动数据，合并写入（支持多个独立活动并存）
    local objects = nk.storage_read({{
        collection = "events", key = "free_heroes", user_id = nil
    }})
    local events = (#objects > 0) and objects[1].value or {}

    for _, hid in ipairs(hero_ids) do
        if type(hid) == "string" and catalog.HEROES[hid] then
            events[hid] = { start_time = start_time, end_time = end_time }
        end
    end

    pcall(nk.storage_write, {{
        collection       = "events",
        key              = "free_heroes",
        user_id          = nil,
        value            = events,
        version          = (#objects > 0) and objects[1].version or "*",
        permission_read  = 2,  -- 所有人可读（客户端可查询活动列表）
        permission_write = 0,
    }})

    return nk.json_encode({ success = true, active_events = events })
end
nk.register_rpc(safe_rpc(admin_set_free_event), "admin_set_free_event")

-- ==========================================
-- 查询当前有效配置（公开，供客户端了解游戏参数）
-- ==========================================
local function get_config(context, payload)
    local cfg = gconfig.load(nk)
    return nk.json_encode({ config = cfg })
end
nk.register_rpc(safe_rpc(get_config), "get_config")

-- ==========================================
-- 管理员更新游戏配置（仅限服务端调用）
-- 支持深度部分更新，示例：
--   {"match":{"turn_timeout":60}}
--   {"hero_price_overrides":{"hakim":300}}
--   {"combat":{"rebel_kill_reward":5},"hero_price_overrides":{"hulagu":800}}
-- ==========================================
local function admin_set_config(context, payload)
    local is_admin = (context.env and context.env["__nakama_admin"] == "true")
        or not context.user_id or context.user_id == ""
    if not is_admin then
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
        version          = (#objects > 0) and objects[1].version or "*",
        permission_read  = 2,
        permission_write = 0,
    }})

    -- 返回合并 DEFAULTS 后的完整有效配置，便于确认
    local effective = gconfig.load(nk)
    return nk.json_encode({ success = true, effective_config = effective })
end
nk.register_rpc(safe_rpc(admin_set_config), "admin_set_config")

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
nk.register_rpc(safe_rpc(get_season_info), "get_season_info")

-- ==========================================
-- 查询当前玩家本赛季统计
-- ==========================================
local function get_my_stats(context, payload)
    local user_id = context.user_id
    if not rate_limiter.check(nk, user_id, "get_my_stats", 60, 60) then
        return nk.json_encode({ success = false, error = "too_many_requests" })
    end
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
nk.register_rpc(safe_rpc(get_my_stats), "get_my_stats")

-- ==========================================
-- 查询对局历史（玩家自身）
-- payload: { "season_id": "2026_Q2" }  可选，默认当前赛季
-- ==========================================
local function get_match_history(context, payload)
    local user_id  = context.user_id
    if not rate_limiter.check(nk, user_id, "get_match_history", 60, 60) then
        return nk.json_encode({ success = false, error = "too_many_requests" })
    end
    local json     = (payload and payload ~= "") and nk.json_decode(payload) or {}
    local season   = season_mgr.get_current_season(nk)
    local sid      = (json and json.season_id) or (season and season.season_id)
    if not sid then
        return nk.json_encode({ error = "请指定 season_id 或先开启赛季" })
    end

    -- cursor 翻页取全量（season_manager 已裁剪至 50 条，翻页保证不遗漏边界数据）
    local all_items = {}
    local cursor = ""
    local max_iter, iter = 20, 0
    repeat
        iter = iter + 1
        if iter > max_iter then break end
        local page, next_cursor = nk.storage_list(user_id, "match_history", 100, cursor)
        if page then
            for _, item in ipairs(page) do
                table.insert(all_items, item)
            end
        end
        cursor = next_cursor or ""
    until cursor == ""

    local records = {}
    for _, item in ipairs(all_items) do
        if item.value and item.value.season_id == sid then
            table.insert(records, item.value)
        end
    end
    -- 按时间倒序，最多返回 50 条
    table.sort(records, function(a, b) return (a.timestamp or 0) > (b.timestamp or 0) end)
    if #records > 50 then
        local trimmed = {}
        for i = 1, 50 do trimmed[i] = records[i] end
        records = trimmed
    end
    return nk.json_encode({ season_id = sid, records = records })
end
nk.register_rpc(safe_rpc(get_match_history), "get_match_history")

-- ==========================================
-- 赛季排行榜（公开）
-- payload: { "limit": 20 }
-- ==========================================
local function get_leaderboard(context, payload)
    if not rate_limiter.check(nk, context.user_id, "get_leaderboard", 60, 60) then
        return nk.json_encode({ success = false, error = "too_many_requests" })
    end
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
nk.register_rpc(safe_rpc(get_leaderboard), "get_leaderboard")

-- ==========================================
-- 管理员开启新赛季（仅服务端调用）
-- payload: { "name":"2026年第二赛季", "start_time":1746057600, "end_time":1753833600 }
-- ==========================================
local function admin_start_season(context, payload)
    local is_admin = (context.env and context.env["__nakama_admin"] == "true")
        or not context.user_id or context.user_id == ""
    if not is_admin then
        return nk.json_encode({ success = false, error = "需要管理员权限" })
    end

    local json       = nk.json_decode(payload)
    local name       = json.name
    local start_time = tonumber(json.start_time)
    local end_time   = tonumber(json.end_time)

    if type(name) ~= "string" or #name > 100 or not start_time or not end_time or start_time >= end_time then
        return nk.json_encode({ success = false, error = "参数无效：需要 name, start_time, end_time" })
    end

    -- 按 start_time 生成赛季 ID（格式 YYYY_QN）
    local t = os.date("*t", start_time)
    local q = math.ceil(t.month / 3)
    local season_id = string.format("%d_Q%d", t.year, q)
    local lb_id     = "season_" .. season_id

    -- 检查该季度是否已有进行中的赛季
    local current = season_mgr.get_current_season(nk)
    if current and current.season_id == season_id then
        return nk.json_encode({ success = false, error = "该季度已有进行中的赛季" })
    end

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
nk.register_rpc(safe_rpc(admin_start_season), "admin_start_season")

-- ==========================================
-- 管理员结束当前赛季（仅服务端调用）
-- ==========================================
local function admin_end_season(context, payload)
    local is_admin = (context.env and context.env["__nakama_admin"] == "true")
        or not context.user_id or context.user_id == ""
    if not is_admin then
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
nk.register_rpc(safe_rpc(admin_end_season), "admin_end_season")

-- ==========================================
-- 好友系统
-- ==========================================

-- 发送好友请求 / 接受请求（Nakama 双向调用自动升为好友）
-- payload: {"username":"xxx"} 或 {"user_id":"xxx"}
local function add_friend(context, payload)
    if not rate_limiter.check(nk, context.user_id, "add_friend", 20, 60) then
        return nk.json_encode({ success = false, error = "too_many_requests" })
    end
    local json = nk.json_decode(payload)
    if not json or (not json.username and not json.user_id) then
        return nk.json_encode({ success = false, error = "需要 username 或 user_id" })
    end
    local user_ids  = json.user_id  and { json.user_id  } or {}
    local usernames = json.username and { json.username } or {}
    nk.friends_add(context.user_id, user_ids, usernames)
    return nk.json_encode({ success = true })
end
nk.register_rpc(safe_rpc(add_friend), "add_friend")

-- 删除好友 / 拒绝请求
-- payload: {"user_id":"xxx"}
local function remove_friend(context, payload)
    if not rate_limiter.check(nk, context.user_id, "remove_friend", 20, 60) then
        return nk.json_encode({ success = false, error = "too_many_requests" })
    end
    local json = nk.json_decode(payload)
    if not json or not json.user_id then
        return nk.json_encode({ success = false, error = "需要 user_id" })
    end
    nk.friends_delete(context.user_id, { json.user_id }, {})
    return nk.json_encode({ success = true })
end
nk.register_rpc(safe_rpc(remove_friend), "remove_friend")

-- 屏蔽用户
-- payload: {"user_id":"xxx"}
local function block_user(context, payload)
    if not rate_limiter.check(nk, context.user_id, "block_user", 20, 60) then
        return nk.json_encode({ success = false, error = "too_many_requests" })
    end
    local json = nk.json_decode(payload)
    if not json or not json.user_id then
        return nk.json_encode({ success = false, error = "需要 user_id" })
    end
    nk.friends_block(context.user_id, { json.user_id }, {})
    return nk.json_encode({ success = true })
end
nk.register_rpc(safe_rpc(block_user), "block_user")

-- 查询好友列表 / 请求列表
-- payload: {"state":0}  0=好友 1=已发请求 2=收到请求 3=已屏蔽，不传则返回全部
local function get_friends(context, payload)
    if not rate_limiter.check(nk, context.user_id, "get_friends", 20, 60) then
        return nk.json_encode({ success = false, error = "too_many_requests" })
    end
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
nk.register_rpc(safe_rpc(get_friends), "get_friends")

-- 邀请好友加入对局（通过 Nakama 通知推送，非持久化）
-- payload: {"user_id":"xxx","match_id":"yyy"}
local function invite_to_match(context, payload)
    if not rate_limiter.check(nk, context.user_id, "invite_to_match", 10, 60) then
        return nk.json_encode({ success = false, error = "too_many_requests" })
    end

    local json     = nk.json_decode(payload)
    local target   = json and json.user_id
    local match_id = json and json.match_id
    if type(target) ~= "string" or type(match_id) ~= "string" or #match_id ~= 36 then
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
nk.register_rpc(safe_rpc(invite_to_match), "invite_to_match")

-- ==========================================
-- 查询好友在线状态（含当前对局信息）
-- 出参：{ friends: [{ user_id, username, status, match_id, mode,
--                     current_players, max_players }] }
-- status: "idle"=空闲  "waiting"=等待中可加入  "playing"=游戏中可观战
-- ==========================================
local function get_friends_status(context, payload)
    if not rate_limiter.check(nk, context.user_id, "get_friends_status", 20, 60) then
        return nk.json_encode({ success = false, error = "too_many_requests" })
    end
    local friends_list, _, _ = nk.friends_list(context.user_id, 100, 0, "")
    if not friends_list or #friends_list == 0 then
        return nk.json_encode({ friends = {} })
    end

    -- 批量读取所有好友的在线状态（单次 storage 请求）
    local reads = {}
    for _, f in ipairs(friends_list) do
        table.insert(reads, {
            collection = "user_status",
            key        = "current_match",
            user_id    = f.user.id,
        })
    end
    local objects = nk.storage_read(reads)

    local status_map = {}
    for _, obj in ipairs(objects) do
        status_map[obj.user_id] = obj.value
    end

    local result = {}
    for _, f in ipairs(friends_list) do
        local uid = f.user.id
        local s   = status_map[uid]
        table.insert(result, {
            user_id         = uid,
            username        = f.user.username,
            status          = s and s.status or "idle",
            match_id        = s and s.match_id or nil,
            mode            = s and s.mode or nil,
            current_players = s and s.current_players or nil,
            max_players     = s and s.max_players or nil,
        })
    end

    return nk.json_encode({ friends = result })
end
nk.register_rpc(safe_rpc(get_friends_status), "get_friends_status")

-- ==========================================
-- 观战：查询当前可观战的对局列表
-- payload: {"mode":"pvp"} 可选，不传则返回全部模式
-- ==========================================

local function find_spectatable_match(context, payload)
    if not rate_limiter.check(nk, context.user_id, "find_spectatable_match", 30, 60) then
        return nk.json_encode({ success = false, error = "too_many_requests" })
    end
    local json  = nk.json_decode(payload)
    local mode  = json and json.mode
    local query = "+label.spectatable:1"
    if mode then
        if not VALID_MODES[mode] then
            return nk.json_encode({ success = false, error = "invalid_mode" })
        end
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
nk.register_rpc(safe_rpc(find_spectatable_match), "find_spectatable_match")

-- ==========================================
-- 成就 RPC
-- ==========================================

-- 返回玩家已解锁的成就列表（含解锁时间）
local function get_my_achievements(context, payload)
    if not rate_limiter.check(nk, context.user_id, "get_my_achievements", 60, 60) then
        return nk.json_encode({ success = false, error = "too_many_requests" })
    end
    local objects = nk.storage_read({{
        collection = "achievements",
        key        = "unlocked",
        user_id    = context.user_id,
    }})
    local unlocked = (#objects > 0) and objects[1].value or {}
    return nk.json_encode({ unlocked = unlocked })
end
nk.register_rpc(safe_rpc(get_my_achievements), "get_my_achievements")

-- 返回全部成就定义，并标注玩家已解锁状态
local function get_achievement_list(context, payload)
    if not rate_limiter.check(nk, context.user_id, "get_achievement_list", 60, 60) then
        return nk.json_encode({ success = false, error = "too_many_requests" })
    end
    local defs = ach_mgr.get_all_definitions()

    local objects = nk.storage_read({{
        collection = "achievements",
        key        = "unlocked",
        user_id    = context.user_id,
    }})
    local unlocked = (#objects > 0) and objects[1].value or {}

    -- 为每条定义附加解锁状态
    for _, d in ipairs(defs) do
        local info = unlocked[d.id]
        if info then
            d.unlocked    = true
            d.unlocked_at = info.unlocked_at
            if info.heroes then d.heroes = info.heroes end
        else
            d.unlocked = false
        end
    end

    return nk.json_encode({ achievements = defs })
end
nk.register_rpc(safe_rpc(get_achievement_list), "get_achievement_list")

-- ==========================================
-- 皮肤系统 RPC
-- ==========================================

-- 金币充值档位：product_id → gold 数量
local PRODUCT_MAP = {
    ["com.asura.gold_60"]   = 60,
    ["com.asura.gold_198"]  = 198,
    ["com.asura.gold_648"]  = 648,
    ["com.asura.gold_1998"] = 1998,
}

-- 内部：调用 Apple IAP 验证接口
-- 先请求 Production，status=21007 时降级 Sandbox（审核环境）
local function verify_apple_receipt(receipt_data, context)
    local secret = context and context.env and context.env["APPLE_IAP_SECRET"] or ""
    if secret == "" then
        nk.logger_warn("APPLE_IAP_SECRET 未配置，IAP 验证将失败")
        return nil, "iap_secret_not_configured"
    end
    local body   = nk.json_encode({ ["receipt-data"] = receipt_data, password = secret })
    local headers = { ["Content-Type"] = "application/json" }

    local function call(url)
        local code, _, resp_body = nk.http_request(url, "POST", headers, body)
        if code ~= 200 then return nil, "http_error_" .. tostring(code) end
        return nk.json_decode(resp_body), nil
    end

    local resp, err = call("https://buy.itunes.apple.com/verifyReceipt")
    if err then return nil, err end

    -- 21007: receipt 是 Sandbox 签发，降级重试
    if resp.status == 21007 then
        resp, err = call("https://sandbox.itunes.apple.com/verifyReceipt")
        if err then return nil, err end
        resp._env = "sandbox"
    else
        resp._env = "production"
    end

    if resp.status ~= 0 then
        return nil, "invalid_receipt_status_" .. tostring(resp.status)
    end

    -- 取 in_app 列表中 purchase_date_ms 最大的那笔
    local in_app = resp.receipt and resp.receipt.in_app or {}
    if #in_app == 0 then return nil, "no_in_app_purchase" end

    local latest = in_app[1]
    for _, item in ipairs(in_app) do
        if tonumber(item.purchase_date_ms or 0) > tonumber(latest.purchase_date_ms or 0) then
            latest = item
        end
    end

    return {
        transaction_id = latest.transaction_id,
        product_id     = latest.product_id,
        environment    = resp._env,
    }, nil
end

-- RPC：verify_iap_receipt
-- 入参：{ product_id, receipt_data }
-- 出参：{ success, gold_granted, new_balance } 或 { success=false, error }
local function verify_iap_receipt(context, payload)
    local req = nk.json_decode(payload)
    if type(req) ~= "table" then
        return nk.json_encode({ success = false, error = "bad_request" })
    end

    local product_id  = req.product_id
    local receipt_data = req.receipt_data
    local gold = PRODUCT_MAP[product_id]
    if not gold then
        return nk.json_encode({ success = false, error = "unknown_product" })
    end

    if not rate_limiter.check(nk, context.user_id, "iap_verify", 5, 60) then
        return nk.json_encode({ success = false, error = "too_many_requests" })
    end

    local result, err = verify_apple_receipt(receipt_data, context)
    if not result then
        return nk.json_encode({ success = false, error = err or "invalid_receipt" })
    end

    local txn_id = result.transaction_id
    if not txn_id then
        return nk.json_encode({ success = false, error = "missing_transaction_id" })
    end

    -- 防重放：OCC insert-only（version="*" 仅在记录不存在时写入，原子性声明）
    local ok_ar = pcall(nk.storage_write, {{
        collection       = "iap_receipts",
        key              = txn_id,
        user_id          = nil,
        value            = {
            uid          = context.user_id,
            product_id   = product_id,
            gold_granted = gold,
            verified_at  = os.time(),
            environment  = result.environment,
        },
        version          = "*",
        permission_read  = 0,
        permission_write = 0,
    }})
    if not ok_ar then
        return nk.json_encode({ success = false, error = "duplicate_transaction" })
    end

    -- 防重放成功后才放行金币（wallet_update 重试 3 次，瞬态失败不影响防重放）
    local ok, wallet_err
    for _ = 1, 3 do
        ok, wallet_err = pcall(nk.wallet_update, context.user_id,
            { gold = gold }, { reason = "iap", product_id = product_id }, true)
        if ok then break end
    end
    if not ok then
        nk.logger_warn("IAP wallet_update 失败 txn=" .. txn_id .. " err=" .. tostring(wallet_err) .. "（收据已记录，联系管理员补发）")
        return nk.json_encode({ success = false, error = "wallet_error" })
    end

    -- 写 per-user 充值历史（供 get_iap_history 查询）
    pcall(nk.storage_write, {{
        collection       = "iap_history",
        key              = txn_id,
        user_id          = context.user_id,
        value            = {
            transaction_id = txn_id,
            product_id     = product_id,
            gold_granted   = gold,
            verified_at    = os.time(),
            environment    = result.environment,
        },
        permission_read  = 1,
        permission_write = 0,
    }})

    local account = nk.account_get_id(context.user_id)
    local balance = account and account.wallet and (account.wallet.gold or 0) or 0
    return nk.json_encode({ success = true, gold_granted = gold, new_balance = balance })
end
nk.register_rpc(safe_rpc(verify_iap_receipt), "verify_iap_receipt")

-- ==========================================
-- Google Play IAP
-- ==========================================

-- 内部：从 Storage 读取缓存的 Google OAuth access token
local function get_google_access_token(context)
    local env = context and context.env or {}
    local client_id     = env["GOOGLE_CLIENT_ID"]     or ""
    local client_secret = env["GOOGLE_CLIENT_SECRET"] or ""
    local refresh_token = env["GOOGLE_REFRESH_TOKEN"] or ""

    if client_id == "" or client_secret == "" or refresh_token == "" then
        return nil, "google_credentials_not_configured"
    end

    -- 尝试使用缓存 token（存于全局 Storage，key=google_token）
    local cached_list = nk.storage_read({{ collection="system_config", key="google_token", user_id=nil }})
    if cached_list and #cached_list > 0 then
        local t = cached_list[1].value
        if t and t.access_token and t.expires_at and os.time() < t.expires_at - 60 then
            return t.access_token, nil
        end
    end

    -- token 过期或不存在：用 refresh_token 换取新 access_token
    local body = table.concat({
        "client_id=" .. client_id,
        "client_secret=" .. client_secret,
        "refresh_token=" .. refresh_token,
        "grant_type=refresh_token",
    }, "&")
    local code, _, resp_body = nk.http_request(
        "https://oauth2.googleapis.com/token", "POST",
        { ["Content-Type"] = "application/x-www-form-urlencoded" }, body)

    if code ~= 200 then
        return nil, "google_token_refresh_failed_" .. tostring(code)
    end
    local resp = nk.json_decode(resp_body)
    if not resp or not resp.access_token then
        return nil, "google_token_parse_error"
    end

    local new_token = {
        access_token = resp.access_token,
        expires_at   = os.time() + (resp.expires_in or 3600),
    }
    pcall(nk.storage_write, {{
        collection       = "system_config",
        key              = "google_token",
        user_id          = nil,
        value            = new_token,
        permission_read  = 0,
        permission_write = 0,
    }})
    return new_token.access_token, nil
end

-- 内部：通过 Google Play Developer API 验证购买凭据
local GOOGLE_PACKAGE_NAME = "com.asura.game"
local function verify_google_purchase(product_id, purchase_token, context)
    local access_token, err = get_google_access_token(context)
    if not access_token then
        return nil, err
    end

    local url = string.format(
        "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/%s/purchases/products/%s/tokens/%s",
        GOOGLE_PACKAGE_NAME, product_id, purchase_token)

    local code, _, resp_body = nk.http_request(url, "GET",
        { ["Authorization"] = "Bearer " .. access_token }, nil)

    if code == 401 then
        -- token 可能过期，清除缓存，单次重试
        pcall(nk.storage_delete, {{ collection="system_config", key="google_token", user_id=nil }})
        access_token, err = get_google_access_token(context)
        if not access_token then return nil, err end
        code, _, resp_body = nk.http_request(url, "GET",
            { ["Authorization"] = "Bearer " .. access_token }, nil)
    end

    if code ~= 200 then
        return nil, "google_api_error_" .. tostring(code)
    end

    local resp = nk.json_decode(resp_body)
    if not resp then return nil, "google_response_parse_error" end

    -- purchaseState: 0=purchased, 1=cancelled, 2=pending
    if resp.purchaseState ~= 0 then
        return nil, "purchase_not_completed"
    end

    -- orderId 作为全局唯一交易 ID
    local order_id = resp.orderId
    if not order_id or order_id == "" then
        return nil, "missing_order_id"
    end

    return {
        transaction_id = order_id,
        product_id     = product_id,
        -- purchaseType: 0=sandbox/test, nil=production (field absent), 1=promo code (treated as production)
        environment    = (resp.purchaseType == 0) and "sandbox" or "production",
    }, nil
end

-- RPC：verify_google_iap_receipt
-- 入参：{ product_id, purchase_token }
-- 出参：{ success, gold_granted, new_balance } 或 { success=false, error }
local function verify_google_iap_receipt(context, payload)
    local req = nk.json_decode(payload)
    if type(req) ~= "table" then
        return nk.json_encode({ success = false, error = "bad_request" })
    end

    local product_id     = req.product_id
    local purchase_token = req.purchase_token
    local gold = PRODUCT_MAP[product_id]
    if not gold then
        return nk.json_encode({ success = false, error = "unknown_product" })
    end
    if type(purchase_token) ~= "string" or purchase_token == "" then
        return nk.json_encode({ success = false, error = "bad_request" })
    end

    if not rate_limiter.check(nk, context.user_id, "iap_verify", 5, 60) then
        return nk.json_encode({ success = false, error = "too_many_requests" })
    end

    local result, err = verify_google_purchase(product_id, purchase_token, context)
    if not result then
        return nk.json_encode({ success = false, error = err or "invalid_receipt" })
    end

    local txn_id = result.transaction_id

    -- 防重放：OCC insert-only（与 Apple IAP 共用同一个 iap_receipts collection，先写防重放）
    local ok_ar = pcall(nk.storage_write, {{
        collection       = "iap_receipts",
        key              = txn_id,
        user_id          = nil,
        value            = {
            uid          = context.user_id,
            product_id   = product_id,
            gold_granted = gold,
            verified_at  = os.time(),
            environment  = result.environment,
            platform     = "android",
        },
        version          = "*",
        permission_read  = 0,
        permission_write = 0,
    }})
    if not ok_ar then
        return nk.json_encode({ success = false, error = "duplicate_transaction" })
    end

    -- 防重放成功后才放行金币（wallet_update 重试 3 次）
    local ok, wallet_err
    for _ = 1, 3 do
        ok, wallet_err = pcall(nk.wallet_update, context.user_id,
            { gold = gold }, { reason = "iap", product_id = product_id }, true)
        if ok then break end
    end
    if not ok then
        nk.logger_warn("Google IAP wallet_update 失败 txn=" .. txn_id .. " err=" .. tostring(wallet_err) .. "（收据已记录，联系管理员补发）")
        return nk.json_encode({ success = false, error = "wallet_error" })
    end

    pcall(nk.storage_write, {{
        collection       = "iap_history",
        key              = txn_id,
        user_id          = context.user_id,
        value            = {
            transaction_id = txn_id,
            product_id     = product_id,
            gold_granted   = gold,
            verified_at    = os.time(),
            environment    = result.environment,
            platform       = "android",
        },
        permission_read  = 1,
        permission_write = 0,
    }})

    local account = nk.account_get_id(context.user_id)
    local balance = account and account.wallet and (account.wallet.gold or 0) or 0
    return nk.json_encode({ success = true, gold_granted = gold, new_balance = balance })
end
nk.register_rpc(safe_rpc(verify_google_iap_receipt), "verify_google_iap_receipt")

-- RPC：admin_refresh_google_token（管理员强制刷新 Google OAuth token 缓存）
local function admin_refresh_google_token(context, _payload)
    -- Nakama 标准管理员检查：控制台 → __nakama_admin; HTTP API key → user_id=nil
    local is_admin = (context.env and context.env["__nakama_admin"] == "true")
        or not context.user_id or context.user_id == ""
    if not is_admin then
        return nk.json_encode({ success = false, error = "需要管理员权限" })
    end
    pcall(nk.storage_delete, {{ collection="system_config", key="google_token", user_id=nil }})
    local token, err = get_google_access_token(context)
    if token then
        return nk.json_encode({ success = true })
    else
        return nk.json_encode({ success = false, error = err })
    end
end
nk.register_rpc(safe_rpc(admin_refresh_google_token), "admin_refresh_google_token")

-- RPC：get_skin_catalog
-- 入参：{} 或 { hero_id }（可选过滤）
-- 出参：{ skins: [...] }（不含默认皮肤）
local function get_skin_catalog(context, payload)
    if not rate_limiter.check(nk, context.user_id, "get_skin_catalog", 60, 60) then
        return nk.json_encode({ success = false, error = "too_many_requests" })
    end
    local req = (payload and payload ~= "") and nk.json_decode(payload) or {}
    local filter_hero = type(req) == "table" and req.hero_id or nil

    local result = {}
    for skin_id, info in pairs(skin_catalog.SKINS) do
        if not info.is_default then
            if not filter_hero or info.hero_id == filter_hero then
                table.insert(result, {
                    id        = skin_id,
                    hero_id   = info.hero_id,
                    name_cn   = info.name_cn,
                    price     = info.price,
                    asset_url = info.asset_url,
                })
            end
        end
    end
    return nk.json_encode({ skins = result })
end
nk.register_rpc(safe_rpc(get_skin_catalog), "get_skin_catalog")

-- RPC：get_my_skins
-- 出参：{ owned:[skin_id,...], equipped:{hero_id:skin_id,...} }
local function get_my_skins(context, payload)
    local uid = context.user_id
    if not rate_limiter.check(nk, uid, "get_my_skins", 60, 60) then
        return nk.json_encode({ success = false, error = "too_many_requests" })
    end
    local objects = nk.storage_read({
        { collection = "skin_inventory", key = "owned_skins",    user_id = uid },
        { collection = "skin_inventory", key = "equipped_skins", user_id = uid },
    })
    local owned, equipped = {}, {}
    for _, obj in ipairs(objects) do
        if obj.key == "owned_skins"    then owned    = obj.value end
        if obj.key == "equipped_skins" then equipped = obj.value end
    end
    return nk.json_encode({ owned = owned, equipped = equipped })
end
nk.register_rpc(safe_rpc(get_my_skins), "get_my_skins")

-- RPC：purchase_skin
-- 入参：{ skin_id }
-- 出参：{ success, new_balance } 或 { success=false, error }
local function purchase_skin(context, payload)
    local req = nk.json_decode(payload)
    if type(req) ~= "table" or not req.skin_id then
        return nk.json_encode({ success = false, error = "bad_request" })
    end

    local skin_id = req.skin_id
    local uid     = context.user_id

    if not skin_catalog.exists(skin_id) then
        return nk.json_encode({ success = false, error = "skin_not_found" })
    end
    local info = skin_catalog.SKINS[skin_id]
    if info.is_default then
        return nk.json_encode({ success = false, error = "default_skin" })
    end

    if not rate_limiter.check(nk, uid, "purchase_skin", 10, 60) then
        return nk.json_encode({ success = false, error = "too_many_requests" })
    end

    -- 读取已拥有皮肤，同时记录 version 用于 OCC 写入
    local objects = nk.storage_read({{
        collection = "skin_inventory", key = "owned_skins", user_id = uid
    }})
    local owned_ver = (#objects > 0) and objects[1].version or "*"
    local owned     = (#objects > 0) and objects[1].value   or {}

    -- 检查是否已拥有（数组转 set 避免 O(n) 线性扫描）
    local owned_set = {}
    for _, s in ipairs(owned) do owned_set[s] = true end
    if owned_set[skin_id] then
        return nk.json_encode({ success = false, error = "already_owned" })
    end

    -- 扣金币
    local ok = pcall(nk.wallet_update, uid, { gold = -info.price }, {}, true)
    if not ok then
        return nk.json_encode({ success = false, error = "insufficient_gold" })
    end

    -- OCC 写入：version 不匹配说明并发购买，回滚金币
    table.insert(owned, skin_id)
    local ok2 = pcall(nk.storage_write, {{
        collection       = "skin_inventory",
        key              = "owned_skins",
        user_id          = uid,
        value            = owned,
        version          = owned_ver,
        permission_read  = 1,
        permission_write = 0,
    }})
    if not ok2 then
        pcall(nk.wallet_update, uid, { gold = info.price }, {}, true)
        return nk.json_encode({ success = false, error = "conflict_retry" })
    end

    local account = nk.account_get_id(uid)
    local balance = account and account.wallet and (account.wallet.gold or 0) or 0
    return nk.json_encode({ success = true, new_balance = balance })
end
nk.register_rpc(safe_rpc(purchase_skin), "purchase_skin")

-- RPC：equip_skin
-- 入参：{ hero_id, skin_id }（skin_id=nil 表示卸下皮肤，恢复默认）
-- 出参：{ success } 或 { success=false, error }
local function equip_skin(context, payload)
    if not rate_limiter.check(nk, context.user_id, "equip_skin", 30, 60) then
        return nk.json_encode({ success = false, error = "too_many_requests" })
    end
    local req = nk.json_decode(payload)
    if type(req) ~= "table" or not req.hero_id then
        return nk.json_encode({ success = false, error = "bad_request" })
    end

    local hero_id = req.hero_id
    local skin_id = req.skin_id  -- nil 表示卸下
    local uid     = context.user_id

    if skin_id then
        if not skin_catalog.exists(skin_id) then
            return nk.json_encode({ success = false, error = "skin_not_found" })
        end
        local info = skin_catalog.SKINS[skin_id]
        if info.hero_id ~= hero_id then
            return nk.json_encode({ success = false, error = "wrong_hero" })
        end
        -- 默认皮肤无需拥有检查，其余皮肤须已购买
        if not info.is_default then
            local objects = nk.storage_read({{
                collection = "skin_inventory", key = "owned_skins", user_id = uid
            }})
            local owned = (#objects > 0) and objects[1].value or {}
            local has = false
            for _, s in ipairs(owned) do if s == skin_id then has = true; break end end
            if not has then
                return nk.json_encode({ success = false, error = "not_owned" })
            end
        end
    end

    -- 读取并更新装备表（OCC：携带 version 防并发写覆盖）
    local objects = nk.storage_read({{
        collection = "skin_inventory", key = "equipped_skins", user_id = uid
    }})
    local eq_rec  = (#objects > 0) and objects[1] or nil
    local equipped = eq_rec and eq_rec.value or {}
    local eq_ver   = eq_rec and eq_rec.version or nil

    if skin_id then
        equipped[hero_id] = skin_id
    else
        equipped[hero_id] = nil
    end

    local ok = pcall(nk.storage_write, {{
        collection       = "skin_inventory",
        key              = "equipped_skins",
        user_id          = uid,
        value            = equipped,
        version          = eq_ver,
        permission_read  = 1,
        permission_write = 0,
    }})
    if not ok then
        return nk.json_encode({ success = false, error = "conflict_retry" })
    end

    return nk.json_encode({ success = true })
end
nk.register_rpc(safe_rpc(equip_skin), "equip_skin")

-- ==========================================
-- RPC：get_iap_history
-- 返回当前用户所有 IAP 充值记录（按 verified_at 倒序）
-- ==========================================
local function get_iap_history(context, _payload)
    local uid = context.user_id
    if not rate_limiter.check(nk, uid, "get_iap_history", 60, 60) then
        return nk.json_encode({ success = false, error = "too_many_requests" })
    end
    local list = nk.storage_list(uid, "iap_history", 100, "")
    local records = {}
    if list then
        for _, obj in ipairs(list) do
            table.insert(records, obj.value)
        end
        table.sort(records, function(a, b)
            return (a.verified_at or 0) > (b.verified_at or 0)
        end)
    end
    return nk.json_encode({ records = records })
end
nk.register_rpc(safe_rpc(get_iap_history), "get_iap_history")

-- ==========================================
-- RPC：delete_account
-- 删除玩家所有游戏数据并注销 Nakama 账号（Apple/Google 审核要求）
-- iap_receipts（全局防重放记录）保留用于审计
-- ==========================================
local function delete_account(context, _payload)
    local uid = context.user_id

    -- 删除固定 key 的用户数据
    local fixed_keys = {
        { collection = "hero_inventory",  key = "unlocked_heroes" },
        { collection = "skin_inventory",  key = "owned_skins"     },
        { collection = "skin_inventory",  key = "equipped_skins"  },
        { collection = "achievements",    key = "unlocked"        },
        { collection = "user_status",     key = "current_match"   },
    }
    local to_delete = {}
    for _, item in ipairs(fixed_keys) do
        table.insert(to_delete, { collection = item.collection, key = item.key, user_id = uid })
    end
    pcall(nk.storage_delete, to_delete)

    -- 删除动态 key 的用户数据（cursor 翻页确保全量删除，满足 Apple/Google 账号注销要求）
    local dynamic_cols = { "season_stats", "match_history", "iap_history", "rate_limits" }
    for _, col in ipairs(dynamic_cols) do
        local cursor = ""
        local max_iter, iter = 50, 0
        repeat
            iter = iter + 1
            if iter > max_iter then break end
            local list, next_cursor = nk.storage_list(uid, col, 200, cursor)
            if list and #list > 0 then
                local batch = {}
                for _, obj in ipairs(list) do
                    table.insert(batch, { collection = col, key = obj.key, user_id = uid })
                end
                pcall(nk.storage_delete, batch)
            end
            cursor = next_cursor or ""
        until cursor == ""
    end

    -- 注销 Nakama 账号（不可恢复）
    local ok, err = pcall(nk.users_delete, { uid })
    if not ok then
        nk.logger_warn("delete_account: users_delete 失败 uid=" .. uid .. " err=" .. tostring(err))
        return nk.json_encode({ success = false, error = "内部错误，请重试" })
    end

    nk.logger_info("delete_account: 账号已注销 uid=" .. uid)
    return nk.json_encode({ success = true })
end
nk.register_rpc(safe_rpc(delete_account), "delete_account")

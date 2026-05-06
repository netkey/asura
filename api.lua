local nk      = require("nakama")
local catalog = require("hero_catalog")
local gconfig = require("game_config")

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

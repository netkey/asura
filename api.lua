local nk = require("nakama")


local function find_or_create_match(context, payload)
    local json = nk.json_decode(payload)
    local mode = json.mode or "standard"
    
    -- 使用 Nakama 内置的查询功能，寻找正在等待、且未满员、且模式相同的房间
    local query = "+label.mode:" .. mode .. " +label.open:1"
    local matches = nk.match_list(10, true, nil, nil, nil, query)

    if #matches > 0 then
        -- 找到已有房间，返回 ID
        return nk.json_encode({ match_id = matches[1].match_id })
    else
        -- 没找到，创建一个新房间
        -- label 里的 open:1 表示该房间还可以加入
        local match_id = nk.match_create("match_handler", { 
            max_players = json.max_players, 
            mode = mode 
        })
        return nk.json_encode({ match_id = match_id })
    end
end
nk.register_rpc(find_or_create_match, "find_or_create_match")

-- api.lua
local function check_hero_access(context, payload)
    local json = nk.json_decode(payload)
    local user_id = context.user_id
    local hero_id = json.hero_id

    -- 默认英雄无需校验
    if hero_id == "aladdin" then
        return nk.json_encode({ has_access = true })
    end

    -- 从数据库读取已解锁列表
    local object_ids = {{
        collection = "hero_inventory",
        key = "unlocked_heroes",
        user_id = user_id
    }}
    local objects = nk.storage_read(object_ids)

    local unlocked = false
    if #objects > 0 then
        local inventory = objects[1].value
        if inventory[hero_id] then
            unlocked = true
        end
    end

    return nk.json_encode({ has_access = unlocked })
end

-- 注册 RPC 供客户端调用
nk.register_rpc(check_hero_access, "check_hero_access")

local function buy_hero(context, payload)
    local json = nk.json_decode(payload)
    local user_id = context.user_id
    local hero_id = json.hero_id
    
    -- 英雄价格配置 (实际应存在一个单独的配置表里)
    local HERO_PRICES = {
        hakim = 1000,
        saladin = 2000
    }
    local price = HERO_PRICES[hero_id]
    if not price then return nk.json_encode({success = false, error = "英雄不存在"}) end

    -- 1. 检查并扣除金币 (使用原子操作 wallet_update)
    -- 如果金币不足，这个函数会抛出异常，我们用 pcall 捕获
    local status, err = pcall(nk.wallet_update, user_id, { gold = -price }, {}, true)
    if not status then
        return nk.json_encode({ success = false, error = "金币不足" })
    end

    -- 2. 更新解锁列表
    local objects = nk.storage_read({{ collection = "hero_inventory", key = "unlocked_heroes", user_id = user_id }})
    local inventory = {}
    if #objects > 0 then
        inventory = objects[1].value
    end
    
    inventory[hero_id] = true -- 标记为已拥有

    nk.storage_write({{
        collection = "hero_inventory",
        key = "unlocked_heroes",
        user_id = user_id,
        value = inventory,
        permission_read = 1,
        permission_write = 0
    }})

    return nk.json_encode({ success = true })
end

nk.register_rpc(buy_hero, "buy_hero")

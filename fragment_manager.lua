-- fragment_manager.lua  英雄碎片管理系统
-- 碎片类型：专属碎片（hero_id）+ 通用碎片（"universal"）
-- 兑换比例：30 专属碎片 = 1 英雄；通用碎片可 1:1 替代任意专属缺口
-- 存储：fragment_inventory / fragments = { [hero_id]: count, universal: count }

local catalog = require("hero_catalog")

local M = {}

local FRAGMENTS_PER_HERO = 30
local COLLECTION         = "fragment_inventory"

-- ==========================================
-- 工具：收集所有可碎片化的英雄 ID（price>0 才需碎片）
-- ==========================================
local function all_fragment_heroes()
    local ids = {}
    for id, info in pairs(catalog.HEROES) do
        if info.price and info.price > 0 then
            table.insert(ids, id)
        end
    end
    return ids
end

-- ==========================================
-- 读取碎片库存
-- ==========================================
local function load(uid)
    local objects = nk.storage_read({{
        collection = COLLECTION,
        key        = "fragments",
        user_id    = uid,
    }})
    if #objects > 0 then return objects[1].value, objects[1].version end
    return {}, nil
end

-- ==========================================
-- shallow table copy（平坦层级，key=字符串，value=数字）
-- ==========================================
local function copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

-- ==========================================
-- 写入碎片库存（OCC 乐观锁 + 3 次重试）
-- 在 OCC 冲突时，将 original→inv 的 delta 重新应用到 fresh 状态，
-- 而非用 inv 直接覆盖 fresh（避免丢失并发写入）
-- ==========================================
local function save(uid, inv, version, original)
    for attempt = 1, 3 do
        local ok = pcall(nk.storage_write, {{
            collection       = COLLECTION,
            key              = "fragments",
            user_id          = uid,
            value            = inv,
            version          = version,
            permission_read  = 1,
            permission_write = 0,
        }})
        if ok then return true end
        if attempt < 3 then
            local fresh, fresh_ver = load(uid)
            -- 计算 original → inv 的 delta，重新应用到 fresh
            local all_keys = {}
            for k in pairs(inv) do all_keys[k] = true end
            for k in pairs(original) do all_keys[k] = true end
            for k in pairs(all_keys) do
                local delta = (inv[k] or 0) - (original[k] or 0)
                if delta ~= 0 then
                    fresh[k] = (fresh[k] or 0) + delta
                    if fresh[k] <= 0 then fresh[k] = nil end
                end
            end
            inv, version = fresh, fresh_ver
        end
    end
    return false
end

-- ==========================================
-- 随机选择一个英雄发放碎片
-- 出参：true/false, hero_id 或错误信息
-- ==========================================
function M.add_random_fragment(uid)
    local inv, version = load(uid)
    local heroes = all_fragment_heroes()
    if #heroes == 0 then return false, "no fragment heroes available" end

    local orig = copy(inv)
    local hero_id = heroes[math.random(#heroes)]
    inv[hero_id] = (inv[hero_id] or 0) + 1
    if not save(uid, inv, version, orig) then
        return false, "save failed"
    end
    return true, hero_id
end

-- ==========================================
-- 查询碎片库存
-- payload: {}（无参数）
-- 出参：{ fragments: { [hero_id]: count }, universal: count }
-- ==========================================
function M.get_fragments(context, payload)
    local uid = context.user_id
    local inv = load(uid)
    return nk.json_encode(inv)
end

-- ==========================================
-- 转换重复英雄碎片为通用碎片
-- payload: { hero_id }
-- 出参：{ success, converted_count, universal_count, error? }
-- ==========================================
function M.convert(context, payload)
    local uid = context.user_id
    local json = nk.json_decode(payload)
    local hero_id = json and json.hero_id
    if type(hero_id) ~= "string" then
        return nk.json_encode({ success = false, error = "need hero_id" })
    end

    local inv, version = load(uid)
    local count = inv[hero_id] or 0
    if count < 1 then
        return nk.json_encode({ success = false, error = "no fragments for this hero" })
    end

    local orig = copy(inv)
    inv[hero_id] = nil
    inv.universal = (inv.universal or 0) + count

    if not save(uid, inv, version, orig) then
        return nk.json_encode({ success = false, error = "save failed (OCC conflict)" })
    end

    return nk.json_encode({
        success         = true,
        converted_count = count,
        universal_count = inv.universal,
    })
end

-- ==========================================
-- 尝试用碎片兑换英雄（被 buy_hero 调用）
-- 入参：uid, hero_id
-- 出参：true（碎片扣除成功） or false
-- ==========================================
function M.try_redeem(uid, hero_id)
    local inv, version = load(uid)
    local needed = FRAGMENTS_PER_HERO
    local avail_hero = inv[hero_id] or 0
    local avail_uni  = inv.universal or 0

    if avail_hero + avail_uni < needed then
        return false
    end

    local orig = copy(inv)
    local use_hero = math.min(avail_hero, needed)
    local use_uni  = needed - use_hero

    inv[hero_id] = avail_hero - use_hero
    if inv[hero_id] <= 0 then inv[hero_id] = nil end
    inv.universal = avail_uni - use_uni
    if inv.universal <= 0 then inv.universal = nil end

    if not save(uid, inv, version, orig) then
        return false
    end
    return true
end

-- ==========================================
-- 检查累计充值是否 ≥ 100 元
-- 读取 iap_records/total 中的 total_rmb 字段
-- ==========================================
local function check_recharge_100(uid)
    local objects = nk.storage_read({{
        collection = "iap_records",
        key        = "total",
        user_id    = uid,
    }})
    if #objects > 0 and (objects[1].value.total_rmb or 0) >= 100 then
        return true
    end
    return false
end

-- ==========================================
-- 赠送碎片给好友
-- payload: { target_id, hero_id, count }
-- 校验：好友 ≥ 7天 + 周上限 5 枚 + 累计充值 ≥ 100 元
-- 出参：{ success, error? }
-- ==========================================
function M.send_fragment(context, payload)
    local uid = context.user_id
    local json = nk.json_decode(payload)
    local target_id = json and json.target_id
    local hero_id   = json and json.hero_id
    local count     = json and json.count or 1

    if type(target_id) ~= "string" or type(hero_id) ~= "string" then
        return nk.json_encode({ success = false, error = "need target_id and hero_id" })
    end
    if count < 1 or count > 5 then
        return nk.json_encode({ success = false, error = "count must be 1-5" })
    end

    -- === 校验 1：好友关系 ≥ 7 天 ===
    local friends, _, _ = nk.friends_list(uid, 100, 0, "")
    local friend_ok = false
    local friend_create_time = 0
    for _, f in ipairs(friends or {}) do
        if f.user and f.user.id == target_id then
            friend_ok = true
            friend_create_time = f.create_time or 0
            break
        end
    end
    if not friend_ok then
        return nk.json_encode({ success = false, error = "not friends" })
    end
    if os.time() - friend_create_time < 7 * 86400 then
        return nk.json_encode({ success = false, error = "friendship less than 7 days" })
    end

    -- === 校验 2：累计充值 ≥ 100 元（发送方） ===
    -- 字段由 IAP RPC 回调写入 iap_records/total.total_rmb
    if not check_recharge_100(uid) then
        return nk.json_encode({ success = false, error = "need cumulative recharge >= 100 RMB" })
    end

    -- === 校验 3：周上限 — 发送方 ===
    local week_start = os.date("!%Y-%W", os.time() + 3 * 3600)
    local gifting_key = "gifting_" .. week_start
    local gifting_objects = nk.storage_read({{
        collection = "fragment_gifting",
        key        = gifting_key,
        user_id    = uid,
    }})
    local gifting = #gifting_objects > 0 and gifting_objects[1].value or { sent = 0, received = 0 }
    if (gifting.sent or 0) + count > 5 then
        return nk.json_encode({ success = false, error = "weekly send limit (max 5)" })
    end

    -- === 校验 4：周上限 — 接收方 ===
    local recv_objects = nk.storage_read({{
        collection = "fragment_gifting",
        key        = gifting_key,
        user_id    = target_id,
    }})
    local recv_state = #recv_objects > 0 and recv_objects[1].value or { sent = 0, received = 0 }
    if (recv_state.received or 0) + count > 5 then
        return nk.json_encode({ success = false, error = "recipient weekly receive limit (max 5)" })
    end

    -- === 扣除发送方碎片 ===
    local inv, version = load(uid)
    local avail = (hero_id == "universal" and inv.universal or inv[hero_id]) or 0
    if avail < count then
        return nk.json_encode({ success = false, error = "insufficient fragments" })
    end

    local orig = copy(inv)
    if hero_id == "universal" then
        inv.universal = inv.universal - count
        if inv.universal <= 0 then inv.universal = nil end
    else
        inv[hero_id] = inv[hero_id] - count
        if inv[hero_id] <= 0 then inv[hero_id] = nil end
    end

    if not save(uid, inv, version, orig) then
        return nk.json_encode({ success = false, error = "save failed" })
    end

    -- === 接收方入库（OCC 保护，防止并发赠送丢失） ===
    local recv_inv, recv_ver = load(target_id)
    local recv_orig = copy(recv_inv)
    if hero_id == "universal" then
        recv_inv.universal = (recv_inv.universal or 0) + count
    else
        recv_inv[hero_id] = (recv_inv[hero_id] or 0) + count
    end
    pcall(nk.storage_write, {{
        collection       = COLLECTION,
        key              = "fragments",
        user_id          = target_id,
        value            = recv_inv,
        version          = recv_ver,
        permission_read  = 1,
        permission_write = 0,
    }})

    -- === 更新双方的周限额 ===
    gifting.sent = (gifting.sent or 0) + count
    pcall(nk.storage_write, {{
        collection       = "fragment_gifting",
        key              = gifting_key,
        user_id          = uid,
        value            = gifting,
        permission_read  = 2,
        permission_write = 0,
    }})
    recv_state.received = (recv_state.received or 0) + count
    pcall(nk.storage_write, {{
        collection       = "fragment_gifting",
        key              = gifting_key,
        user_id          = target_id,
        value            = recv_state,
        permission_read  = 2,
        permission_write = 0,
    }})

    -- 通知接收方
    local ok_info, account_info = pcall(nk.account_get_id, uid)
    local sender_name = (ok_info and account_info and account_info.username) or "someone"
    pcall(nk.notifications_send, {{
        code       = 3,
        content    = { target_id = uid, hero_id = hero_id, count = count },
        persistent = true,
        sender_id  = uid,
        subject    = "You received " .. count .. " fragment(s) from " .. sender_name,
        user_id    = target_id,
    }})

    return nk.json_encode({ success = true })
end

return M

-- rate_limiter.lua  per-user 滑动窗口限流
-- 基于 Nakama Storage，OCC version 写入防止并发 TOCTOU 绕过
-- 写入失败（并发冲突）时重试一次，防止窗口边界合法请求被误拒

local M = {}

function M.check(nk, uid, action, max_calls, window_secs)
    local now = os.time()

    local objects = nk.storage_read({{
        collection = "rate_limits",
        key        = action,
        user_id    = uid,
    }})

    local rec     = nil
    local version = nil
    if #objects > 0 then
        rec     = objects[1].value
        version = objects[1].version
    end

    local new_rec
    if rec and (now - rec.window_start) < window_secs then
        if rec.count >= max_calls then
            return false
        end
        new_rec = { count = rec.count + 1, window_start = rec.window_start }
    else
        new_rec = { count = 1, window_start = now }
        -- is_expired: 窗口过期重置场景
    end

    local write_version = version or "*"
    local ok = pcall(nk.storage_write, {{
        collection       = "rate_limits",
        key              = action,
        user_id          = uid,
        value            = new_rec,
        version          = write_version,
        permission_read  = 0,
        permission_write = 0,
    }})

    -- OCC 冲突时重试一次（窗口边界并发）
    if not ok then
        local retry_obj = nk.storage_read({{
            collection = "rate_limits",
            key        = action,
            user_id    = uid,
        }})
        if #retry_obj > 0 then
            local r_rec = retry_obj[1].value
            local r_ver = retry_obj[1].version
            if r_rec and (now - r_rec.window_start) < window_secs then
                if r_rec.count >= max_calls then return false end
                new_rec = { count = r_rec.count + 1, window_start = r_rec.window_start }
            else
                new_rec = { count = 1, window_start = now }
            end
            ok = pcall(nk.storage_write, {{
                collection = "rate_limits", key = action, user_id = uid,
                value = new_rec, version = r_ver or "*",
                permission_read = 0, permission_write = 0,
            }})
        else
            -- 记录已被删除（极低概率），创建新记录
            ok = pcall(nk.storage_write, {{
                collection = "rate_limits", key = action, user_id = uid,
                value = { count = 1, window_start = now }, version = "*",
                permission_read = 0, permission_write = 0,
            }})
        end
    end

    if not ok then
        return false
    end

    return true
end

return M

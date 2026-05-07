-- rate_limiter.lua  per-user 滑动窗口限流
-- 基于 Nakama Storage，OCC version 写入防止并发 TOCTOU 绕过
-- 写入失败（并发冲突）时直接拒绝，不因 Storage 抖动阻塞正常业务

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
        version = nil   -- 窗口已过期或首次：插入新记录
    end

    -- OCC 写入：version="*" 表示仅当记录不存在时写入（首次或窗口重置）
    --            version=具体值 表示仅当版本匹配时更新，防止并发计数器竞争
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

    if not ok then
        -- 版本冲突（并发请求同时通过检查）：拒绝此次请求
        return false
    end

    return true
end

return M

-- rate_limiter.lua  per-user 滑动窗口限流
-- 基于 Nakama Storage，计数窗口超期后自动重置
-- M.check 写失败时静默放行（不因 Storage 抖动阻塞正常业务）

local M = {}

function M.check(nk, uid, action, max_calls, window_secs)
    local now = os.time()

    local objects = nk.storage_read({{
        collection = "rate_limits",
        key        = action,
        user_id    = uid,
    }})

    local rec = (#objects > 0) and objects[1].value or nil

    if rec and (now - rec.window_start) < window_secs then
        if rec.count >= max_calls then
            return false
        end
        rec.count = rec.count + 1
    else
        rec = { count = 1, window_start = now }
    end

    pcall(nk.storage_write, {{
        collection       = "rate_limits",
        key              = action,
        user_id          = uid,
        value            = rec,
        permission_read  = 0,
        permission_write = 0,
    }})

    return true
end

return M

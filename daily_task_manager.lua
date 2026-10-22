-- daily_task_manager.lua  每日任务系统
-- 刷新周期：UTC+3 每日 00:00
-- 任务：赢得 1 局对战 → 1 随机英雄碎片
-- 胜场计数由 season_manager.record_match 回调触发
local nk = require("nakama")

local frag_mgr = require("fragment_manager")

local M = {}

-- UTC+3 日期 key（用于每日刷新判断）
local function today_key()
    return os.date("!%Y-%m-%d", os.time() + 3 * 3600)
end

-- ==========================================
-- 加载每日任务状态（不存在则创建今日空任务）
-- 返回 state, version
-- ==========================================
local function load_or_create(nk, uid)
    local objects = nk.storage_read({{
        collection = "daily_tasks",
        key        = "state",
        user_id    = uid,
    }})
    local state, version
    if #objects > 0 then
        state   = objects[1].value
        version = objects[1].version
    else
        state   = {}
        version = "*"
    end

    local today = today_key()
    if state.date ~= today then
        state   = { date = today, wins = 0, claimed = false }
        version = "*"  -- 重置后以 "*" 写入，忽略旧版本
    end
    return state, version
end

-- ==========================================
-- 持久化每日任务状态（OCC 版本控制，3 次重试）
-- ==========================================
local function save(nk, uid, state, version)
    local ok = pcall(nk.storage_write, {{
        collection       = "daily_tasks",
        key              = "state",
        user_id          = uid,
        value            = state,
        version          = version,
        permission_read  = 1,
        permission_write = 0,
    }})
    return ok
end

-- ==========================================
-- 外部回调：对局胜利时调用（由 season_manager.record_match 触发）
-- ==========================================
function M.on_match_win(nk, uid, username)
    local state, version = load_or_create(nk, uid)
    if state.claimed then return end
    if state.date ~= today_key() then return end
    state.wins = (state.wins or 0) + 1
    save(nk, uid, state, version)
    -- 忽略 OCC 冲突（极低概率，下一场胜场会覆盖重算）
end

-- ==========================================
-- RPC：查询今日任务状态
-- payload: {}（无参数）
-- 出参：{ date, wins, claimed, total_win_required }
-- ==========================================
function M.get_task(context, payload)
    local uid = context.user_id
    local _ = payload

    local state = load_or_create(nk, uid)
    return nk.json_encode({
        date             = state.date,
        wins             = state.wins,
        claimed          = state.claimed,
        total_win_required = 1,
        reward           = { type = "fragment", count = 1 },
    })
end

-- ==========================================
-- RPC：领取今日任务奖励
-- 使用 OCC 版本控制，3 次重试，防止并发重复领取
-- payload: {}（无参数）
-- 出参：{ success, fragment_hero, fragment_count, error? }
-- ==========================================
function M.claim(context, payload)
    local uid = context.user_id
    local _ = payload

    for attempt = 1, 3 do
        local state, version = load_or_create(nk, uid)

        if state.date ~= today_key() then
            return nk.json_encode({ success = false, error = "today's task not available yet" })
        end
        if state.claimed then
            return nk.json_encode({ success = false, error = "already claimed today" })
        end
        if (state.wins or 0) < 1 then
            return nk.json_encode({ success = false, error = "need 1 win to claim" })
        end

        local ok, hero_id = frag_mgr.add_random_fragment(uid)
        if not ok then
            return nk.json_encode({ success = false, error = "failed to grant fragment: " .. tostring(hero_id) })
        end

        state.claimed = true
        if save(nk, uid, state, version) then
            return nk.json_encode({
                success        = true,
                fragment_hero  = hero_id,
                fragment_count = 1,
            })
        end
        -- OCC 冲突，重试以重新加载
    end

    return nk.json_encode({ success = false, error = "conflict_retry" })
end

return M

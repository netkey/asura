-- season_manager.lua  赛季与战绩管理
-- 负责：积分计算、match_history 写入、season_stats 聚合、Nakama leaderboard 更新
-- 赛季由管理员通过 admin_start_season / admin_end_season RPC 手动控制

local M = {}

local HISTORY_LIMIT = 50  -- 每位玩家每赛季最多保留对局数

-- ==========================================
-- 积分增减表
-- ==========================================
local DELTA_TABLE = {
    MONARCH_WIN = { MONARCH = 12, MINISTER = 8,  REBEL = -5, TRAITOR = -5 },
    REBEL_WIN   = { MONARCH = -5, MINISTER = -5, REBEL = 10, TRAITOR = -8 },
    TRAITOR_WIN = { MONARCH = -5, MINISTER = -5, REBEL = -5, TRAITOR = 15 },
}

-- ==========================================
-- 读取当前赛季配置
-- ==========================================
function M.get_current_season(nk)
    local objects = nk.storage_read({{
        collection = "season_config",
        key        = "current",
        user_id    = nil,
    }})
    return (#objects > 0) and objects[1].value or nil
end

-- ==========================================
-- 计算每位玩家的积分变化
-- 返回 { uid → delta }
-- ==========================================
function M.calc_rating(state, winner)
    local deltas = {}
    if state.mode == "pvp" then
        for uid, p in pairs(state.players) do
            deltas[uid] = (p.health > 0) and 10 or -5
        end
    else
        local tbl = DELTA_TABLE[winner] or {}
        for uid, p in pairs(state.players) do
            deltas[uid] = tbl[p.role] or 0
        end
    end
    return deltas
end

-- ==========================================
-- 读取玩家当前赛季统计（不存在则返回初始值）
-- ==========================================
local function load_season_stats(nk, uid, season_id)
    local objects = nk.storage_read({{
        collection = "season_stats",
        key        = season_id,
        user_id    = uid,
    }})
    if #objects > 0 then return objects[1].value end
    return {
        season_id       = season_id,
        games           = 0,
        wins            = 0,
        losses          = 0,
        rating          = 1000,
        best_streak     = 0,
        current_streak  = 0,
        hero_stats      = {},
        role_stats      = {},
    }
end

-- ==========================================
-- 更新并持久化赛季统计
-- ==========================================
local function update_season_stats(nk, uid, p, season_id, is_win, delta)
    local stats = load_season_stats(nk, uid, season_id)

    stats.games   = stats.games + 1
    stats.rating  = math.max(0, stats.rating + delta)

    if is_win then
        stats.wins           = stats.wins + 1
        stats.current_streak = stats.current_streak + 1
        if stats.current_streak > stats.best_streak then
            stats.best_streak = stats.current_streak
        end
    else
        stats.losses         = stats.losses + 1
        stats.current_streak = 0
    end

    -- 英雄统计
    local hero = p.hero or "unknown"
    stats.hero_stats[hero] = stats.hero_stats[hero] or { games = 0, wins = 0 }
    stats.hero_stats[hero].games = stats.hero_stats[hero].games + 1
    if is_win then stats.hero_stats[hero].wins = stats.hero_stats[hero].wins + 1 end

    -- 角色统计（pvp 模式跳过）
    if p.role and p.role ~= "NONE" then
        stats.role_stats[p.role] = stats.role_stats[p.role] or { games = 0, wins = 0 }
        stats.role_stats[p.role].games = stats.role_stats[p.role].games + 1
        if is_win then stats.role_stats[p.role].wins = stats.role_stats[p.role].wins + 1 end
    end

    nk.storage_write({{
        collection       = "season_stats",
        key              = season_id,
        user_id          = uid,
        value            = stats,
        permission_read  = 1,
        permission_write = 0,
    }})

    return stats
end

-- ==========================================
-- 写入单条对局历史，超出限制时删除最旧记录
-- ==========================================
local function write_match_history(nk, uid, season_id, ts, p, mode, winner, is_win, turns, delta, rating_after)
    local key = season_id .. "_" .. tostring(ts)
    nk.storage_write({{
        collection       = "match_history",
        key              = key,
        user_id          = uid,
        value            = {
            season_id       = season_id,
            timestamp       = ts,
            mode            = mode,
            hero            = p.hero,
            role            = p.role,
            winner          = winner,
            result          = is_win and "WIN" or "LOSS",
            turns           = turns,
            damage_dealt    = p.damage_dealt or 0,
            damage_received = p.damage_received or 0,
            rating_change   = delta,
            rating_after    = rating_after,
        },
        permission_read  = 1,
        permission_write = 0,
    }})

    -- 裁剪：超出 HISTORY_LIMIT 时删最旧一条
    local list = nk.storage_list(uid, "match_history", 200, "")
    if list and #list > HISTORY_LIMIT then
        -- 按 key 升序（key 前缀相同，ts 越小越旧）
        table.sort(list, function(a, b) return a.key < b.key end)
        local to_delete = {}
        for i = 1, #list - HISTORY_LIMIT do
            table.insert(to_delete, { collection = "match_history", key = list[i].key, user_id = uid })
        end
        nk.storage_delete(to_delete)
    end
end

-- ==========================================
-- 主入口：结算一局对局
-- state.turns 需由 match_handler 维护；这里如无则填 0
-- ==========================================
function M.record_match(nk, state, winner)
    local season = M.get_current_season(nk)
    if not season then return end  -- 未开赛季则不记录

    local deltas = M.calc_rating(state, winner)
    local ts     = os.time()
    local turns  = state.turns or 0

    for uid, p in pairs(state.players) do
        local delta   = deltas[uid] or 0
        local is_win  = delta > 0
        local updated = update_season_stats(nk, uid, p, season.season_id, is_win, delta)

        write_match_history(nk, uid, season.season_id, ts, p,
            state.mode, winner, is_win, turns, delta, updated.rating)

        -- 更新排行榜
        nk.leaderboard_record_write(
            season.leaderboard_id,
            uid,
            p.username,
            updated.rating,
            0,
            {}
        )
    end
end

return M

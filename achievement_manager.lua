-- achievement_manager.lua  成就系统
-- 成就永久有效，跨赛季不重置，每个成就只能解锁一次
-- hero_mastery 类按英雄单独记录，同一英雄不重复颁发

local nk = require("nakama")

local M = {}

-- ==========================================
-- 成就定义表（19枚）
-- check(stats, match_ctx) -> bool
--   stats     : update_season_stats 返回的最新统计
--   match_ctx : { is_win, hero, role, damage_dealt, mode }
-- ==========================================
local ACHIEVEMENTS = {
    -- 首胜类
    { id = "first_win",          name = "初出茅庐", gold = 100,
      check = function(s, m) return m.is_win and s.wins >= 1 end },
    { id = "pvp_first_win",      name = "擂台初鸣", gold = 50,
      check = function(s, m) return m.is_win and m.mode == "pvp" and (s.pvp_wins or 0) >= 1 end },
    { id = "identity_first_win", name = "身份初显", gold = 50,
      check = function(s, m) return m.is_win and m.mode == "identity" and (s.identity_wins or 0) >= 1 end },

    -- 连胜类
    { id = "streak_3",  name = "势如破竹", gold = 80,
      check = function(s, _) return s.best_streak >= 3 end },
    { id = "streak_5",  name = "锐不可当", gold = 150,
      check = function(s, _) return s.best_streak >= 5 end },
    { id = "streak_10", name = "战无不胜", gold = 500,
      check = function(s, _) return s.best_streak >= 10 end },

    -- 对局数里程碑
    { id = "games_10",   name = "初涉江湖", gold = 50,
      check = function(s, _) return s.games >= 10 end },
    { id = "games_50",   name = "身经百战", gold = 200,
      check = function(s, _) return s.games >= 50 end },
    { id = "games_100",  name = "沙场老将", gold = 500,
      check = function(s, _) return s.games >= 100 end },
    { id = "games_500",  name = "戎马半生", gold = 1500,
      check = function(s, _) return s.games >= 500 end },
    { id = "games_1000", name = "千战不殆", gold = 5000,
      check = function(s, _) return s.games >= 1000 end },

    -- 身份局角色胜利
    { id = "win_as_monarch", name = "君临天下", gold = 100,
      check = function(s, m)
          return m.is_win and m.role == "MONARCH"
              and (s.role_stats["MONARCH"] or {wins=0}).wins >= 1
      end },
    { id = "win_as_rebel",   name = "揭竿而起", gold = 100,
      check = function(s, m)
          return m.is_win and m.role == "REBEL"
              and (s.role_stats["REBEL"] or {wins=0}).wins >= 1
      end },
    { id = "win_as_traitor", name = "孤注一掷", gold = 200,
      check = function(s, m)
          return m.is_win and m.role == "TRAITOR"
              and (s.role_stats["TRAITOR"] or {wins=0}).wins >= 1
      end },

    -- 单场伤害
    { id = "damage_single_20", name = "破阵斩将", gold = 100,
      check = function(_, m) return m.damage_dealt >= 20 end },

    -- 赛季积分
    { id = "rating_1200", name = "崭露头角", gold = 150,
      check = function(s, _) return s.rating >= 1200 end },
    { id = "rating_1500", name = "声名大噪", gold = 300,
      check = function(s, _) return s.rating >= 1500 end },
}

-- 英雄精通（动态生成，check 逻辑特殊，单独处理）
local MASTERY_TIERS = {
    { suffix = "10", name_fmt = "%s专精", gold = 150,  threshold = 10 },
    { suffix = "25", name_fmt = "%s大师", gold = 400,  threshold = 25 },
}

-- ==========================================
-- 读取玩家已解锁成就（不存在返回空表）
-- ==========================================
local function load_achievements(nk, uid)
    local objects = nk.storage_read({{
        collection = "achievements",
        key        = "unlocked",
        user_id    = uid,
    }})
    if #objects > 0 then return objects[1].value, objects[1].version end
    return {}, nil
end

-- ==========================================
-- 颁发成就：写 storage（OCC 乐观锁 + 重试 3 次）+ 金币 + Nakama 通知
-- ==========================================
local function grant(nk, uid, username, ach_id, ach_name, gold, unlocked)
    local ts = os.time()
    -- 保留 unlocked[ach_id] 中已有字段（如 hero_mastery 的 heroes 数组）
    local existing = unlocked[ach_id]
    unlocked[ach_id] = existing and { unlocked_at = ts, heroes = existing.heroes } or { unlocked_at = ts }

    for attempt = 1, 3 do
        -- 读取当前版本做 OCC 写入
        local _, version = load_achievements(nk, uid)

        local ok, err = pcall(nk.storage_write, {{
            collection       = "achievements",
            key              = "unlocked",
            user_id          = uid,
            value            = unlocked,
            version          = version,
            permission_read  = 1,
            permission_write = 0,
        }})
        if ok then
            -- OCC 写入成功后才发金币和通知
            local ok2, err2 = pcall(nk.wallet_update, uid, { gold = gold }, {}, true)
            if not ok2 then
                nk.logger_warn("grant: wallet_update 失败 uid=" .. uid .. " ach=" .. ach_id .. " err=" .. tostring(err2))
            end
            pcall(nk.notifications_send, {{
                code       = 2,
                content    = { achievement_id = ach_id, name = ach_name, gold = gold },
                persistent = true,
                sender_id  = nil,
                subject    = "解锁成就：" .. ach_name .. "（+" .. gold .. "金币）",
                user_id    = uid,
            }})
            nk.logger_info("成就解锁 uid=" .. uid .. " ach=" .. ach_id .. " gold=" .. gold)
            break
        end

        if attempt < 3 then
            -- OCC 版本冲突：重载最新数据，合并当前进程已解锁的成就
            local fresh, _ = load_achievements(nk, uid)
            for k, v in pairs(fresh) do
                if not unlocked[k] then
                    unlocked[k] = v
                elseif type(v) == "table" and v.heroes and type(unlocked[k]) == "table" and unlocked[k].heroes then
                    -- 合并英雄精通成就的 heroes 数组
                    for _, h in ipairs(v.heroes) do
                        local found = false
                        for _, existing_h in ipairs(unlocked[k].heroes) do
                            if existing_h == h then found = true; break end
                        end
                        if not found then
                            table.insert(unlocked[k].heroes, h)
                        end
                    end
                end
            end
        else
            nk.logger_warn("grant: OCC 重试耗尽 uid=" .. uid .. " ach=" .. ach_id .. " err=" .. tostring(err))
        end
    end
end

-- ==========================================
-- 处理英雄精通成就（每英雄独立一枚）
-- ==========================================
local function check_hero_mastery(nk, uid, username, stats, match_ctx, unlocked)
    local hero = match_ctx.hero
    if not hero then return end

    local hero_wins = (stats.hero_stats[hero] or {wins=0}).wins

    for _, tier in ipairs(MASTERY_TIERS) do
        if hero_wins >= tier.threshold then
            -- 检查当前英雄该层级是否已领取
            local ach_id = "hero_mastery_" .. tier.suffix
            local existing = unlocked[ach_id]
            local already = false
            if existing and existing.heroes then
                for _, h in ipairs(existing.heroes) do
                    if h == hero then already = true; break end
                end
            end
            if not already then
                -- 找到英雄中文名（没有则用 id）
                local hero_name = hero
                local ach_name = string.format(tier.name_fmt, hero_name)
                -- 更新 heroes 列表后再写 storage（grant 会整体覆写 unlocked）
                if not unlocked[ach_id] then
                    unlocked[ach_id] = { unlocked_at = os.time(), heroes = {} }
                end
                table.insert(unlocked[ach_id].heroes, hero)
                grant(nk, uid, username, ach_id, ach_name, tier.gold, unlocked)
            end
        end
    end
end

-- ==========================================
-- 主入口：检查并颁发普通成就
-- ==========================================
function M.check_and_award(nk, uid, username, stats, match_ctx)
    local unlocked = load_achievements(nk, uid)

    -- 普通成就（幂等：已解锁则跳过）
    for _, ach in ipairs(ACHIEVEMENTS) do
        if not unlocked[ach.id] then
            local ok, result = pcall(ach.check, stats, match_ctx)
            if ok and result then
                grant(nk, uid, username, ach.id, ach.name, ach.gold, unlocked)
            end
        end
    end

    -- 英雄精通（按英雄单独判断）
    check_hero_mastery(nk, uid, username, stats, match_ctx, unlocked)
end

-- ==========================================
-- 返回全部成就定义（供 API 查询）
-- ==========================================
function M.get_all_definitions()
    local result = {}
    for _, ach in ipairs(ACHIEVEMENTS) do
        table.insert(result, { id = ach.id, name = ach.name, gold = ach.gold })
    end
    for _, tier in ipairs(MASTERY_TIERS) do
        table.insert(result, {
            id   = "hero_mastery_" .. tier.suffix,
            name = string.format(tier.name_fmt, "{hero}"),
            gold = tier.gold,
            note = "每英雄独立一枚，需该英雄赢" .. tier.threshold .. "场",
        })
    end
    return result
end

return M

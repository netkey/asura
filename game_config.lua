-- game_config.lua  游戏参数配置
-- 所有参数的权威默认值在 DEFAULTS 中定义，可读可审计。
-- 管理员通过 admin_set_config RPC 写入 Nakama storage，
-- 下一局对局初始化时自动生效，无需重新部署。

local M = {}

M.DEFAULTS = {
    match = {
        player_health     = 4,   -- 普通玩家初始血量
        monarch_health    = 5,   -- 主公初始血量（含额外+1）
        initial_hand_size = 4,   -- 游戏开始时每人摸牌数
        turn_timeout      = 30,  -- 回合超时秒数（超时触发托管）
        draw_cards_per_turn = 2, -- 每回合摸牌阶段摸牌数
        max_wine_per_turn  = 1,   -- 每回合最多用酒数（增伤用）
    },
    combat = {
        rebel_kill_reward    = 3, -- 击杀反贼后奖励摸牌数
        -- 防具减伤 & 武器加伤已直接配置在 CARD_EFFECTS 中
        wine_damage_bonus    = 1, -- 酒牌触发的攻击伤害加成
        lightning_damage     = 3, -- 闪电判定命中伤害
        attack_range_default = 1, -- 默认武器射程
        duel_timeout         = 15, -- 决斗响应超时
    },
    -- 临时覆盖 hero_catalog.lua 中的英雄定价，不影响代码定义
    -- 示例：{ hakim = 300 } 将哈基姆临时折扣至 300 金
    hero_price_overrides = {},
}

-- 深度合并：overrides 中存在的键覆盖 base，缺失键保留 base 值
local function deep_merge(base, overrides)
    local result = {}
    for k, v in pairs(base) do
        result[k] = type(v) == "table" and deep_merge(v, {}) or v
    end
    for k, v in pairs(overrides) do
        if type(v) == "table" and type(result[k]) == "table" then
            result[k] = deep_merge(result[k], v)
        else
            result[k] = v
        end
    end
    return result
end

-- 从 Nakama storage 加载配置覆盖项，与 DEFAULTS 合并后返回
-- storage: collection="server_config", key="game_config", user_id=nil（全局）
function M.load(nk)
    local objects = nk.storage_read({{
        collection = "server_config",
        key        = "game_config",
        user_id    = nil,
    }})
    if #objects > 0 then
        return deep_merge(M.DEFAULTS, objects[1].value)
    end
    return deep_merge(M.DEFAULTS, {})
end

return M

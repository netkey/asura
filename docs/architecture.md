# Asura 架构设计文档

**版本**: 1.0.0
**创建日期**: 2026-03-31
**作者**: Claude Code

---

## 1. 系统架构概述

### 1.1 架构目标
- **高可用性**: 99.9% 在线时间
- **低延迟**: 中东地区 <100ms 延迟
- **可扩展**: 支持 10,000+ 同时在线玩家
- **安全性**: 防止作弊和外挂
- **可维护**: 模块化设计，易于迭代

### 1.2 整体架构
```
┌─────────────────────────────────────────────────────────────┐
│                        客户端层                              │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  │
│  │ Web      │  │ Mobile   │  │ PC       │  │ Console  │  │
│  │ Client   │  │ Client   │  │ Client   │  │ Client   │  │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘  │
│       │             │             │             │          │
└───────┼─────────────┼─────────────┼─────────────┼──────────┘
        │             │             │             │
┌───────▼─────────────▼─────────────▼─────────────▼──────────┐
│                    负载均衡层 (Nginx)                       │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  │
│  │  SSL     │  │  WAF     │  │ 限流     │  │ 路由     │  │
│  │  终止    │  │  防护    │  │ 控制     │  │ 分发     │  │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘  │
│       │             │             │             │          │
└───────┼─────────────┼─────────────┼─────────────┼──────────┘
        │             │             │             │
┌───────▼─────────────▼─────────────▼─────────────▼──────────┐
│                  Nakama 游戏服务器集群                     │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐          │  │
│  │  │ Match    │  │ RPC      │  │ 实时     │          │  │
│  │  │ Handler  │  │ Handler  │  │ 对战     │          │  │
│  │  └────┬─────┘  └────┬─────┘  └────┬─────┘          │  │
│  │       │             │             │                │  │
│  │  ┌────▼─────────────▼─────────────▼──────────┐    │  │
│  │  │           Lua 游戏逻辑模块               │    │  │
│  │  │  ┌────────┐  ┌────────┐  ┌────────┐    │    │  │
│  │  │  │ 游戏   │  │ 英雄   │  │ 卡牌   │    │    │  │
│  │  │  │ 规则   │  │ 技能   │  │ 效果   │    │    │  │
│  │  │  └────────┘  └────────┘  └────────┘    │    │  │
│  │  └──────────────────────────────────────────┘    │  │
│  └────────────────────────────────────────────────────┘  │
└───────┬──────────────────────────────────────────────────┘
        │
┌───────▼──────────────────────────────────────────────────┐
│                    数据存储层                              │
│  ┌──────────────────┐  ┌──────────────────┐              │
│  │ PostgreSQL       │  │ Redis            │              │
│  │ (主数据库)       │  │ (缓存/会话)      │              │
│  │                  │  │                  │              │
│  │ - 用户数据       │  │ - 在线状态       │              │
│  │ - 英雄数据       │  │ - 匹配队列       │              │
│  │ - 游戏记录       │  │ - 临时数据       │              │
│  │ - 配置数据       │  │ - 限流计数       │              │
│  └──────────────────┘  └──────────────────┘              │
└────────────────────────────────────────────────────────────┘
```

---

## 2. 技术栈选择

### 2.1 后端技术

#### 2.1.1 Nakama 游戏服务器
- **选择理由**: 专为游戏设计的开源服务器
- **优势**: 实时对战、匹配系统、社交功能、Lua 脚本支持
- **版本**: 3.x

#### 2.1.2 数据库

**PostgreSQL (主数据库)**
- **用途**: 持久化存储用户数据、游戏记录、配置数据
- **优势**: ACID 事务、复杂查询、数据一致性
- **部署**: 主从复制，读写分离

**Redis (缓存层)**
- **用途**: 会话管理、排行榜、限流、临时数据
- **优势**: 高性能、数据结构丰富、Pub/Sub
- **持久化**: RDB + AOF

#### 2.1.3 消息队列 (未来)
- **选型**: RabbitMQ / Kafka
- **用途**: 异步任务、日志处理、事件通知

### 2.2 基础设施

#### 2.2.1 部署环境
- **Docker**: 容器化部署
- **Kubernetes**: 容器编排（生产环境）
- **Docker Compose**: 开发环境

#### 2.2.2 监控告警
- **Prometheus**: 指标收集
- **Grafana**: 可视化监控
- **ELK Stack**: 日志收集分析
- **PagerDuty**: 告警通知

#### 2.2.3 CDN 与加速
- **CloudFlare**: DDoS 防护、CDN 加速
- **AWS CloudFront**: 静态资源加速（如有）

---

## 3. 模块设计

### 3.1 API 模块 (api.lua)

#### 3.1.1 职责
- 提供 RPC 接口供客户端调用
- 处理用户认证、英雄购买、数据查询
- 对接 Nakama 的内置功能

#### 3.1.2 接口设计
```lua
-- 查找或创建匹配
rpc find_or_create_match(mode, max_players) -> match_id

-- 检查英雄访问权限
rpc check_hero_access(hero_id) -> {has_access: bool}

-- 购买英雄
rpc buy_hero(hero_id) -> {success: bool, error: string}

-- 获取玩家信息
rpc get_player_info() -> {level, gold, unlocked_heroes}

-- 获取英雄列表
rpc get_hero_list() -> [hero_info]

-- 获取排行榜
rpc get_leaderboard(type) -> [rank_data]
```

#### 3.1.3 数据验证
- 参数合法性检查
- 防作弊验证
- 速率限制

### 3.2 匹配模块 (match_handler.lua)

#### 3.2.1 职责
- 管理游戏房间生命周期
- 处理玩家加入/离开
- 协调游戏流程
- 处理断线重连

#### 3.2.2 状态机
```
WAITING -> PLAYING -> ENDED
   ↑          │
   └──────────┘ (重连)
```

#### 3.2.3 核心功能
- **匹配创建**: `match_init()`
- **玩家加入**: `match_join()`
- **游戏循环**: `match_loop()`
- **消息处理**: 处理客户端消息
- **状态同步**: 广播游戏状态
- **断线处理**: `match_leave()`、`match_join_attempt()`

### 3.3 游戏规则模块 (game_rules.lua)

#### 3.3.1 职责
- 实现核心游戏规则
- 处理卡牌效果
- 胜负判定
- 身份局逻辑

#### 3.3.2 核心组件

**卡牌系统**
```lua
-- 卡牌定义
type Card = {
    id: string,
    type: "ATTACK" | "DEFENSE" | "HEAL" | "AOE_SANDSTORM" | "DRAW_TWO" | "JUDGE_STORM",
    name: string,
    suit: "HEART" | "SPADE" | "CLUB" | "DIAMOND",
    number: 1-13
}

-- 牌堆管理
create_deck() -> shuffled_deck
draw_cards(state, player_id, count)
shuffle_discard_to_deck(state)
```

**回合流程**
```lua
-- 回合阶段
start_turn(state, player_id) -> {
    judgment_phase(),   -- 判定阶段
    draw_phase(),       -- 摸牌阶段
    play_phase(),       -- 出牌阶段
    discard_phase(),    -- 弃牌阶段
    end_phase()         -- 结束阶段
}

-- 切换回合
next_turn(state) -> next_player_id
```

**身份局逻辑**
```lua
-- 身份分配
assign_roles(player_count) -> [roles]

-- 胜负判定
check_victory(state) -> {is_over: bool, winner: role}

-- 奖惩机制
handle_role_reward(killer_id, victim_id)
```

### 3.4 英雄管理模块 (hero_manager.lua)

#### 3.4.1 职责
- 加载和管理英雄技能
- 触发技能钩子
- 处理技能响应

#### 3.4.2 技能系统

**钩子类型**
```lua
-- 被动技能钩子
on_damaged           -- 受到伤害后
on_before_attack     -- 攻击前
on_attack_defended   -- 攻击被防御后
on_after_damage      -- 造成伤害后

-- 主动技能钩子
on_draw_phase_start  -- 摸牌阶段开始前
on_play_phase_start  -- 出牌阶段开始前
on_judgment_phase    -- 判定阶段

-- 响应技能钩子
on_response          -- 玩家响应技能选择
```

**技能触发流程**
```lua
-- 触发技能
trigger(hook_name, dispatcher, state, player_id, ...) -> suspended: bool

-- 处理响应
handle_response(dispatcher, state, player_id, payload)
```

#### 3.4.3 英雄定义
```lua
-- 英雄模块结构
local hero = {
    -- 被动技能
    on_damaged = function(dispatcher, state, player_id, amount)
        -- 技能逻辑
        return false  -- 不挂起
    end,

    -- 主动技能
    on_play_phase_start = function(dispatcher, state, player_id)
        -- 询问玩家是否发动技能
        state.pending_action = {...}
        return true  -- 挂起等待响应
    end,

    -- 响应处理
    on_response = function(dispatcher, state, player_id, payload)
        -- 处理玩家选择
        state.pending_action = nil
    end
}
```

### 3.5 英雄技能模块

#### 3.5.1 阿拉丁 (aladdin.lua)
- **定位**: 摸牌流，新手友好
- **技能**: 【神灯】- 换牌技能
- **复杂度**: 低

#### 3.5.2 阿里巴巴 (alibaba.lua)
- **定位**: 防御反击
- **技能**: 【暗号】- 防御后反击
- **复杂度**: 中

#### 3.5.3 萨拉丁 (saladin.lua)
- **定位**: 坦克生存
- **技能**: 【坚守】- 受伤摸牌
- **复杂度**: 低

#### 3.5.4 哈基姆 (hakim.lua)
- **定位**: 控制预知
- **技能**: 【星象】- 控制判定
- **复杂度**: 高

---

## 4. 数据模型设计

### 4.1 用户数据 (users)

```sql
CREATE TABLE users (
    id UUID PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    email VARCHAR(255) UNIQUE,
    created_at TIMESTAMP DEFAULT NOW(),
    last_login TIMESTAMP,
    level INTEGER DEFAULT 1,
    experience INTEGER DEFAULT 0,
    gold INTEGER DEFAULT 0,
    diamond INTEGER DEFAULT 0,
    status VARCHAR(20) DEFAULT 'active'  -- active, banned, deleted
);
```

**Nakama 存储格式**
```json
{
    "collection": "user_profile",
    "key": "profile",
    "user_id": "...",
    "value": {
        "level": 1,
        "experience": 0,
        "gold": 1000,
        "diamond": 0,
        "stats": {
            "total_games": 0,
            "wins": 0,
            "loses": 0,
            "win_rate": 0.0
        }
    }
}
```

### 4.2 英雄数据 (heroes)

```json
{
    "collection": "hero_inventory",
    "key": "unlocked_heroes",
    "user_id": "...",
    "value": {
        "aladdin": {
            "owned": true,
            "games": 10,
            "wins": 6,
            "win_rate": 0.6,
            "favorite": true
        },
        "alibaba": {
            "owned": false,
            "price": 1000
        }
    }
}
```

### 4.3 游戏记录 (game_history)

```sql
CREATE TABLE game_history (
    id UUID PRIMARY KEY,
    match_id VARCHAR(100) NOT NULL,
    started_at TIMESTAMP NOT NULL,
    ended_at TIMESTAMP,
    game_mode VARCHAR(20) NOT NULL,
    player_count INTEGER NOT NULL,
    winner_role VARCHAR(20),
    duration_seconds INTEGER,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE game_players (
    id UUID PRIMARY KEY,
    game_id UUID REFERENCES game_history(id),
    user_id UUID NOT NULL,
    hero_id VARCHAR(50) NOT NULL,
    role VARCHAR(20) NOT NULL,
    final_health INTEGER,
    is_winner BOOLEAN,
    kills INTEGER DEFAULT 0,
    damage_dealt INTEGER DEFAULT 0,
    cards_played INTEGER DEFAULT 0,
    created_at TIMESTAMP DEFAULT NOW()
);
```

### 4.4 配置数据 (config)

```json
{
    "collection": "game_config",
    "key": "hero_prices",
    "value": {
        "aladdin": 0,
        "alibaba": 1000,
        "saladin": 1500,
        "hakim": 2000
    }
}

{
    "collection": "game_config",
    "key": "card_deck",
    "value": {
        "attack": 20,
        "defense": 10,
        "heal": 5,
        "draw_two": 3,
        "aoe_sandstorm": 3,
        "judge_storm": 2
    }
}
```

---

## 5. 网络通信设计

### 5.1 通信协议

#### 5.1.1 RPC 接口 (HTTP/HTTPS)
- **用途**: 非实时请求（登录、购买、查询）
- **格式**: JSON
- **认证**: Session Token
- **限流**: 100次/分钟/用户

#### 5.1.2 实时消息 (WebSocket)
- **用途**: 游戏实时通信
- **格式**: Protobuf（推荐）或 JSON
- **心跳**: 30秒一次
- **重连**: 自动重连机制

### 5.2 消息格式

#### 5.2.1 OpCode 定义
```lua
-- 系统消息
OP_HELLO = 0           -- 连接建立
OP_DISCONNECT = 1      -- 断开连接
OP_ERROR = 2           -- 错误消息

-- 游戏消息
OP_PLAY_CARD = 3       -- 出牌
OP_END_TURN = 4        -- 结束回合
OP_CHAT = 5            -- 聊天消息

-- 状态同步
OP_GAME_STATE = 10     -- 完整游戏状态
OP_PLAYER_UPDATE = 11  -- 玩家状态更新
OP_CARD_EFFECT = 12    -- 卡牌效果

-- 技能消息
OP_SKILL_CHOICE = 20   -- 技能选择
OP_SKILL_EFFECT = 21   -- 技能效果

-- 匹配消息
OP_MATCH_FOUND = 30    -- 找到匹配
OP_MATCH_START = 31    -- 游戏开始
OP_MATCH_END = 32      -- 游戏结束

-- 判定消息
OP_JUDGMENT = 40       -- 判定相关
```

#### 5.2.2 消息示例

**出牌消息**
```json
{
    "op_code": 3,
    "sender": "user_id",
    "data": {
        "card_id": "atk_15",
        "target_id": "user_id_2"
    }
}
```

**状态同步**
```json
{
    "op_code": 10,
    "data": {
        "current_turn": "user_id_1",
        "pending_action": {
            "type": "WAITING_FOR_DEFENSE",
            "attacker_id": "user_id_1",
            "target_id": "user_id_2",
            "deadline": 1640000000
        },
        "players": {
            "user_id_1": {
                "health": 4,
                "hand_count": 5,
                "hero": "aladdin",
                "role": "MONARCH"
            }
        }
    }
}
```

### 5.3 断线重连

#### 5.3.1 重连机制
1. **检测断线**: 心跳超时或连接断开
2. **保留状态**: 游戏状态保留 5 分钟
3. **重连验证**: 验证玩家身份
4. **状态同步**: 发送完整游戏状态
5. **继续游戏**: 恢复回合

#### 5.3.2 托管机制
- **触发**: 玩家超时未操作
- **行为**: AI 自动出牌（简单逻辑）
- **恢复**: 玩家重新操作后接管
- **惩罚**: 托管过多扣除信誉分

---

## 6. 部署架构

### 6.1 开发环境

```yaml
# docker-compose.yml
version: '3.8'
services:
  postgres:
    image: postgres:13
    environment:
      POSTGRES_DB: nakama
      POSTGRES_USER: nakama
      POSTGRES_PASSWORD: nakama
    ports:
      - "5432:5432"

  nakama:
    image: heroiclabs/nakama:3.14.0
    entrypoint:
      - "/bin/sh"
      - "-ecx"
      - >
        /nakama/nakama migrate up --database.address postgres://nakama:nakama@postgres:5432/nakama &&
        /nakama/nakama --name nakama1 --database.address postgres://nakama:nakama@postgres:5432/nakama --logger.level DEBUG --session.token_expiry_sec 7200
    restart: always
    links:
      - "postgres:db"
    depends_on:
      - postgres
    volumes:
      - ./:/nakama/data/modules
    expose:
      - "7349"
      - "7350"
      - "7351"
    ports:
      - "7349:7349"
      - "7350:7350"
      - "7351:7351"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:7350/"]
      interval: 10s
      timeout: 5s
      retries: 5
```

### 6.2 生产环境

#### 6.2.1 基础设施
```
┌─────────────────────────────────────────┐
│           CDN (CloudFlare)              │
│  - DDoS 防护                           │
│  - SSL 终止                            │
│  - 静态资源缓存                        │
└──────────────┬──────────────────────────┘
               │
┌──────────────▼──────────────────────────┐
│        负载均衡器 (Nginx Plus)          │
│  - 健康检查                            │
│  - 会话保持                            │
│  - 限流                                │
└──────────────┬──────────────────────────┘
               │
┌──────────────▼──────────────────────────┐
│      Nakama 集群 (3-5 节点)             │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐ │
│  │ Node 1  │  │ Node 2  │  │ Node 3  │ │
│  │ (主)    │  │ (从)    │  │ (从)    │ │
│  └────┬────┘  └────┬────┘  └────┬────┘ │
└───────┼────────────┼────────────┼───────┘
        │            │            │
┌───────▼────────────▼────────────▼───────┐
│    PostgreSQL 集群 (主从复制)          │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐ │
│  │ Master  │  │ Slave 1 │  │ Slave 2 │ │
│  └────┬────┘  └─────────┘  └─────────┘ │
└───────┼─────────────────────────────────┘
        │
┌───────▼──────────────┐
│   Redis 集群         │
│  - 会话缓存          │
│  - 排行榜            │
│  - 限流计数          │
└──────────────────────┘
```

#### 6.2.2 配置示例

**Nakama 配置**
```yaml
name: nakama-node-1
data_dir: ./data

logger:
  level: info
  file: /var/log/nakama/nakama.log

session:
  encryption_key: "your-encryption-key"
  token_expiry_sec: 7200
  refresh_token_expiry_sec: 604800

runtime:
  path: /nakama/data/modules
  http_key: "your-http-key"

database:
  address:
    - "postgres://nakama:password@postgres-master:5432/nakama"
  max_open_conns: 100
  max_idle_conns: 10
  conn_max_lifetime_ms: 60000

console:
  port: 7351
  username: admin
  password: password

cluster:
  enabled: true
  addr: 0.0.0.0:7356
  rpc_port: 7357
  gossip_bindaddr: 0.0.0.0:7358
  join:
    - nakama-node-2:7356
    - nakama-node-3:7356
```

---

## 7. 性能优化

### 7.1 代码优化

#### 7.1.1 Lua 性能最佳实践
```lua
-- 避免全局变量
local M = {}
local nk = require("nakama")

-- 预编译正则表达式
local pattern = [[%w+]]

-- 使用 table 缓存
local cache = {}
function get_hero_config(hero_id)
    if not cache[hero_id] then
        cache[hero_id] = load_hero_config(hero_id)
    end
    return cache[hero_id]
end

-- 避免频繁创建 table
local temp_table = {}
for i = 1, n do
    temp_table[i] = i
end

-- 使用 ipairs 而非 pairs（数组）
for i, v in ipairs(array) do
    -- do something
end
```

#### 7.1.2 减少数据库查询
```lua
-- 批量读取
local objects = nk.storage_read({
    {collection = "heroes", key = "config", user_id = user_id},
    {collection = "inventory", key = "items", user_id = user_id},
    {collection = "stats", key = "game", user_id = user_id}
})

-- 缓存频繁访问数据
local hero_config = nk.storage_read({...})[1].value
nk.runtime_cache_put("hero_config", hero_config, 3600)  -- 缓存1小时
```

### 7.2 数据库优化

#### 7.2.1 索引设计
```sql
-- 用户表索引
CREATE INDEX idx_users_username ON users(username);
CREATE INDEX idx_users_level ON users(level);
CREATE INDEX idx_users_last_login ON users(last_login);

-- 游戏记录索引
CREATE INDEX idx_game_history_started ON game_history(started_at);
CREATE INDEX idx_game_history_user ON game_players(user_id);
CREATE INDEX idx_game_history_winner ON game_history(winner_role);

-- 复合索引
CREATE INDEX idx_game_players_user_game ON game_players(user_id, game_id);
```

#### 7.2.2 查询优化
```sql
-- 使用 EXPLAIN ANALYZE 分析查询
EXPLAIN ANALYZE
SELECT * FROM game_players
WHERE user_id = '...'
ORDER BY created_at DESC
LIMIT 10;

-- 避免 SELECT *
SELECT user_id, hero_id, is_winner FROM game_players WHERE ...

-- 使用连接而非子查询
SELECT g.*, p.hero_id
FROM game_history g
JOIN game_players p ON g.id = p.game_id
WHERE p.user_id = '...'
```

### 7.3 缓存策略

#### 7.3.1 Redis 使用场景
```lua
-- 在线状态
local key = "online:" .. user_id
redis:setex(key, 300, "1")  -- 5分钟过期

-- 排行榜（每周重置）
redis:zincrby("leaderboard:weekly", points, user_id)
redis:expire("leaderboard:weekly", 604800)

-- 限流
local key = "rate_limit:" .. user_id .. ":" .. api_name
local count = redis:incr(key)
if count == 1 then
    redis:expire(key, 60)  -- 1分钟窗口
end

-- 游戏状态缓存（短期）
local key = "game_state:" .. match_id
redis:setex(key, 300, json.encode(state))
```

#### 7.3.2 缓存失效策略
```lua
-- 主动失效
function update_hero_config(hero_id, config)
    nk.storage_write({...})
    nk.runtime_cache_delete("hero_config:" .. hero_id)
    redis:del("hero_config:" .. hero_id)
end

-- TTL 自动失效
-- 版本号控制
local version = redis:get("config_version")
if not version or version ~= expected_version then
    -- 重新加载配置
end
```

### 7.4 网络优化

#### 7.4.1 消息压缩
```lua
-- 状态同步优化
function broadcast_compact_state(dispatcher, state)
    local compact_state = {
        t = state.current_turn_id,  -- 缩写
        p = {}
    }

    for id, p in pairs(state.players) do
        compact_state.p[id] = {
            h = p.health,  -- health
            c = #p.hand,   -- card count
            r = p.role     -- role
        }
    end

    dispatcher.broadcast_message(10, nk.json_encode(compact_state))
end
```

#### 7.4.2 增量更新
```lua
-- 只发送变化的部分
local last_state = player.last_state
local delta = {}

if last_state.health ~= current.health then
    delta.health = current.health
end

if #last_state.hand ~= #current.hand then
    delta.hand_count = #current.hand
end

if next(delta) then
    dispatcher.send_message(11, nk.json_encode(delta), {presence})
end
```

---

## 8. 安全设计

### 8.1 认证与授权

#### 8.1.1 认证流程
```
客户端 -> 注册/登录 -> Nakama 验证 -> 返回 Session Token
    ↓
Session Token 存储在客户端
    ↓
每次请求携带 Token
    ↓
服务器验证 Token 有效性
```

#### 8.1.2 权限控制
```lua
-- RPC 权限检查
local function buy_hero(context, payload)
    -- 验证用户身份
    if not context.user_id then
        return nk.json_encode({error = "未登录"})
    end

    -- 检查速率限制
    local ok, err = check_rate_limit(context.user_id, "buy_hero")
    if not ok then
        return nk.json_encode({error = "操作过于频繁"})
    end

    -- 执行业务逻辑
    -- ...
end
```

### 8.2 防作弊机制

#### 8.2.1 客户端验证
```lua
-- 出牌验证
function validate_play_card(state, player_id, card_id, target_id)
    local player = state.players[player_id]

    -- 验证回合
    if state.current_turn_id ~= player_id then
        return false, "不是你的回合"
    end

    -- 验证手牌
    local has_card = false
    for _, card in ipairs(player.hand) do
        if card.id == card_id then
            has_card = true
            break
        end
    end

    if not has_card then
        return false, "没有这张牌"
    end

    -- 验证目标
    if target_id and not state.players[target_id] then
        return false, "目标不存在"
    end

    return true
end
```

#### 8.2.2 服务器端权威
```lua
-- 所有游戏逻辑在服务器执行
-- 客户端只负责发送意图，不执行逻辑

-- 错误示例（客户端执行）
-- 客户端发送"我造成了3点伤害"

-- 正确示例（服务器执行）
-- 客户端发送"我使用攻击牌攻击玩家B"
-- 服务器验证、计算、执行伤害
```

#### 8.2.3 数据完整性检查
```lua
-- 游戏状态哈希
function compute_state_hash(state)
    local data = {
        turn = state.current_turn_id,
        players = {}
    }

    for id, p in pairs(state.players) do
        data.players[id] = {
            health = p.health,
            hand_count = #p.hand
        }
    end

    return nk.sha256_hash(nk.json_encode(data))
end

-- 定期验证
if client_state_hash ~= server_state_hash then
    nk.logger_error("状态不同步: " .. match_id)
    -- 发送完整状态重新同步
end
```

### 8.3 安全防护

#### 8.3.1 DDoS 防护
- **CDN 层**: CloudFlare 自动防护
- **速率限制**: API 调用频率限制
- **IP 封禁**: 恶意 IP 自动封禁

#### 8.3.2 SQL 注入防护
```lua
-- 使用参数化查询（Nakama 已内置）
-- 不要拼接 SQL

-- 错误示例
local sql = "SELECT * FROM users WHERE id = '" .. user_id .. "'"

-- 正确示例
local objects = nk.storage_read({{
    collection = "users",
    key = user_id,
    user_id = user_id
}})
```

#### 8.3.3 XSS 防护
```lua
-- 输入验证和过滤
function sanitize_input(input)
    -- 移除 HTML 标签
    input = input:gsub("<", "&lt;"):gsub(">", "&gt;")
    -- 移除特殊字符
    input = input:gsub("[%c%z]", "")
    return input
end

-- 限制输入长度
if #username > 20 then
    return {error = "用户名过长"}
end
```

---

## 9. 扩展性设计

### 9.1 水平扩展

#### 9.1.1 Nakama 集群
```yaml
# Kubernetes 部署示例
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nakama
spec:
  replicas: 3  # 3个副本
  selector:
    matchLabels:
      app: nakama
  template:
    metadata:
      labels:
        app: nakama
    spec:
      containers:
      - name: nakama
        image: heroiclabs/nakama:3.14.0
        ports:
        - containerPort: 7350
        - containerPort: 7351
        env:
        - name: NAKAMA_DATABASE_ADDRESS
          value: "postgres://..."
        - name: NAKAMA_CLUSTER_ENABLED
          value: "true"
```

#### 9.1.2 数据库分片
```sql
-- 按用户 ID 分片
-- 用户 ID 哈希值 0-127 -> Shard 0
-- 用户 ID 哈希值 128-255 -> Shard 1

-- 分片键选择
SELECT * FROM users WHERE id = '...'  -- 直接路由

-- 跨分片查询
-- 使用聚合服务或数据冗余
```

### 9.2 新功能扩展

#### 9.2.1 添加新英雄
```lua
-- 1. 创建英雄模块
-- heroes/new_hero.lua

-- 2. 注册到管理器
-- hero_manager.lua
local heroes = {
    aladdin = require("heroes.aladdin"),
    alibaba = require("heroes.alibaba"),
    saladin = require("heroes.saladin"),
    hakim = require("heroes.hakim"),
    new_hero = require("heroes.new_hero")  -- 新增
}

-- 3. 配置价格和解锁条件
-- config/hero_prices.lua
local HERO_PRICES = {
    new_hero = 2500
}

-- 4. 更新客户端资源
-- 无需重启服务器（热更新）
```

#### 9.2.2 添加新卡牌
```lua
-- 1. 定义卡牌效果
-- game_rules.lua
local CARD_EFFECTS = {
    ["NEW_CARD"] = function(dispatcher, state, source_id, target_id)
        -- 新卡牌逻辑
    end
}

-- 2. 更新牌堆配置
function create_deck()
    local deck = {}
    -- 添加新卡牌
    for i = 1, 3 do
        table.insert(deck, {
            id = "new_" .. i,
            type = "NEW_CARD",
            name = "新卡牌"
        })
    end
    return deck
end
```

### 9.3 插件系统（未来）

#### 9.3.1 插件架构
```lua
-- 插件加载器
local function load_plugin(plugin_name)
    local plugin = require("plugins." .. plugin_name)

    -- 注册钩子
    if plugin.hooks then
        for hook_name, func in pairs(plugin.hooks) do
            register_hook(hook_name, func)
        end
    end

    -- 注册 RPC
    if plugin.rpc then
        for rpc_name, func in pairs(plugin.rpc) do
            nk.register_rpc(func, rpc_name)
        end
    end

    return plugin
end

-- 插件示例
-- plugins/stats_plugin.lua
local M = {
    hooks = {
        on_game_end = function(dispatcher, state)
            -- 统计游戏数据
        end
    },

    rpc = {
        get_detailed_stats = function(context, payload)
            -- 返回详细统计
        end
    }
}

return M
```

---

## 10. 监控与运维

### 10.1 监控指标

#### 10.1.1 系统指标
- **CPU 使用率**: <80%
- **内存使用率**: <80%
- **磁盘使用率**: <70%
- **网络带宽**: <70%

#### 10.1.2 应用指标
- **在线用户数**: 实时在线
- **游戏房间数**: 活跃房间
- **匹配等待时间**: 平均等待时间
- **回合响应时间**: 平均响应时间
- **API 响应时间**: P95, P99
- **错误率**: <0.1%

#### 10.1.3 业务指标
- **日活跃用户 (DAU)**
- **月活跃用户 (MAU)**
- **留存率**: 次日、7日、30日
- **付费转化率**
- **ARPPU**

### 10.2 日志管理

#### 10.2.1 日志分级
```lua
-- DEBUG: 调试信息
nk.logger_debug("玩家出牌: " .. card_id)

-- INFO: 重要信息
nk.logger_info("游戏开始: " .. match_id)

-- WARN: 警告信息
nk.logger_warn("玩家操作频率过高: " .. user_id)

-- ERROR: 错误信息
nk.logger_error("数据库连接失败: " .. err)
```

#### 10.2.2 日志收集
```yaml
# Filebeat 配置
filebeat.inputs:
- type: log
  enabled: true
  paths:
    - /var/log/nakama/*.log
  fields:
    service: nakama
    environment: production

output.elasticsearch:
  hosts: ["elasticsearch:9200"]
  index: "nakama-logs-%{+yyyy.MM.dd}"
```

### 10.3 告警规则

```yaml
# Prometheus 告警规则
groups:
- name: nakama.rules
  rules:
  - alert: HighCPUUsage
    expr: cpu_usage > 80
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "Nakama CPU 使用率过高"

  - alert: HighErrorRate
    expr: error_rate > 0.01
    for: 3m
    labels:
      severity: critical
    annotations:
      summary: "错误率超过 1%"

  - alert: DatabaseDown
    expr: pg_up == 0
    for: 1m
    labels:
      severity: critical
    annotations:
      summary: "数据库连接失败"
```

---

## 11. 容灾与备份

### 11.1 备份策略

#### 11.1.1 数据库备份
```bash
#!/bin/bash
# 每日备份脚本

# PostgreSQL 备份
pg_dump -h localhost -U nakama nakama > /backup/nakama_$(date +%Y%m%d).sql

# 压缩备份
gzip /backup/nakama_$(date +%Y%m%d).sql

# 上传 S3
aws s3 cp /backup/nakama_$(date +%Y%m%d).sql.gz s3://nakama-backups/

# 删除 30 天前的备份
find /backup -name "nakama_*.sql.gz" -mtime +30 -delete
```

#### 11.1.2 配置备份
```bash
# 备份 Nakama 配置和模块
rsync -avz /etc/nakama/ /backup/config/
rsync -avz /nakama/data/modules/ /backup/modules/
```

### 11.2 故障恢复

#### 11.2.1 数据库故障
1. **主库故障**: 提升从库为主库
2. **数据损坏**: 从备份恢复
3. **延迟过高**: 读写分离优化

#### 11.2.2 服务器故障
1. **单节点故障**: 负载均衡自动剔除
2. **集群故障**: 切换到备用集群
3. **数据中心故障**: DNS 切换到备用数据中心

#### 11.2.3 恢复演练
- **每月**: 备份验证
- **每季度**: 故障恢复演练
- **每年**: 全面灾难恢复测试

---

## 12. 附录

### 12.1 术语表
- **Nakama**: Heroic Labs 开发的开源游戏服务器
- **Lua**: 轻量级脚本语言，用于游戏逻辑
- **RPC**: Remote Procedure Call，远程过程调用
- **OpCode**: Operation Code，操作码
- **Match**: 游戏房间/对局
- **Presence**: 在线玩家状态

### 12.2 参考资料
- [Nakama 官方文档](https://heroiclabs.com/docs/nakama/)
- [Lua 5.3 参考手册](https://www.lua.org/manual/5.3/)
- [PostgreSQL 文档](https://www.postgresql.org/docs/)
- [Redis 文档](https://redis.io/documentation)

### 12.3 相关文档
- [产品设计文档](./product_design.md)
- [API 文档](./api.md) (待创建)
- [部署文档](./deployment.md) (待创建)

---

**文档状态**: 初稿
**最后更新**: 2026-03-31
**下次评审**: 2026-04-15

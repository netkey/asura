# Asura 后端接口文档

> 版本：v0.3.0 · 最后更新：2026-05-06  
> 服务端框架：Nakama (Lua Runtime)  
> 所有 RPC 均通过 Nakama 客户端 SDK 调用，需携带有效的用户 Token。

---

## 目录

1. [游戏模式与核心概念](#1-游戏模式与核心概念)
2. [WebSocket 对局消息（OpCode）](#2-websocket-对局消息opcode)
3. [RPC 接口列表](#3-rpc-接口列表)
   - [匹配系统](#31-匹配系统)
   - [英雄系统](#32-英雄系统)
   - [商城系统](#33-商城系统)
   - [皮肤系统](#34-皮肤系统)
   - [充值系统（Apple IAP）](#35-充值系统apple-iap)
   - [赛季与战绩](#36-赛季与战绩)
   - [好友系统](#37-好友系统)
   - [观战系统](#38-观战系统)
   - [成就系统](#39-成就系统)
   - [管理员接口](#310-管理员接口)
4. [存储结构（Storage Schema）](#4-存储结构storage-schema)
5. [成就列表（19 枚）](#5-成就列表19-枚)
6. [关键设计决策](#6-关键设计决策)

---

## 1. 游戏模式与核心概念

### 游戏模式

| 模式 | 人数 | 身份 | 说明 |
|------|------|------|------|
| `pvp` | 2 人 | 无 | 公平对战，双方无身份，先被击败者负 |
| `identity` | 5 人 | 有 | 身份局，主公/忠臣/反贼/内奸四种角色 |

### 身份局胜利条件

| 阵营 | 胜利条件 |
|------|---------|
| 主公（MONARCH）| 消灭所有反贼和内奸 |
| 忠臣（MINISTER）| 与主公共同消灭反贼和内奸 |
| 反贼（REBEL）| 消灭主公 |
| 内奸（TRAITOR）| 最后一个存活 |

### 牌堆构成（96 张）

| 牌型 | 数量 | 说明 |
|------|------|------|
| ATTACK（攻击）| 30 | 基础攻击 |
| DEFENSE（防御）| 15 | 防御攻击 |
| HEAL（治疗）| 8 | 回复 1 点血量 |
| AOE_SANDSTORM（沙尘暴）| 6 | 全场除自己外受 1 点伤害 |
| DRAW_TWO（无中生有）| 8 | 摸 2 张牌 |
| JUDGE_STORM（天谴）| 6 | 延时判定，黑桃 2-9 造成 3 点伤害并传递 |
| WINE（酒）| 6 | 攻击+1 或濒死回 1 血 |
| WEAPON（武器）| 5 | 装备：攻击+1 |
| ARMOR（防具）| 5 | 装备：受到伤害-1 |
| HORSE（马匹）| 4 | 装备：速度加成 |
| INSTANT_TRICK（即时锦囊）| 3 | 随机效果 |
| DELAYED_TRICK（延时锦囊）| 等 | 延时效果 |

---

## 2. WebSocket 对局消息（OpCode）

对局期间通过 Nakama 实时连接收发，客户端连接到 Match 后开始接收。

### 客户端 → 服务端（发送）

| OpCode | 说明 | Payload 示例 |
|--------|------|-------------|
| `3` | 出牌 | `{"card_id":"c_001","target_id":"user-uuid"}` |
| `4` | 手动结束回合 | `{}` |
| `5` | 防御/AOE 响应 | `{"confirm":true}` |

> **安全说明**：OpCode 3/4 服务端会校验发送方是否为当前回合玩家，非当前回合消息将被丢弃。`target_id` 必须是存活玩家，否则出牌无效。

### 服务端 → 客户端（接收）

| OpCode | 触发时机 | Payload 关键字段 |
|--------|---------|----------------|
| `10` | 每次状态变更后广播 | 见下方详细结构 |
| `11` | 游戏事件日志（弃牌、技能、判定等）| `{"content":"..."}` |
| `30` | 对局结束 | `{"winner":"MONARCH_WIN"}` |

#### OpCode 10 Payload 结构

```json
{
  "current_turn": "user-uuid",
  "pending": null,
  "me": {
    "hand": [{"id":"c_001","type":"ATTACK","suit":"SPADE","number":7,"name":"攻击"}],
    "hp": 4,
    "role": "REBEL",
    "equipment": {"weapon": null, "armor": null, "horse": null},
    "delayed_effects": [],
    "weapon_buff": false,
    "skin_id": "aladdin_golden"
  },
  "others": [
    {
      "id": "user-uuid-2",
      "username": "Player2",
      "hp": 3,
      "hand_count": 5,
      "hero": "hakim",
      "role": "UNKNOWN",
      "equipment": {"weapon": null, "armor": null, "horse": null},
      "skin_id": null
    }
  ]
}
```

> **身份迷雾**：`others[].role` 除主公（MONARCH）、已阵亡玩家、对局结束外，均显示为 `"UNKNOWN"`。  
> **皮肤字段**：`skin_id = null` 表示使用默认皮肤，客户端加载 `skins/{hero_id}/default/`。

#### 旁观者 / 重连附加字段

| 场景 | 额外字段 |
|------|---------|
| 旁观者 | `"is_spectator": true`，视野与目标玩家完全一致 |
| 断线重连 | `"is_reconnect": true`，包含完整战场快照 |

---

## 3. RPC 接口列表

所有接口均为 POST，Payload 和返回值均为 JSON。

---

### 3.1 匹配系统

#### `find_or_create_match`
查找或创建一个等待中的对局。

```json
// 入参
{"mode": "pvp", "max_players": 2}

// 出参
{"match_id": "uuid.nakama.xxx"}
```

---

### 3.2 英雄系统

#### `get_hero_shop`
获取英雄商城列表（含玩家拥有状态和活动价格）。

```json
// 无需入参

// 出参
{
  "heroes": [
    {
      "id": "aladdin",
      "name": "阿拉丁",
      "price": 0,
      "tier": 1,
      "description": "...",
      "owned": true,
      "free_until": null
    }
  ]
}
```

#### `buy_hero`
用金币购买英雄。

```json
// 入参
{"hero_id": "hakim"}

// 出参（成功）
{"success": true}

// 出参（失败）
{"success": false, "error": "insufficient_gold | already_owned | 英雄不存在"}
```

#### `check_hero_access`
校验玩家是否可使用某英雄（含限时免费活动）。

```json
// 入参
{"hero_id": "saladin"}

// 出参
{"accessible": true}
```

#### `get_wallet`
查询当前金币余额。

```json
// 出参
{"gold": 1280}
```

---

### 3.3 商城系统

#### `get_shop`
统一商城入口，一次返回全部英雄和皮肤商品（含玩家拥有状态）。

```json
// 无需入参（可选 {"hero_id":"aladdin"} 过滤皮肤）

// 出参
{
  "items": [
    {
      "category": "hero",
      "id": "hakim",
      "name": "哈基姆",
      "price": 100,
      "tier": 2,
      "owned": false,
      "buy_rpc": "buy_hero"
    }
  ],
  "skins": [
    {
      "category": "skin",
      "id": "aladdin_golden",
      "hero_id": "aladdin",
      "name": "黄金神灯",
      "price": 680,
      "asset_url": null,
      "owned": false,
      "buy_rpc": "purchase_skin"
    }
  ]
}
```

> `buy_rpc` 字段指明购买时应调用的 RPC 名，UI 直接使用即可。  
> `asset_url` 当前为 `null`，客户端按本地命名规则加载皮肤资源。

---

### 3.4 皮肤系统

#### 客户端皮肤资源命名约定

```
本地路径：  skins/{hero_id}/{skin_id}/
默认皮肤：  skin_id = null 时加载 skins/{hero_id}/default/
CDN模式：   asset_url 非 null 时从该地址下载资源包（当前均为 null）
```

#### `get_skin_catalog`
获取皮肤商城列表（不含默认皮肤）。

```json
// 入参（可选）
{"hero_id": "aladdin"}

// 出参
{"skins": [{"id":"aladdin_golden","hero_id":"aladdin","name_cn":"黄金神灯","price":680,"asset_url":null}]}
```

#### `get_my_skins`
获取玩家已拥有及已装备的皮肤。

```json
// 出参
{
  "owned": ["aladdin_golden"],
  "equipped": {"aladdin": "aladdin_golden"}
}
```

#### `purchase_skin`
用金币购买皮肤。

```json
// 入参
{"skin_id": "aladdin_golden"}

// 出参
{"success": true, "new_balance": 600}
```

#### `equip_skin`
为英雄装备/卸下皮肤。

```json
// 入参（skin_id=null 表示卸下，恢复默认）
{"hero_id": "aladdin", "skin_id": "aladdin_golden"}

// 出参
{"success": true}
```

---

### 3.5 充值系统（Apple IAP）

#### `verify_iap_receipt`
验证 Apple IAP 购买凭据并发放金币。

```json
// 入参
{
  "product_id": "com.asura.gold_648",
  "receipt_data": "<base64 receipt string>"
}

// 出参（成功）
{"success": true, "gold_granted": 648, "new_balance": 1928}

// 出参（失败）
{"success": false, "error": "duplicate_transaction | invalid_receipt | unknown_product"}
```

**金币充值档位：**

| product_id | 金币数量 |
|------------|---------|
| `com.asura.gold_60` | 60 |
| `com.asura.gold_198` | 198 |
| `com.asura.gold_648` | 648 |
| `com.asura.gold_1998` | 1998 |

> **防重放**：服务端记录每个 `transaction_id`（全局唯一），同一凭据只能兑换一次。  
> **环境变量**：需在部署时配置 `APPLE_IAP_SECRET`（App Shared Secret）。

---

### 3.6 赛季与战绩

#### `get_season_info`
获取当前赛季信息。

```json
// 出参
{"season": {"season_id": "s1", "leaderboard_id": "lb1"}}
```

#### `get_my_stats`
获取玩家当前赛季统计。

```json
// 出参
{
  "stats": {
    "games": 42, "wins": 28, "losses": 14,
    "rating": 1350, "best_streak": 7, "current_streak": 3,
    "hero_stats": {"aladdin": {"games": 15, "wins": 10}},
    "role_stats": {"MONARCH": {"games": 5, "wins": 4}}
  }
}
```

#### `get_match_history`
获取对局历史记录（最近 50 场）。

```json
// 出参
{
  "history": [
    {
      "timestamp": 1746000000, "mode": "pvp", "hero": "aladdin",
      "result": "WIN", "rating_change": 10, "rating_after": 1350,
      "damage_dealt": 12, "damage_received": 8
    }
  ]
}
```

#### `get_leaderboard`
获取赛季排行榜（前 100 名）。

```json
// 出参
{"records": [{"rank": 1, "username": "PlayerA", "score": 1800}]}
```

---

### 3.7 好友系统

#### `add_friend`
发送好友申请或接受申请。

```json
{"user_id": "target-uuid"}
```

#### `remove_friend` / `block_user`

```json
{"user_id": "target-uuid"}
```

#### `get_friends`
获取好友列表。

```json
// 入参（可选 state 过滤：0=好友 1=我发出 2=对方发来 3=屏蔽）
{"state": 0}

// 出参
{"friends": [{"user_id": "...", "username": "PlayerA", "state": 0}]}
```

#### `get_friends_status`
获取所有好友的在线/对局状态（含 match_id，支持直接加入或观战）。

```json
// 出参
{
  "friends": [
    {
      "user_id": "...",
      "username": "PlayerA",
      "status": "playing",
      "match_id": "uuid.nakama.xxx",
      "mode": "pvp",
      "current_players": 2,
      "max_players": 2
    }
  ]
}
```

**`status` 字段说明及客户端响应：**

| status | 含义 | 推荐客户端行为 |
|--------|------|--------------|
| `idle` | 空闲 | 显示「邀请」按钮，调 `invite_to_match` |
| `waiting` | 等待中，对局未满 | 显示「加入」按钮，用 `match_id` 直接加入 |
| `playing` | 游戏中 | 显示「观战」按钮，用 `match_id` + `is_spectator=true` 加入 |

> **实时推送**：服务端状态变更时调用 `nk.status_update`，客户端通过 WebSocket `StatusFollow` 实时接收，无需轮询。  
> **兜底方案**：进入好友列表页时调用一次 `get_friends_status` 同步最新状态。

**客户端订阅好友状态（WebSocket）：**

```
// 登录后发送一次，订阅所有好友的状态变更
StatusFollow { user_ids: ["friend-uuid-1", "friend-uuid-2", ...] }

// 监听服务端推送
onStatusPresenceEvent(event) → JSON.parse(event.joins[i].status) → 更新 UI
```

#### `invite_to_match`
邀请好友加入对局（发送站内通知，code=1）。

```json
{"user_id": "target-uuid", "match_id": "uuid.nakama.xxx"}
```

---

### 3.8 观战系统

#### `find_spectatable_match`
查询当前可观战的对局列表。

```json
// 入参（可选）
{"mode": "pvp"}

// 出参
{"matches": [{"match_id": "...", "mode": "pvp", "player_count": 2}]}
```

**加入观战（通过 Nakama 客户端 SDK）：**

```
// metadata 中携带观战标记和目标玩家
JoinMatch(match_id, metadata={"is_spectator": true, "target_player_id": "user-uuid"})
```

---

### 3.9 成就系统

#### `get_my_achievements`
获取玩家已解锁成就（含解锁时间）。

```json
// 出参
{
  "unlocked": {
    "first_win": {"unlocked_at": 1746000000},
    "hero_mastery_10": {"unlocked_at": 1746100000, "heroes": ["aladdin"]}
  }
}
```

#### `get_achievement_list`
获取全部成就定义及玩家解锁状态。

```json
// 出参
{
  "achievements": [
    {"id": "first_win", "name": "初出茅庐", "gold": 100, "unlocked": true, "unlocked_at": 1746000000},
    {"id": "streak_5",  "name": "锐不可当", "gold": 150, "unlocked": false}
  ]
}
```

> 成就解锁时自动发放金币奖励并推送站内通知（code=2）。

---

### 3.10 管理员接口

> 以下接口仅限通过 Nakama HTTP Key 调用，客户端调用将被拒绝。

| RPC | 说明 | 关键入参 |
|-----|------|---------|
| `admin_grant_gold` | 手动发放金币 | `{"user_id":"...","amount":100}` |
| `admin_set_free_event` | 设置限时免费英雄活动 | `{"heroes":["hakim"],"start_time":ts,"end_time":ts}` |
| `admin_set_config` | 更新游戏参数配置 | 见 game_config.lua |
| `admin_start_season` | 开启新赛季 | `{"season_id":"s2","leaderboard_id":"lb2"}` |
| `admin_end_season` | 结束当前赛季 | `{}` |

---

## 4. 存储结构（Storage Schema）

| collection | key | user_id | 说明 |
|-----------|-----|---------|------|
| `hero_inventory` | `unlocked_heroes` | uid | 已解锁英雄集合 `{hero_id: true}` |
| `skin_inventory` | `owned_skins` | uid | 已购皮肤列表 `[skin_id, ...]` |
| `skin_inventory` | `equipped_skins` | uid | 各英雄装备皮肤 `{hero_id: skin_id}` |
| `achievements` | `unlocked` | uid | 已解锁成就 `{ach_id: {unlocked_at}}` |
| `season_stats` | `{season_id}` | uid | 赛季积分/胜负/连胜等统计 |
| `match_history` | `{season_id}_{ts}` | uid | 单场对局记录（最多保留 50 条）|
| `user_status` | `current_match` | uid | 当前对局状态（等待/游戏中），供好友查询 |
| `iap_receipts` | `{transaction_id}` | nil | IAP 防重放记录（全局） |
| `season_config` | `current` | nil | 当前赛季配置（管理员写入） |
| `events` | `free_heroes` | nil | 限时免费英雄活动配置 |

---

## 5. 成就列表（19 枚）

| ID | 名称 | 解锁条件 | 金币奖励 |
|----|------|---------|---------|
| `first_win` | 初出茅庐 | 首次赢得对局 | 100 |
| `pvp_first_win` | 擂台初鸣 | PVP 模式首胜 | 50 |
| `identity_first_win` | 身份初显 | 身份局首胜 | 50 |
| `streak_3` | 势如破竹 | 达成 3 连胜 | 80 |
| `streak_5` | 锐不可当 | 达成 5 连胜 | 150 |
| `streak_10` | 战无不胜 | 达成 10 连胜 | 500 |
| `games_10` | 初涉江湖 | 累计对局 10 场 | 50 |
| `games_50` | 身经百战 | 累计对局 50 场 | 200 |
| `games_100` | 沙场老将 | 累计对局 100 场 | 500 |
| `games_500` | 戎马半生 | 累计对局 500 场 | 1500 |
| `games_1000` | 千战不殆 | 累计对局 1000 场 | 5000 |
| `win_as_monarch` | 君临天下 | 以主公身份胜利 | 100 |
| `win_as_rebel` | 揭竿而起 | 以反贼身份胜利 | 100 |
| `win_as_traitor` | 孤注一掷 | 以内奸身份胜利 | 200 |
| `hero_mastery_10_{hero_id}` | {英雄}专精 | 该英雄赢 10 场（每英雄独立一枚）| 150 |
| `hero_mastery_25_{hero_id}` | {英雄}大师 | 该英雄赢 25 场（每英雄独立一枚）| 400 |
| `damage_single_20` | 破阵斩将 | 单场造成伤害 ≥ 20 | 100 |
| `rating_1200` | 崭露头角 | 赛季积分达到 1200 | 150 |
| `rating_1500` | 声名大噪 | 赛季积分达到 1500 | 300 |

---

## 6. 关键设计决策

### 6.1 服务端安全原则
- **价格从不信任客户端**：`buy_hero`/`purchase_skin` 均从服务端 catalog 读取价格，客户端无法通过修改包体改价。
- **拥有状态从不信任客户端**：拥有校验均通过 `nk.storage_read` 服务端读取，`get_shop` 返回的 `owned` 字段仅供展示。
- **回合归属校验**：OpCode 3（出牌）和 4（结束回合）服务端校验 `uid == current_turn_id`，防止非回合玩家操作。
- **Storage 写权限**：所有用户数据 `permission_write = 0`，客户端无法绕过 RPC 直接写入。

### 6.2 观战视野设计
旁观者与目标玩家视野完全一致（相同的身份迷雾规则），防止通过观战获取作弊信息。每个旁观者绑定一个目标玩家，收到与目标相同的 OpCode 10 payload。

### 6.3 皮肤系统前向兼容
`skin_catalog.lua` 中每套皮肤预留 `asset_url` 字段（当前为 `null`）。早期皮肤资源随客户端打包，按 `skins/{hero_id}/{skin_id}/` 路径加载。后期切换 CDN 时，只需服务端填写 `asset_url`，客户端代码无需修改。

### 6.4 IAP 防重放
Apple IAP `transaction_id` 以 `user_id=nil` 全局存储，防止同一凭据跨账号重复兑换。写入防重放记录和发放金币顺序为：先写记录，再发金币（保守顺序，极端情况下补发由运营手工处理）。

### 6.5 好友状态双轨机制
- **主路径**：服务端状态变更时调用 `nk.status_update`，好友通过 WebSocket `StatusFollow` 实时接收（零轮询，毫秒级延迟）。
- **兜底路径**：客户端进入好友列表页时主动调用 `get_friends_status` RPC，覆盖断线重连后的状态同步。

### 6.6 货币体系
单一金币体系（`wallet.gold`），来源：IAP 充值、成就奖励；消耗：购买英雄、购买皮肤。  
*待规划*：每日任务奖励金币、英雄碎片兑换英雄。

---

## 待规划功能

| 功能 | 状态 | 备注 |
|------|------|------|
| 每日任务系统 | 规划中 | 奖励方案待确认，倾向单一金币体系 |
| 英雄碎片系统 | 规划中 | F2P 解锁英雄路径，与碎片独立性待确认 |

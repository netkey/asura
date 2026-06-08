# Asura 后端接口文档

> 版本：v0.6.0 · 最后更新：2026-06-08  
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
   - [账号管理](#36-账号管理)
   - [赛季与战绩](#37-赛季与战绩)
   - [好友系统](#38-好友系统)
   - [观战系统](#39-观战系统)
   - [成就系统](#310-成就系统)
   - [管理员接口](#311-管理员接口)
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

### 牌堆构成（122 张）

| 牌型 | 数量 | 说明 |
|------|------|------|
| ATTACK（杀/大马士革弯刀）| 30 | 需在武器射程内，每回合限1次（连弩机除外） |
| DEFENSE（闪/蜃景）| 15 | 抵消一次攻击 |
| HEAL（桃/椰枣）| 8 | 回复 1 点血量 |
| WINE（沙漠之心）| 3 | 增伤：出牌阶段使用，下次杀伤害+1；濒死自救 |
| INSTANT_TRICK（即时锦囊）| 36 | 见下方子类型表 |
| DELAYED_TRICK（延时锦囊）| 7 | 乐不思蜀×3/兵粮寸断×2/闪电×2 |
| WEAPON（武器）| 9 | 连弩机/贯石斧/青龙偃月刀/丈八蛇矛/方天画戟/古锭刀/双刃剑/朱雀羽扇/麒麟弓 |
| ARMOR（防具）| 3 | 八卦阵/仁王盾/藤甲 |
| HORSE（马匹）| 8 | 阿拉伯战马（进攻马-1距离）×4 / 骆驼（防守马+1距离）×4 |

#### INSTANT_TRICK 子类型

| subtype | 中文名 | 数量 | 效果 |
|---------|--------|------|------|
| aoe_attack | 沙漠侵袭（南蛮入侵）| 3 | 全场需出【杀】，否则1点伤害 |
| aoe_defense | 万箭齐发 | 3 | 全场需出【闪】，否则1点伤害 |
| duel | 决斗 | 3 | 轮流出【杀】，放弃者受1点伤害 |
| discard_one | 过河拆桥 | 4 | 弃目标一张牌（手牌或装备）|
| steal_one | 顺手牵羊 | 4 | 获得目标一张牌（距离1内）|
| draw_two | 无中生有 | 4 | 摸2张牌 |
| mass_heal | 桃园结义 | 2 | 全场角色各回复1点生命 |
| mass_draw | 五谷丰登 | 2 | 按座次顺序各摸1张牌 |
| counterspell | 无懈可击 | 3 | 抵消一张锦囊牌（在响应窗口中使用）|
| borrow_weapon | 借刀杀人 | 2 | 借目标武器对另一角色出杀，否则武器归你 |
| fire_attack | 火攻 | 3 | 目标展示一张手牌，猜中花色则1点火焰伤害 |
| iron_chain | 铁索连环 | 6 | 连环目标（属性伤害传导）或重铸（弃牌摸1）|

---

## 2. WebSocket 对局消息（OpCode）

对局期间通过 Nakama 实时连接收发，客户端连接到 Match 后开始接收。

### 客户端 → 服务端（发送）

| OpCode | 说明 | Payload 示例 |
|--------|------|-------------|
| `3` | 出牌 | `{"card_id":"c_001","target_id":"user-uuid"}` |
| `4` | 手动结束回合 | `{}` |
| `5` | 防御/AOE/救援 响应 | `{"confirm":true}` 或 `{"confirm":true,"card_id":"c_002"}` |

**OpCode 5 详细说明：**

| 场景 | 服务端 `pending.type` | 客户端应发送 |
|------|----------------------|------------|
| 出示【防御】 | `WAITING_FOR_DEFENSE` | `{"confirm":true}` |
| 放弃防御 | `WAITING_FOR_DEFENSE` | `{"confirm":false}` |
| AOE 出示防御 | `WAITING_FOR_AOE` | `{"confirm":true}` |
| AOE 放弃防御 | `WAITING_FOR_AOE` | `{"confirm":false}` |
| 救援（出桃/酒）| `WAITING_FOR_RESCUE` | `{"confirm":true,"card_id":"c_002"}` |
| 放弃救援 | `WAITING_FOR_RESCUE` | `{"confirm":false}` |
| 决斗出【杀】 | `WAITING_FOR_DUEL` | `{"confirm":true,"card_id":"c_002"}` 或 `{"confirm":false}` |
| 无懈可击响应 | `WAITING_FOR_COUNTER` | `{"confirm":true,"card_id":"c_002"}`（无懈可击）或 `{"confirm":false}` |
| 过河拆桥/顺手牵羊选牌 | `WAITING_FOR_TRICK_SELECT` | `{"confirm":true,"card_id":"c_07"}` 或 `{"confirm":false}`（随机） |
| 借刀杀人选攻击目标 | `WAITING_FOR_TRICK_SELECT` | `{"confirm":true,"target_id":"uid"}` 或 `{"confirm":false}` |
| 借刀杀人出杀或交武器 | `WAITING_FOR_BORROW_WEAPON` | `{"confirm":true,"card_id":"c_02"}`（出杀）或 `{"confirm":false}`（交武器） |
| 火攻猜花色 | `WAITING_FOR_FIRE_GUESS` | `{"confirm":true,"guess":"HEART"}`（HEART/SPADE/CLUB/DIAMOND）|
| 英雄技能确认+选目标 | `SULEIMAN_CHI_LING` / `HARUN_CHOOSE` / `ALIBABA_COUNTER` 等 | `{"confirm":true,"target_id":"uid"}` 或 `{"confirm":false}` |
| 哈基姆【星象】重排牌堆 | `HAKIM_XING_XIANG` | `{"confirm":true,"sorted_ids":["c_01","c_02"]}` 或 `{"confirm":false}` |
| 弃牌阶段选牌 | `WAITING_FOR_DISCARD` | `{"confirm":true,"card_ids":["c_01","c_03"]}` 或 `{"confirm":false}`（服务端自动从末尾弃） |

> **超时自动处理**：各等待阶段均有 deadline（DEFENSE/AOE 15s，RESCUE 10s，DISCARD 等同回合超时 30s），超时后服务端自动以 `confirm=false` 推进。弃牌阶段若玩家在线且非托管模式，服务端先发 OpCode 106 `discard_required` 事件等待玩家选择；离线或托管模式直接从手牌末尾自动弃牌。

> **安全说明**：OpCode 3/4 服务端会校验发送方是否为当前回合玩家，非当前回合消息将被丢弃。`target_id` 必须是存活玩家，否则出牌无效。

### 服务端 → 客户端（接收）

#### 广播（所有玩家）

| OpCode | 触发时机 | Payload 示例 |
|--------|---------|-------------|
| `10` | 每次状态变更后广播全量状态 | 见下方详细结构 |
| `11` | 游戏事件日志（弃牌、技能发动、判定、死亡等文本） | `{"content":"萨拉丁 受到1点伤害","event":"skill_used","hero":"saladin"}` |
| `20` | 伤害结算时广播（动画驱动） | `{"event":"damage","target":"uid-B","source":"uid-A","amount":1}` |
| `30` | 对局结束 | `{"winner":"MONARCH_WIN"}` |
| `105` | 攻击或 AOE 命中某玩家，该玩家需要响应（广播全场，非目标玩家可播放攻击动画） | `{"attacker":"uid-A","target":"uid-B","damage":1,"msg":"受到攻击，请出示【防御】"}` |

#### 私发（仅发给特定玩家）

| OpCode | 接收方 | 触发时机 | Payload 示例 |
|--------|--------|---------|-------------|
| `101` | 技能使用者或目标玩家 | 英雄技能询问，如苏莱曼【敕令】、哈伦【哈里发令】、阿里巴巴【暗号】 | `{"type":"skill_choice","skill":"chi_ling","description":"是否发动【敕令】？","targets":[...],"block_types":[{"type":"ATTACK","label":"攻击"},{"type":"HEAL","label":"治疗"}]}` |
| `106` | 锦囊使用者或技能目标 | 锦囊牌选牌/选目标的私有信息 / 弃牌阶段选牌 | 过河拆桥/顺手牵羊: `{"event":"pick_target_card","target_id":"uid","hand":[...],"equipment":...,"purpose":"discard\|steal"}` / 借刀杀人: `{"event":"choose_attack_target","valid_targets":[...],"purpose":"borrow_weapon"}` / 火攻: `{"event":"fire_guess","target_hand":"HEART"}` / 弃牌: `{"event":"discard_required","player_id":"uid","discard_count":2,"msg":"需要弃置 2 张牌"}` |

> **接收 101 时客户端需弹出英雄技能交互面板**；玩家决策后通过 **OpCode 5**（confirm + 可选 target_id / card_id / sorted_ids）回传。超时由服务端以 `confirm=false` 自动推进。

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
    "skin_id": "aladdin_golden",
    "seat_idx": 1
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
      "skin_id": null,
      "seat_idx": 2
    }
  ]
}
```

> **身份迷雾**：`others[].role` 除主公（MONARCH）、已阵亡玩家、对局结束外，均显示为 `"UNKNOWN"`。  
> **皮肤字段**：`skin_id = null` 表示使用默认皮肤，客户端加载 `skins/{hero_id}/default/`。  
> **座次字段**：`seat_idx` 为玩家在环上的位置索引（1-based），结合全场玩家的 `seat_idx` 和 `equipment` 可在本地计算出攻击距离（见下方 [攻击距离预检](#攻击距离预检)）。

#### 攻击距离预检

客户端可在发出攻击前通过本地计算判断目标是否在射程内，避免无效网络请求（尤其在残局短兵器够不到远处目标时）。所有必要数据（`seat_idx`、`equipment.weapon.subtype`、`equipment.horse.subtype`）均在 OpCode 10 中下发。

**步骤 1：环上最短距离（seat_distance）**

将全场存活玩家（`me` + `others`）按 `seat_idx` 升序排列成环：

```
n = 存活玩家总数
diff = |attacker.seat_idx - target.seat_idx|
seat_distance = min(diff, n - diff)
```

**步骤 2：有效距离（effective_distance）**

```
effective_distance = seat_distance
                   - (攻击方有进攻马 ? 1 : 0)    // horse.subtype == "offense"
                   + (防御方有防御马 ? 1 : 0)    // horse.subtype == "defense"
```

**步骤 3：武器射程（weapon_range）**

取攻击方 `equipment.weapon.subtype`，查下表（无武器时取 1）：

| weapon.subtype | 射程 | 对应武器 |
|----------------|------|---------|
| `null`（无武器） | 1 | — |
| `unlimited_attack` | 1 | 连弩机（诸葛连弩） |
| `reattempt_discard2` | 2 | 贯石斧 |
| `reattempt_attack` | 2 | 青龙偃月刀 |
| `spear_discard2` | 2 | 丈八蛇矛 |
| `ignore_armor` | 2 | 双刃剑（双股剑） |
| `bow_strip_horse` | 3 | 麒麟弓 |
| 未知 subtype | 1 | 安全回退 |

**步骤 4：判定**

```
可以攻击 ⇔ effective_distance ≤ weapon_range
```

**特殊情况**

- **双角王【远疆-西行】**：激活时（`state.dhul_westward[attacker_id]` 为 true），本回合攻击**无视距离限制**（等同于 `weapon_range = ∞`）。客户端需自行跟踪该 flag（可通过英雄技能广播推断状态）。
- **【顺手牵羊】**：要求 `effective_distance ≤ 1`（武器射程不适用），即距离 1 内（不含自身）。

**示例代码（Lua 伪码）：**

```lua
local WEAPON_RANGES = {
    unlimited_attack = 1, reattempt_discard2 = 2, reattempt_attack = 2,
    spear_discard2 = 2, ignore_armor = 2, bow_strip_horse = 3,
}

local function can_attack_client(me, target, all_players)
    -- 环距离
    local n = #all_players
    local diff = math.abs(me.seat_idx - target.seat_idx)
    local dist = math.min(diff, n - diff)

    -- 马匹修正
    if me.equipment.horse and me.equipment.horse.subtype == "offense" then
        dist = math.max(0, dist - 1)
    end
    if target.equipment.horse and target.equipment.horse.subtype == "defense" then
        dist = dist + 1
    end

    -- 武器射程
    local subtype = me.equipment.weapon and me.equipment.weapon.subtype
    local range = WEAPON_RANGES[subtype] or 1

    return dist <= range
end
```

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
{"success": false, "error": "insufficient_gold | already_owned | 英雄不存在 | conflict_retry | too_many_requests"}
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

// 出参（成功）
{"success": true, "new_balance": 600}

// 出参（失败）
{"success": false, "error": "insufficient_gold | already_owned | skin_not_found | default_skin | conflict_retry | too_many_requests"}
```

#### `equip_skin`
为英雄装备/卸下皮肤。

```json
// 入参（skin_id=null 表示卸下，恢复默认）
{"hero_id": "aladdin", "skin_id": "aladdin_golden"}

// 出参（成功）
{"success": true}

// 出参（失败）
{"success": false, "error": "bad_request | skin_not_found | wrong_hero | not_owned | conflict_retry"}
```

> `conflict_retry`：并发写冲突（OCC），客户端重试即可。

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
{"success": false, "error": "duplicate_transaction | invalid_receipt | unknown_product | iap_secret_not_configured | too_many_requests"}
```

**金币充值档位（Apple / Google 共用）：**

| product_id | 金币数量 |
|------------|---------|
| `com.asura.gold_60` | 60 |
| `com.asura.gold_198` | 198 |
| `com.asura.gold_648` | 648 |
| `com.asura.gold_1998` | 1998 |

> **防重放**：OCC insert-only（`version="*"`）写入，消除并发重复兑换 TOCTOU 漏洞；同一 `transaction_id` 只能兑换一次。  
> **环境变量**：需在部署时配置 `APPLE_IAP_SECRET`（App Shared Secret），缺失时返回 `iap_secret_not_configured`。  
> **限流**：每用户每分钟最多 5 次调用，超限返回 `too_many_requests`。

---

### 3.5b 充值系统（Google Play IAP）

#### `verify_google_iap_receipt`
验证 Google Play 购买凭据并发放金币。

```json
// 入参
{
  "product_id": "com.asura.gold_648",
  "purchase_token": "<Google Play purchase token>"
}

// 出参（成功）
{"success": true, "gold_granted": 648, "new_balance": 1928}

// 出参（失败）
{"success": false, "error": "duplicate_transaction | google_credentials_not_configured | google_api_error_xxx | purchase_not_completed | unknown_product | too_many_requests"}
```

> **验证方式**：通过 Google Play Developer API（`purchases.products.get`）服务端验证 `purchaseState == 0`（已完成），`orderId` 作为全局唯一交易 ID 用于防重放。  
> **OAuth Token 缓存**：access_token 缓存于 `system_config/google_token`，到期前 60s 自动刷新；缓存失效时自动重新获取。  
> **环境变量**：需配置 `GOOGLE_CLIENT_ID`、`GOOGLE_CLIENT_SECRET`、`GOOGLE_REFRESH_TOKEN`（Google Play Console → API access → Service account OAuth credentials）。  
> **防重放 / 限流**：与 Apple IAP 共用同一套 `iap_receipts` 防重放表和 5次/分钟 限流。

#### `admin_refresh_google_token`（管理员）
强制清除并刷新 Google OAuth access token 缓存（仅限 Nakama HTTP Key 调用）。

```json
// 出参（成功）
{"success": true}
// 出参（失败）
{"success": false, "error": "google_credentials_not_configured | google_token_refresh_failed_xxx"}
```

#### `get_iap_history`
获取当前用户所有充值记录（Apple + Google，按时间倒序）。

```json
// 出参
{
  "records": [
    {
      "transaction_id": "txn_abc123",
      "product_id": "com.asura.gold_648",
      "gold_granted": 648,
      "verified_at": 1746000000,
      "environment": "production",
      "platform": "android"
    }
  ]
}
```

> `platform` 字段：`"android"` 为 Google Play 充值，Apple IAP 记录无此字段。

---

### 3.6 账号管理

#### `delete_account`
永久删除玩家所有游戏数据并注销 Nakama 账号（Apple/Google 审核要求）。

> **不可逆**：操作完成后账号无法恢复。客户端需在调用前弹出确认对话框。  
> **保留数据**：全局防重放记录（`iap_receipts`）保留用于审计，不随账号删除。

```json
// 无需入参

// 出参（成功）
{"success": true}

// 出参（失败）
{"success": false, "error": "内部错误，请重试"}
```

---

### 3.7 赛季与战绩

#### `get_season_info`
获取当前赛季信息。

```json
// 出参（活跃）
{"active": true, "season": {"season_id": "2026_Q2", "name": "2026年第二赛季", "start_time": 1746057600, "end_time": 1753833600, "leaderboard_id": "season_2026_Q2"}}

// 出参（无赛季）
{"active": false}
```

#### `get_my_stats`
获取玩家当前赛季统计。

```json
// 出参
{
  "stats": {
    "season_id": "2026_Q2",
    "games": 42, "wins": 28, "losses": 14,
    "pvp_wins": 18, "identity_wins": 10,
    "rating": 1350, "best_streak": 7, "current_streak": 3,
    "hero_stats": {"aladdin": {"games": 15, "wins": 10}},
    "role_stats": {"MONARCH": {"games": 5, "wins": 4}}
  }
}
```

#### `get_match_history`
获取对局历史记录（最近 50 场，按时间倒序）。

```json
// 出参
{
  "season_id": "2026_Q2",
  "records": [
    {
      "timestamp": 1746000000, "mode": "pvp", "hero": "aladdin",
      "result": "WIN", "rating_change": 10, "rating_after": 1350,
      "damage_dealt": 12, "damage_received": 8
    }
  ]
}
```

#### `get_leaderboard`
获取赛季排行榜（默认前 20 名，最多 100 名）。

```json
// 入参（可选）
{"limit": 20}

// 出参
{"season_id": "2026_Q2", "leaderboard": [{"rank": 1, "user_id": "xxx", "username": "PlayerA", "rating": 1800}]}
```

---

### 3.8 好友系统

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

> **限流**：每用户每分钟最多 20 次调用，超限返回 `{"success":false,"error":"too_many_requests"}`。

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
> **限流**：每用户每分钟最多 20 次调用，超限返回 `{"success":false,"error":"too_many_requests"}`。

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

### 3.9 观战系统

#### `find_spectatable_match`
查询当前可观战的对局列表。

```json
// 入参（可选，mode 仅接受 "pvp" 或 "identity"）
{"mode": "pvp"}

// 出参
{"matches": [{"match_id": "...", "mode": "pvp", "player_count": 2}]}

// 出参（失败）
{"success": false, "error": "invalid_mode"}
```

**加入观战（通过 Nakama 客户端 SDK）：**

```
// metadata 中携带观战标记和目标玩家
JoinMatch(match_id, metadata={"is_spectator": true, "target_player_id": "user-uuid"})
```

**加入对局时选择英雄（通过 Nakama 客户端 SDK）：**

```
// metadata 中携带英雄 ID，服务端校验已解锁后生效；未携带或不合法则默认使用阿拉丁
JoinMatch(match_id, metadata={"hero_id": "hakim"})
```

---

### 3.10 成就系统

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

### 3.11 管理员接口

> 以下接口仅限通过 Nakama HTTP Key 调用，客户端调用将被拒绝。

| RPC | 说明 | 关键入参 |
|-----|------|---------|
| `admin_grant_gold` | 手动发放金币 | `{"user_id":"...","amount":100}` |
| `admin_set_free_event` | 设置限时免费英雄活动 | `{"heroes":["hakim"],"start_time":ts,"end_time":ts}` |
| `admin_set_config` | 更新游戏参数配置 | 见 game_config.lua |
| `admin_start_season` | 开启新赛季（按 start_time 自动生成季度 ID） | `{"name":"2026年第二赛季","start_time":1746057600,"end_time":1753833600}` |
| `admin_end_season` | 结束当前赛季 | `{}` |
| `admin_refresh_google_token` | 强制刷新 Google OAuth token 缓存 | `{}` |

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
| `iap_receipts` | `{transaction_id}` | nil | IAP 防重放记录（Apple+Google 共用，永久保留） |
| `iap_history` | `{transaction_id}` | uid | 用户 IAP 充值历史（`get_iap_history` 查询） |
| `rate_limits` | `{action}` | uid | 接口调用频率窗口计数（临时） |
| `season_config` | `current` | nil | 当前赛季配置（管理员写入） |
| `events` | `free_heroes` | nil | 限时免费英雄活动配置 |
| `system_config` | `google_token` | nil | Google OAuth access_token 缓存（含 expires_at） |

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

### 6.4 IAP 防重放（OCC）
Apple IAP `transaction_id` 以 `user_id=nil` 全局存储，防止同一凭据跨账号重复兑换。使用 OCC `version="*"` 写入（仅当记录不存在时成功），消除并发请求同时通过读检查的 TOCTOU 窗口。写入防重放记录和发放金币顺序为：先写记录，再发金币（保守顺序，极端情况下补发由运营手工处理）。

### 6.5 好友状态双轨机制
- **主路径**：服务端状态变更时调用 `nk.status_update`，好友通过 WebSocket `StatusFollow` 实时接收（零轮询，毫秒级延迟）。
- **兜底路径**：客户端进入好友列表页时主动调用 `get_friends_status` RPC，覆盖断线重连后的状态同步。

### 6.6 濒死求救流程（WAITING_FOR_RESCUE）
当玩家 HP 降至 0 时，不立即死亡，而是进入濒死状态。从该玩家的下一个存活玩家开始，依次询问是否出手救援（桃/酒）：
- 救援成功：目标 HP 恢复至 1，游戏继续（AOE 中触发时，救援结束后恢复 AOE 推进）
- 所有人放弃：正式处决（弃牌、奖惩结算）
- 每位救援者有 10 秒响应时间，超时自动视为放弃

响应格式：`{"confirm":true,"card_id":"桃/酒的card_id"}` 或 `{"confirm":false}`

### 6.7 货币体系
单一金币体系（`wallet.gold`），来源：IAP 充值、成就奖励；消耗：购买英雄、购买皮肤。  
*待规划*：每日任务奖励金币、英雄碎片兑换英雄。

---

## 待规划功能

| 功能 | 状态 | 备注 |
|------|------|------|
| 每日任务系统 | 规划中 | 奖励方案待确认，倾向单一金币体系 |
| 英雄碎片系统 | 规划中 | F2P 解锁英雄路径，与碎片独立性待确认 |

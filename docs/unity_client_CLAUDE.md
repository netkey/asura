# Asura Unity Client — CLAUDE.md

## 项目概述

Asura 客户端，基于中东神话的多人在线卡牌游戏（类三国杀）。  
服务端为 Nakama (Lua Runtime)，客户端通过 Nakama Unity SDK 与服务端交互。

**服务端接口完整文档**：`docs/server_api.md`（从服务端仓库同步，只读，勿手改）  
服务端仓库地址：`github.com/netkey/asura`

---

## 技术栈

| 层 | 技术 |
|----|------|
| 引擎 | Unity 2022.3 LTS |
| 网络 | Nakama Unity SDK (`io.heroiclabs.nakama-unity` 3.x) |
| 语言 | C# 9，async/await 全链路异步 |
| UI | Unity UI Toolkit（优先）或 uGUI |
| 序列化 | Newtonsoft.Json（SDK 自带），禁止用 `JsonUtility`（不支持 null 字段） |
| 资产管理 | Addressables |

---

## 项目结构

```
Assets/
├── Scripts/
│   ├── Network/
│   │   ├── NakamaManager.cs         # 单例：连接、认证、Session 管理
│   │   ├── MatchSocket.cs           # WebSocket 收发、OpCode 分发
│   │   └── RpcClient.cs             # 封装所有 RPC 调用（对应 server_api.md §3）
│   ├── Game/
│   │   ├── MatchState.cs            # 本地状态镜像（对应 OpCode 10 payload）
│   │   ├── MatchController.cs       # 游戏主控：驱动 UI 响应状态变更
│   │   ├── PendingActionHandler.cs  # 根据 pending.type 弹出对应交互面板
│   │   └── CardPlayValidator.cs     # 出牌合法性预校验（服务端仍是最终裁判）
│   ├── UI/
│   │   ├── Panels/
│   │   │   ├── HandPanel.cs         # 手牌区
│   │   │   ├── PlayerSeatPanel.cs   # 玩家席位（血量、装备、身份）
│   │   │   ├── DefensePanel.cs      # 防御/AOE 响应弹窗
│   │   │   ├── RescuePanel.cs       # 濒死救援弹窗
│   │   │   ├── HeroSkillPanel.cs    # 英雄技能交互弹窗（OpCode 100/101/102）
│   │   │   └── TrickSelectPanel.cs  # 锦囊牌选择弹窗（OpCode 106）
│   │   └── HUD/
│   │       ├── EventLogView.cs      # 事件日志滚动（OpCode 11）
│   │       └── TurnTimerView.cs     # 回合倒计时
│   ├── Hero/
│   │   └── HeroSkillConfig.cs       # 英雄技能 UI 配置（图标、描述、交互类型）
│   └── Common/
│       ├── CardData.cs              # 牌面数据结构
│       ├── PlayerData.cs            # 玩家数据结构
│       └── GameEvents.cs            # 全局静态事件总线（UnityAction）
├── Scenes/
│   ├── Boot.unity                   # 初始化、NakamaManager 加载
│   ├── Login.unity
│   ├── Lobby.unity                  # 模式选择、英雄选择、匹配等待
│   ├── Match.unity                  # 对局主场景
│   └── Result.unity                 # 结算场景
├── Prefabs/
├── Addressables/
│   ├── Cards/                       # 牌面图
│   ├── Heroes/                      # 英雄立绘、头像
│   └── Skins/                       # 皮肤资源，路径 skins/{hero_id}/{skin_id}/
└── docs/
    └── server_api.md                # 服务端接口文档（只读同步）
```

---

## 核心架构决策

### 1. 状态驱动，不事件驱动

服务端每次变更都推送 **OpCode 10 全量状态**，客户端直接用这份数据刷新 UI，不维护增量 diff。
`MatchState` 替换整个对象，`MatchController` 订阅 `OnStateUpdated` 事件后逐面板刷新。

```csharp
// MatchSocket.cs — OpCode 分发
private void OnMatchStateReceived(IMatchState state)
{
    switch ((long)state.OpCode)
    {
        case 10: GameEvents.OnStateUpdated?.Invoke(ParseState(state.State)); break;
        case 11: GameEvents.OnEventLog?.Invoke(ParseLog(state.State));       break;
        case 20: GameEvents.OnDamageAnim?.Invoke(ParseDamage(state.State));  break;
        case 30: GameEvents.OnMatchEnd?.Invoke(ParseResult(state.State));    break;
        case 105: GameEvents.OnAttackPrompt?.Invoke(ParseAttack(state.State)); break;
        // 私发
        case 100: GameEvents.OnHeroSkillPrompt?.Invoke(ParseSkill(state.State));  break;
        case 101: GameEvents.OnHeroChoicePrompt?.Invoke(ParseSkill(state.State)); break;
        case 102: GameEvents.OnHakimPeek?.Invoke(ParsePeek(state.State));         break;
        case 106: GameEvents.OnTrickSelect?.Invoke(ParseTrick(state.State));       break;
    }
}
```

### 2. PendingActionHandler — 弹窗路由器

收到 OpCode 10 后，检查 `state.pending.type` 决定弹出哪个交互面板：

| `pending.type` | 显示面板 | 回传 OpCode |
|---------------|---------|------------|
| `WAITING_FOR_DEFENSE` | DefensePanel | 5 |
| `WAITING_FOR_AOE` | DefensePanel（标注 AOE） | 5 |
| `WAITING_FOR_RESCUE` | RescuePanel | 5 |
| `WAITING_FOR_TRICK_SELECT` | TrickSelectPanel | 5 |
| `SULEIMAN_SEAL` / `HARUN_CHOOSE` / `ALIBABA_COUNTER` 等 | HeroSkillPanel | 5 |
| `HAKIM_XING_XIANG` | HeroSkillPanel（排序模式） | 5 |
| `ALADDIN_LAMP` | HeroSkillPanel（多选弃牌） | 5 |
| `null` | 关闭所有弹窗 | — |

> **只有 `player_id == me.id` 时才弹窗**；其他玩家的 pending 仅用于显示"等待中"状态。

### 3. 异步模式

所有网络调用使用 `async/await`，不用回调。Unity 主线程更新用 `UniTask`（或 `Task` + `SynchronizationContext`）。

```csharp
// 示例：出牌
public async Task PlayCard(string cardId, string targetId)
{
    var payload = JsonConvert.SerializeObject(new { card_id = cardId, target_id = targetId });
    var bytes = System.Text.Encoding.UTF8.GetBytes(payload);
    await _socket.SendMatchStateAsync(_matchId, 3, bytes);
}
```

### 4. NakamaManager 生命周期

- `Boot` 场景加载时初始化，`DontDestroyOnLoad`
- 存储 `IClient`、`ISession`、`ISocket`
- Session 过期自动 refresh（`session.IsExpired` 检查）
- 断线时触发 `OnDisconnected`，`MatchController` 负责显示重连 UI

---

## 对局消息协议速查

> 完整协议见 `docs/server_api.md` §2。

### 客户端发送

| OpCode | 时机 | 关键字段 |
|--------|------|---------|
| `3` | 出牌 | `card_id`, `target_id` |
| `4` | 手动结束回合 | （空 payload） |
| `5` | 所有"响应/确认"操作 | `confirm`, 可选 `card_id` / `target_id` / `card_ids` / `sorted_ids` |

### 客户端接收（关键）

| OpCode | 用途 | 触发 UI |
|--------|------|--------|
| `10` | 全量状态刷新 | 全部面板 |
| `11` | 事件文本 | EventLogView 滚动条 |
| `20` | 伤害动画驱动 | 受击动画、血条 tween |
| `30` | 对局结束 | 跳转 Result 场景 |
| `105` | 攻击/AOE 通知 | 攻击方播放出牌动画；目标方弹 DefensePanel |
| `100/101/102` | 英雄技能询问（**私发**）| HeroSkillPanel |
| `106` | 锦囊私有信息（**私发**）| TrickSelectPanel |

---

## RPC 调用规范

所有 RPC 封装在 `RpcClient.cs`，**禁止**在 UI 层直接调用 `client.RpcAsync`。

```csharp
// RpcClient.cs 示例
public async Task<HeroShopResult> GetHeroShop()
{
    var resp = await _client.RpcAsync(_session, "get_hero_shop", "{}");
    return JsonConvert.DeserializeObject<HeroShopResult>(resp.Payload);
}
```

完整 RPC 列表见 `docs/server_api.md` §3，所有接口均为 POST + JSON。

---

## 编码规范

- **命名**：类名 `PascalCase`，字段 `_camelCase`，常量 `UPPER_CASE`
- **异步**：Unity 回调（`Start`, `OnEnable`）如需 async 改为 `async void`，其余返回 `Task`
- **序列化**：服务端 JSON 字段为 `snake_case`，C# 类加 `[JsonProperty("field_name")]` 或配置 `snake_case` 命名策略
- **注释**：只注释"为什么"，不注释"是什么"；服务端行为、协议约定、超时处理需要注释
- **错误处理**：RPC 调用统一 `try/catch ApiResponseException`，显示本地化错误 Toast
- **禁止**在 `Update()` 里轮询网络状态，全部用事件驱动

---

## 场景流转

```
Boot → Login → Lobby → [HeroSelect弹窗] → Match → Result → Lobby
                  ↑                                            |
                  └────────────── 再次匹配 ────────────────────┘
```

- **Login**：设备 ID 匿名登录或 Apple/Google 账号登录
- **Lobby**：调用 `find_or_create_match`，等待服务端 `match_join` 确认
- **HeroSelect**：进入 Match 场景前通过 `join_match_with_hero` RPC 传入 `hero_id`
- **Match**：连接 WebSocket，进入 `matchId`，开始收发 OpCode
- **Result**：展示胜负、积分变化，调用 `get_season_stats` 刷新数据

---

## 身份迷雾规则（客户端）

- `others[].role` 除以下情况外一律显示 `"UNKNOWN"`（不得显示真实身份）：
  - 该玩家已阵亡（`hp <= 0`）
  - 对局结束（OpCode 30 收到后）
  - 该玩家身份为 `"MONARCH"`（主公身份公开）
- 自己的 `me.role` 始终可见

---

## 开发优先级（首批）

1. `NakamaManager` — 连接、匿名登录、Session 持久化
2. `MatchSocket` — OpCode 收发框架
3. `MatchState` / `MatchController` — OpCode 10 解析 + 基础 UI 刷新
4. `HandPanel` + `DefensePanel` — 出牌 + 防御最小闭环
5. `RpcClient` — `find_or_create_match`, `get_hero_shop`
6. 其余面板和英雄技能交互面板

---

## 服务端行为约定（客户端需知）

- 服务端是**最终裁判**，客户端预校验仅用于改善体验，不可信任
- 出牌后不要乐观更新 UI，等服务端推送 OpCode 10 再刷新
- `pending.deadline` 字段为服务端 Unix 时间戳，客户端据此显示倒计时（注意时钟偏差，建议 ±2s 容差）
- 断线重连后服务端会推送带 `"is_reconnect": true` 的 OpCode 10，客户端重置所有面板状态

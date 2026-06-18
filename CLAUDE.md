# Asura - 中东神话卡牌游戏

## 项目概述

Asura 是一个基于 Nakama 服务器的多人在线卡牌游戏，灵感来源于《三国杀》/《英雄杀》，但主题定位在中东神话和文化背景。游戏支持 2/5 名玩家进行身份局对战。

### 核心特色
- **中东文化主题**：英雄角色基于中东神话和历史人物
- **身份局玩法**：主公、忠臣、反贼、内奸的身份系统
- **英雄技能系统**：每个英雄拥有独特的主动/被动技能
- **实时对战**：基于 Nakama 的实时多人游戏框架

## 技术栈

### 后端
- **Nakama**: 游戏服务器框架 (Lua)
- **Docker**: 容器化部署
- **PostgreSQL 15**: 数据存储

### 游戏机制
- **语言**: Lua (Nakama 模块)
- **游戏模式**: 实时对战、身份局
- **卡牌系统**: 攻击、防御、治疗、锦囊牌

## 项目结构

```
asura/
├── api.lua                      # RPC API 接口（37 个，均 safe_rpc 包裹）
├── match_handler.lua           # 匹配/对局生命周期
├── game_rules.lua              # 游戏规则核心逻辑
├── hero_manager.lua            # 英雄技能触发器
├── hero_catalog.lua            # 英雄注册表（可从此处查所有英雄 ID）
├── game_config.lua             # 服务端游戏配置（从 storage 加载）
├── card_deck.lua               # 牌堆定义（108 张）
├── season_manager.lua          # 赛季排位 + match_history 记录
├── rate_limiter.lua            # RPC 速率限制器
├── skin_catalog.lua            # 皮肤注册表
├── daily_task_manager.lua      # 每日任务系统（UTC+3 刷新，胜场→碎片）
├── fragment_manager.lua        # 英雄碎片系统（兑换/转换/赠送）
├── achievement_manager.lua     # 成就系统
├── demo_concurrent.lua         # 本地并发测试（mock Nakama，10局随机英雄）。⚠️ 部署时被排除
├── demo.lua                    # ⚠️ 开发/测试辅助文件。CI 部署时自动清理（Nakama 加载此文件会导致崩溃）
├── heroes/                     # 英雄技能定义 (30 个英雄)
│   ├── *.lua + *.md            # 每个英雄一个 lua（技能逻辑）+ md（设计说明）
├── docs/                       # 文档目录
│   ├── plugin_refactoring.md   # 插件化架构重构说明
│   ├── product_design.md       # 产品设计文档
│   ├── architecture.md         # 架构设计文档
│   ├── backend_api.md          # 服务端 API 文档（客户端对接用）
│   ├── hero_design_review.md   # 英雄设计评审与修改记录
│   ├── hero_bugfix_plan.md     # 英雄 Bug 修复计划
│   └── unity_client_CLAUDE.md  # Unity 客户端项目配置
├── .github/workflows/          # CI/CD 工作流
│   ├── ci.yml                  # lint（luacheck + luac -p）
│   ├── deploy.yml              # 推送到 VPS 自动部署（self-hosted runner）
│   └── scheduled-test.yml      # 每日 10 局随机测试（UTC 2:00/14:00）
├── .luacheckrc                 # luacheck 配置（忽略 Nakama 回调模式误报）
├── docker-compose.yml          # 生产配置（Postgres 15 + Nakama，自定义镜像 ghcr.io/netkey/asura）
├── CLAUDE.md                   # 项目配置（本文件）
└── README.md                   # 项目说明
```

## 开发规范

### 代码规范
- 使用 4 个空格缩进
- 函数命名使用 snake_case
- 常量使用 UPPER_CASE
- 仅在 WHY 不明显时添加注释（隐藏约束、特殊不变量、绕过特定 bug 等）；不注释显而易见的逻辑

### Git 工作流
- main 分支为主分支
- 功能开发使用 feature/ 前缀分支
- 提交信息使用中文或英文，描述清晰

### 英雄设计原则
1. **文化契合**: 技能设计要符合中东文化背景
2. **平衡性**: 避免过强或过弱的英雄
3. **独特性**: 每个英雄都有独特的玩法
4. **可理解性**: 技能描述清晰易懂

## 游戏模式

### 标准模式 (2/5 人)
- **主公 (MONARCH)**: 1 人，血量+1，需要消灭所有反贼和内奸
- **忠臣 (MINISTER)**: 1-2 人，保护主公，与主公同阵营
- **反贼 (REBEL)**: 2-4 人，消灭主公
- **内奸 (TRAITOR)**: 1 人，最后存活获胜

### 卡牌类型

| 牌型 | 张数 | 说明 |
|------|------|------|
| ATTACK（大马士革弯刀）| 30 | 基础攻击，每回合限 1 次（连弩机除外） |
| DEFENSE（蜃景）| 15 | 抵消一次攻击 |
| HEAL（椰枣）| 8 | 回复 1 点血量 |
| WINE（沙漠之心）| 3 | 增伤 +1；不能用于濒死救人 |
| INSTANT_TRICK | 36 | 即时锦囊：aoe_attack/duel/discard_one/steal_one/draw_two/mass_heal/mass_draw/counterspell/borrow_weapon/fire_attack/aoe_defense/iron_chain |
| DELAYED_TRICK | 7 | 延时锦囊：skip_play（乐不思蜀）/ lightning（闪电） |
| WEAPON | 9 | 连弩机/贯石斧/青龙偃月刀/丈八蛇矛/双刃剑/麒麟弓/方天画戟/古锭刀/朱雀羽扇 |
| ARMOR | 3 | 八卦阵/仁王盾/藤甲 |
| HORSE | 8 | 进攻马(×4)+防守马(×4)，影响攻击距离 |

> 内部 type 不变，`card.name` 为大中东主题名（如 WINE→沙漠之心）。卡牌名中东本土化待办见 `project_backlog.md`。

## 英雄列表

### 已实现的英雄 (30 个)

| # | 英雄 | 中文名 | 来源 |
|---|------|--------|------|
| 1 | Aladdin | 阿拉丁 | 《一千零一夜》 |
| 2 | Alibaba | 阿里巴巴 | 《一千零一夜》 |
| 3 | Saladin | 萨拉丁 | 阿尤布王朝创立者 |
| 4 | Hakim | 哈基姆 | 法蒂玛王朝哈里发 |
| 5 | Al-Biruni | 比鲁尼 | 波斯博学家 |
| 6 | Al-Khwarizmi | 花剌子密 | 数学家、「代数」之父 |
| 7 | Al-Mansur | 曼苏尔 | 阿拔斯王朝哈里发 |
| 8 | Antar | 安塔拉 | 阿拉伯骑士诗人 |
| 9 | Avicenna | 伊本·西那 | 波斯医学家/哲学家 |
| 10 | Basira | 巴希拉 | 原创角色 |
| 11 | Dhul-Qarnayn | 双角王 | 《古兰经》人物 |
| 12 | Dunyazad | 敦娅扎德 | 《一千零一夜》 |
| 13 | Enheduanna | 恩赫杜安娜 | 美索不达米亚女祭司 |
| 14 | Gilgamesh | 吉尔伽美什 | 美索不达米亚史诗 |
| 15 | Harun al-Rashid | 哈伦·拉希德 | 阿拔斯王朝哈里发 |
| 16 | Hulagu | 旭烈兀 | 伊儿汗国创立者 |
| 17 | Ibn Battuta | 伊本·白图泰 | 摩洛哥旅行家 |
| 18 | Imru al-Qais | 乌姆鲁勒·盖斯 | 阿拉伯悬诗诗人 |
| 19 | Jafar | 贾法尔 | 巴尔马克家族宰相 |
| 20 | Khayyam | 海亚姆 | 波斯诗人/数学家 |
| 21 | Muawiyah | 穆阿维叶 | 倭马亚王朝创立者 |
| 22 | Nefertiti | 纳芙蒂蒂 | 古埃及王后 |
| 23 | Nizam al-Mulk | 尼扎姆·穆勒克 | 塞尔柱帝国宰相 |
| 24 | Rumi | 鲁米 | 波斯诗人与哲人 |
| 25 | Scheherazade | 谢赫拉莎德 | 《一千零一夜》讲述者 |
| 26 | Sinbad | 辛巴达 | 《一千零一夜》航海家 |
| 27 | Suleiman | 苏莱曼大帝 | 奥斯曼帝国苏丹 |
| 28 | Tamerlane | 帖木儿 | 帖木儿帝国创立者 |
| 29 | Zenobia | 芝诺比娅 | 帕尔米拉女王 |
| 30 | Zubaydah | 祖拜达 | 阿拔斯王朝王后 |

> 详细技能说明见各 `heroes/<name>.md` 文件

## 开发任务

> **说明**：本节为静态快照，仅记录优先级方向。活动任务列表见 memory `project_backlog.md`，以 memory 为准。

### 高优先级
- [x] 实现英雄解锁/购买系统（buy_hero RPC + wallet扣款 + OCC写入）
- [x] 实现排位赛 + 赛季系统（段位 bronze→grandmaster + leaderboard + match_history）
- [x] 实现皮肤购买系统（purchase_skin RPC + get_shop 统一商城）

### 中优先级
- [x] 添加更多英雄 — 已完成 30 个（超出原定 20+ 目标）
- [x] 完善身份局胜负判定逻辑（含阵亡身份广播）
- [x] 添加游戏配置系统（game_config.lua）
- [x] 添加好友/社交系统（好友状态实时推送 + 直接加入/观战）
- [x] 实现观战功能
- [x] 成就系统（achievement_manager.lua）
- [x] 游戏统计（storage 存储的 metric_inc 计数器）

### 待办
- [x] 每日任务系统 + 英雄碎片系统（daily_task_manager.lua + fragment_manager.lua，含赠送/兑换 RPC）
- [x] 卡牌名中东本土化全量完成 → 已入库（card_deck.lua 108 张英文命名）
- [x] 广播消息英文本土化全量完成 → 已入库（~105 条 OpCode 11 内容）
- [ ] 多语言支持

## 部署说明

### 本地开发
```bash
# 启动 Nakama + Postgres
docker compose up -d

# 查看日志
docker compose logs -f nakama
```

### 自动化部署（VPS）
GitHub Actions self-hosted runner 在 VPS 上运行，`push 到 main` 时自动触发（Docker 镜像模式）：
1. Build Docker 镜像 → push 到 ghcr.io
2. 排空（drain）现有对局，最长 120s
3. 拉取新镜像 → `docker compose up -d --force-recreate`
4. 健康检查（轮询 port 7350，最多 60s）
5. 取消排空（undrain）恢复匹配
6. Hermes 自动重测 10 局

> ⚠️ 新增脚本文件/目录必须在 `Dockerfile` 中添加对应的 `COPY` 指令，否则不会进入镜像。

### 本地测试
```bash
# 10 局随机英雄并发测试（mock Nakama，无需启动容器）
lua5.4 demo_concurrent.lua

# Lint 检查
luacheck --no-color .
luac -p *.lua heroes/*.lua
```

### 生产配置要点
- `docker-compose.yml` 已合并 VPS 生产配置
- Postgres 15 Alpine，数据持久化到 `/data/nakama/pgdata`
- `stop_grace_period: 60s` + `match_terminate` 实现排空机制
- Nakama `session.token_expiry_sec: 7200`，DEBUG 日志级别
- `IAP_SECRET/GOOGLE_CLIENT_*` 环境变量通过 VPS 环境注入

## 生产加固模式

### 1. RPC 安全 — safe_rpc 包裹
`api.lua` 中所有 `nk.register_rpc` 必须使用 `safe_rpc(fn)` 包裹，防止未捕获异常导致 Nakama RPC 端点崩溃。

### 2. 第三方 API 降级 — pcall
Nakama 部分 API（如 `nk.status_update`）在版本迭代中可能被移除。所有不常用 `nk.*` 调用必须 `pcall` 包裹：
```lua
pcall(nk.status_update, uid, data)
```

### 3. 编码前查文档
调用任何 `nk.*` 函数前，先用 Context7 查 Nakama 文档确认函数存在与签名（当前生产镜像 `ghcr.io/netkey/asura:latest`）。参考 `feedback_nakama_docs_lookup`。

### 4. 存储型计数器
Nakama Lua 无 Prometheus HTTP 接口，使用 `ops/matches` 存储记录指标（`metric_inc` 模式），通过 `nk.storage_read` + OCC 版本控制写入。

### 5. 服务器排空 — match_terminate
`match_terminate` 不直接结束对局，而是设置 `pending_shutdown` 时间戳，由 `match_loop` 到期后自动清理。兼容多节点协调器（如 konsul）的 draining 流程。

### 6. 客户端状态同步 — broadcast_update
`on_response` **所有分支**（含失败/校验不通过/超时）必须调用 `broadcast_update`，否则客户端卡死在假死循环。不要在每个成功分支里单独调用，放在块外统一调用。

### 7. pending_action 与死亡玩家
`pending_action` 涉及已死亡玩家时必须清理并推进链。`auto_defend` 对 dead target 不能静默 return，必须 `handle_response` 推进链。`WAITING_FOR_COUNTER` 遍历时跳过 `health<=0` 的玩家，避免每死者空耗 15s。

### 8. 并发安全 — OCC 存储
`find_or_create_match` 等竞态场景用 `nk.storage_write` 的 OCC 版本控制替代 `match_list` 二次查询（TOCTOU）。

### 9. 输入校验
所有 payload 字段（`card_id`/`target_id`/`block_type` 等）使用前必须做类型、范围、归属校验，不允许信任客户端输入。

### 10. Lua 循环控制
Lua 5.4 中循环跳过用 `goto continue` + `::continue::`，`break` 会截断后续合法元素。

## 相关文档

- [产品设计文档](./docs/product_design.md)
- [架构设计文档](./docs/architecture.md)
- [API 文档](./docs/backend_api.md)（客户端对接用，变更后需同步更新）
- [英雄设计评审报告](./docs/hero_design_review.md)

---

**最后更新**: 2026-06-17
**版本**: 0.8.0

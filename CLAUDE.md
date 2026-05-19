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
- **PostgreSQL/CockroachDB**: 数据存储

### 游戏机制
- **语言**: Lua (Nakama 模块)
- **游戏模式**: 实时对战、身份局
- **卡牌系统**: 攻击、防御、治疗、锦囊牌

## 项目结构

```
asura/
├── api.lua                      # RPC API 接口
├── game_rules.lua              # 游戏规则核心逻辑
├── match_handler.lua           # 匹配处理逻辑
├── hero_manager.lua            # 英雄管理器
├── heroes/                     # 英雄技能定义 (30 个英雄)
│   ├── al_biruni.lua         # 比鲁尼
│   ├── al_khwarizmi.lua      # 花剌子密
│   ├── al_mansur.lua         # 曼苏尔
│   ├── aladdin.lua           # 阿拉丁
│   ├── alibaba.lua           # 阿里巴巴
│   ├── antar.lua             # 安塔拉
│   ├── avicenna.lua          # 伊本·西那 (阿维森纳)
│   ├── basira.lua            # 巴希拉
│   ├── dhul_qarnayn.lua      # 双角王
│   ├── dunyazad.lua          # 敦娅扎德
│   ├── enheduanna.lua        # 恩赫杜安娜
│   ├── gilgamesh.lua         # 吉尔伽美什
│   ├── hakim.lua             # 哈基姆
│   ├── harun_al_rashid.lua   # 哈伦·拉希德
│   ├── hulagu.lua            # 旭烈兀
│   ├── ibn_battuta.lua       # 伊本·白图泰
│   ├── imru_al_qais.lua      # 乌姆鲁勒·盖斯
│   ├── jafar.lua             # 贾法尔
│   ├── khayyam.lua           # 海亚姆
│   ├── muawiyah.lua          # 穆阿维叶
│   ├── nefertiti.lua         # 纳芙蒂蒂
│   ├── nizamulmulk.lua       # 尼扎姆·穆勒克
│   ├── rumi.lua              # 鲁米
│   ├── saladin.lua           # 萨拉丁
│   ├── scheherazade.lua     # 谢赫拉莎德
│   ├── sinbad.lua            # 辛巴达
│   ├── suleiman.lua          # 苏莱曼大帝
│   ├── tamerlane.lua         # 帖木儿
│   ├── zenobia.lua           # 芝诺比娅
│   └── zubaydah.lua          # 祖拜达
├── CLAUDE.md                  # 项目配置 (本文件)
├── docs/                      # 文档目录
│   ├── product_design.md      # 产品设计文档
│   └── architecture.md        # 架构设计文档
└── README.md                  # 项目说明
```

## 开发规范

### 代码规范
- 使用 4 个空格缩进
- 函数命名使用 snake_case
- 常量使用 UPPER_CASE
- 添加必要的注释说明

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
- **攻击 (ATTACK)**: 基础攻击牌
- **防御 (DEFENSE)**: 防御攻击
- **治疗 (HEAL)**: 恢复生命值
- **AOE_SANDSTORM**: 范围攻击
- **DRAW_TWO**: 摸两张牌
- **JUDGE_STORM**: 延时判定牌

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

### 高优先级
- [ ] 修复英雄技能文件重复问题
- [ ] 完善身份局胜负判定逻辑
- [ ] 添加游戏配置系统
- [ ] 实现英雄解锁/购买系统

### 中优先级
- [x] 添加更多英雄 (目标: 20+ 英雄) — 已完成 30 个
- [ ] 实现排位赛系统
- [ ] 添加好友/社交系统
- [ ] 实现观战功能

### 低优先级
- [ ] 添加游戏统计
- [ ] 实现回放系统
- [ ] 添加成就系统
- [ ] 多语言支持

## 部署说明

### 本地开发
```bash
# 启动 Nakama
docker-compose up -d

# 查看日志
docker-compose logs -f nakama
```

### 生产部署
- 使用 Docker 部署
- 配置 PostgreSQL/CockroachDB
- 设置环境变量

## 相关文档

- [产品设计文档](./docs/product_design.md)
- [架构设计文档](./docs/architecture.md)
- [API 文档](./docs/api.md) (待创建)
- [英雄设计评审报告](./docs/hero_design_review.md)

## 联系方式

- 项目负责人: [待填写]
- 技术负责人: [待填写]
- 游戏设计师: [待填写]

---

**最后更新**: 2026-05-19
**版本**: 0.4.0

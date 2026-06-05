# 插件化架构重构

**版本**: 1.0.0  
**日期**: 2026-06-05  
**状态**: 已完成

## 目标

消除核心文件（`game_rules.lua`、`match_handler.lua`）中对具体英雄的硬编码判断，统一为钩子模式。

## 原则

```
核心文件 → hero_mgr.trigger("hook") → hero_manager 路由 → heroes/*.lua 实现
```

新增英雄只改 `heroes/<name>.lua` + `hero_manager.lua` 注册，不动核心文件。

---

## 重构内容

### 1. 超时处理插件化（`on_timeout`）

**问题**: `match_handler.lua:auto_resolve_pending` 含 13 个 `elseif act.type == "XXX"` 英雄分支（~60 行）。

**方案**: 每个英雄加 `on_timeout(dispatcher, state, act)` 函数，`hero_manager` 做 `hero_id → on_timeout` 路由。

**涉及英雄（13 个）**:

| 英雄 | hero_id | Pending Type | 超时行为 |
|------|---------|-------------|----------|
| 恩赫杜安娜 | enheduanna | ENHEDUANNA_SONG_CI | confirm=true |
| 恩赫杜安娜 | enheduanna | ENHEDUANNA_SONG_CI_GIVE | confirm=true + card_id + target_id |
| 苏莱曼 | suleiman | SULEIMAN_CHI_LING | confirm=true + target_id[1] + block_type="ATTACK" |
| 哈伦 | harun_al_rashid | HARUN_SELECT_TARGET | confirm=true + target_id[1] |
| 哈伦 | harun_al_rashid | HARUN_CHOOSE | confirm=true + choose_discard=false |
| 阿里巴巴 | alibaba | ALIBABA_COUNTER | confirm=true |
| 伊本白图泰 | ibn_battuta | IBN_BATTUTA_YUAN_XING | confirm=true + hand[1] |
| 鲁米 | rumi | RUMI_XUANHUI | confirm=true |
| 哈基姆 | hakim | HAKIM_XING_XIANG | confirm=false |
| 花剌子密 | al_khwarizmi | AL_KHWARIZMI_SUANFA | confirm=false |
| 比鲁尼 | al_biruni | AL_BIRUNI_CELIANG | confirm=false |
| 吉尔伽美什 | gilgamesh | GILGAMESH_BU_XIU | confirm=true + cards[1] |
| 谢赫拉莎德 | scheherazade | SCHEHERAZADE_QIANYE | confirm=false |
| 阿维森纳 | avicenna | AVICENNA_ZHEN | confirm=true + heart_cards[1] |
| 巴希拉 | basira | BASIRA_DONG_CHA | confirm=false（死代码，不会触发） |
| 双角王 | dhul_qarnayn | DHUL_SKILL_CHOICE / WEST_EXTRA / EAST_EXTRA | confirm=false |

**死代码清理**: `BASIRA_DONG_CHA`、`DHUL_WESTWARD_TARGET`、`DHUL_EASTWARD_TARGET` 三种类型在代码中从未被创建，一并删除。

### 2. 救援条件插件化（`can_rescue_with`）

**问题**: `game_rules.lua:1145` 和 `match_handler.lua:362` 硬编码 `rescuer.hero == "avicenna"`。

**方案**: `hero_manager` 加 `can_rescue_with(hero_id, card)` → 阿维森纳实现 `card.suit == "HEART"`。

### 3. 英雄发现

**hero_manager.lua** 新增两个路由函数，`auto_resolve_pending` 从 ~100 行缩至 ~35 行。

---

## 变更文件清单

| 文件 | 变更类型 |
|------|----------|
| `heroes/enheduanna.lua` | +10 行 `on_timeout` |
| `heroes/suleiman.lua` | +10 行 |
| `heroes/harun_al_rashid.lua` | +15 行 |
| `heroes/alibaba.lua` | +5 行 |
| `heroes/ibn_battuta.lua` | +10 行 |
| `heroes/rumi.lua` | +5 行 |
| `heroes/hakim.lua` | +5 行 |
| `heroes/al_khwarizmi.lua` | +5 行 |
| `heroes/al_biruni.lua` | +5 行 |
| `heroes/gilgamesh.lua` | +10 行 |
| `heroes/scheherazade.lua` | +5 行 |
| `heroes/avicenna.lua` | +10 行（on_timeout + can_rescue_with） |
| `heroes/basira.lua` | +5 行（死代码兼容） |
| `heroes/dhul_qarnayn.lua` | +10 行 |
| `hero_manager.lua` | +20 行（handle_timeout + can_rescue_with） |
| `match_handler.lua` | -60 行 + 5 行 |
| `game_rules.lua` | -1 行 + 1 行 |

---

## 验证计划

```bash
luac5.4 -p *.lua heroes/*.lua     # 语法检查
lua5.4 demo_concurrent.lua x3     # 30 局稳定性测试
grep -rn "hero ==\|act\.type ==" match_handler.lua game_rules.lua  # 确认无新硬编码
```

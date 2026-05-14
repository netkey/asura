# 英雄系统 Bug 修复计划

> 来源：2026-05-12 英雄专项代码审查（30 英雄全量检查）
> 总计：P0×5 / P1×11 / P2×15 / P3×13

---

## 修复原则

1. **按依赖关系排序**，而非严格按 P0→P1→P2 线性推进
2. **每个 Phase 产出可测试的增量**，修完即可验证
3. **先修框架层 bug，再修英雄层 bug** — 框架层修复可能连带解决多个英雄问题
4. **设计歧义问题（代码 vs 文档）单独收集**，统一确认后再改

---

## Phase 1：核心战斗系统修复（阻塞全部对局）

**目标**：修复防御系统和钩子调用，让基础战斗流程可用。

| 编号 | 问题 | 修复方案 | 影响范围 |
|------|------|----------|----------|
| H-P0-1 | 防御成功不消耗手牌 + pending_action 未清除 | 参考死代码 `handle_defense_response`(行774-792)，在 `handle_response` 的防御分支中：(1) 从 defender.hand 移除 DEFENSE 牌到 discard_pile；(2) 调用前先 `state.pending_action = nil` | 所有攻防交互 |
| H-P0-2 | `on_draw_phase_start` 钩子未调用 | 在 `match_handler.lua:520` 的 `draw_cards` 前插入 `hero_mgr.trigger("on_draw_phase_start", dispatcher, state, uid)`，如返回 true 则跳过默认摸牌 | al_biruni / al_khwarizmi / basira |
| H-P1-1 | 防御成功广播裸字符串 | 改为 `nk.json_encode({content = "防御成功！"})` | 所有防御成功事件 |
| H-P3-3 | `handle_defense_response` 死代码 | 合并到 H-P0-1 后删除死代码 | 代码清理 |

**验证标准**：
- 防御成功后攻击者手牌不变、防御者手牌 -1
- pending_action 正确清除，不触发超时二次扣血
- al_biruni / al_khwarizmi / basira 技能正常触发

---

## Phase 2：状态生命周期修复（跨回合状态泄漏）

**目标**：修复永不清除的状态标记，防止英雄越来越强/技能单次失效。

| 编号 | 问题 | 修复方案 | 影响范围 |
|------|------|----------|----------|
| H-P0-5 | suleiman_sealed 在 next_turn 入口清除太早 | 改为在被封印目标的回合结束时清除：记录 `sealed_target_id`，在 `next_turn` 中仅当 `state.current_turn == sealed_target_id` 时清除 | suleiman |
| H-P1-4 | dunyazad_immune 永不清除 | 在 `match_handler.lua` 的 `next_turn` 中（suleiman_sealed 清除处附近）添加 `state.dunyazad_immune = {}` | dunyazad |
| H-P1-2 | basira_used 永不重置 | 在 `on_draw_phase_start`（Phase 1 修通后）入口处 `player.basira_used = false` | basira |

**验证标准**：
- suleiman 封印在被封印者的下一个出牌阶段生效，其回合结束后清除
- dunyazad 免疫效果仅持续到攻击者当前回合结束
- basira 每回合可使用一次技能

---

## Phase 3：濒死/伤害流程修复

**目标**：修复濒死救援被跳过、伤害计算错误等致命问题。

| 编号 | 问题 | 修复方案 | 影响范围 |
|------|------|----------|----------|
| H-P0-3 | harun_al_rashid 覆写救援状态 | 将 `state.pending_action = nil`（行78）移入 `if not (... WAITING_FOR_RESCUE)` 条件内 | harun_al_rashid |
| H-P0-4 | khayyam 覆盖牌堆 | 改为追加：`for _, card in ipairs(rules.shuffle(state.discard_pile)) do table.insert(state.deck, card) end` | khayyam / 全局牌堆 |
| H-P1-3 | alibaba 反击伤害含武器/酒加成 | 反击改为直接 `target.health = target.health - 1` + 触发 on_damaged，绕过 apply_damage 的加成计算 | alibaba |
| H-P1-10 | saladin 固定摸 1 张 | 改为 `rules.draw_cards(state, player_id, amount)` 按伤害量摸牌 | saladin |

**验证标准**：
- harun_al_rashid 造成濒死伤害时，目标可被正常救援
- khayyam 触发【诗酒】后牌堆总量 = 原牌堆 + 弃牌堆
- alibaba 反击固定扣 1 点，不受装备/酒影响
- saladin 受到 N 点伤害摸 N 张牌

---

## Phase 4：技能触发范围与目标选择修复

**目标**：修复技能触发条件与设计文档的不一致。

| 编号 | 问题 | 修复方案 | 影响范围 |
|------|------|----------|----------|
| H-P1-9 | nizamulmulk 对所有伤害触发 | 在 `on_damaged` 中增加伤害来源类型检查，或改用 `on_after_being_attacked` 钩子（需新增） | nizamulmulk |
| H-P1-5 | harun_al_rashid 随机选目标 | 改为设置 `pending_action` 让玩家选择目标，类型 `HARUN_SELECT_TARGET` | harun_al_rashid |
| H-P1-11 | zenobia pairs() 顺序不确定 | 改为 ipairs + 按 player_id 排序的确定性列表，并列时选 id 最小的 | zenobia |
| H-P1-8 | muawiyah 空手牌分支无广播 | 添加 `rules.broadcast_update(dispatcher, state)` | muawiyah |

**验证标准**：
- nizamulmulk 仅在被攻击牌命中时触发，天谴/AOE 不触发
- harun_al_rashid 技能弹出目标选择 UI
- zenobia 手牌并列时结果确定且一致

---

## Phase 5：pending_action 规范化

**目标**：统一所有英雄 pending_action 的 deadline 和广播时序。

| 编号 | 问题 | 修复方案 | 影响范围 |
|------|------|----------|----------|
| H-P1-7 | ibn_battuta 缺 deadline | 添加 `deadline = os.time() + 15`，并在 match_handler 超时分发列表注册 `IBN_BATTUTA_YUAN_XING` | ibn_battuta |
| H-P2-1 | rumi / scheherazade 缺 deadline | 同上，添加 `deadline = os.time() + 15` | rumi / scheherazade |
| H-P2-2 | broadcast_update 在 pending_action = nil 之前 | 全局排查：先 `state.pending_action = nil` 再 `broadcast_update`。涉及 rumi / scheherazade / ibn_battuta / tamerlane | 4 个英雄 |

**验证标准**：
- 所有英雄的 pending_action 均有 15 秒超时
- 断线玩家不会阻塞游戏超过 15 秒
- broadcast_update 发送时 pending_action 已为 nil

---

## Phase 6：设计确认项（需产品/策划确认后修复）

以下问题代码与文档存在歧义，需先确认"以哪个为准"再改代码或改文档。

| 编号 | 问题 | 选项 A（改代码） | 选项 B（改文档） |
|------|------|-----------------|-----------------|
| H-P1-6 | hakim 触发条件 | 改为 `on_draw_phase_start`，每回合观察牌堆顶 3 张 | 文档改为"判定阶段开始时，若有判定牌则可查看并改变结果" |
| H-P3-5 | jafar 无限制强制命中 | 添加每回合 1 次限制或弃牌成本 | 文档明确"无限制"为设计意图 |
| H-P3-8 | sinbad 自动 vs 可选 | 改为 pending_action 让玩家选择是否取牌 | 文档改为"自动取回" |
| H-P2-10 | enheduanna 给敌人摸牌 | 改为仅给同阵营摸牌（需身份系统支持） | 文档明确"双刃剑"设计意图 |
| H-P2-7 | avicenna 致死伤害不触发 | 在 HP 扣除前触发（需重构 on_damaged 时机） | 文档明确"仅非致死伤害" |

---

## 工作量估算

| Phase | 预估耗时 | 涉及文件 | 风险 |
|-------|----------|----------|------|
| Phase 1 | 1-2h | game_rules.lua, match_handler.lua | 高（核心战斗流程） |
| Phase 2 | 0.5-1h | match_handler.lua, dunyazad.lua, basira.lua | 中 |
| Phase 3 | 1-2h | harun_al_rashid.lua, khayyam.lua, alibaba.lua, saladin.lua | 高（伤害计算） |
| Phase 4 | 1-2h | nizamulmulk.lua, harun_al_rashid.lua, zenobia.lua, muawiyah.lua | 中 |
| Phase 5 | 1h | ibn_battuta.lua, rumi.lua, scheherazade.lua, match_handler.lua | 低 |
| Phase 6 | 待确认 | 多个英雄 | 取决于设计决策 |

**总计**：Phase 1-5 约 5-8 小时，Phase 6 待产品确认。

---

## 修复后回归测试清单

- [ ] 基础攻防：攻击→防御→消耗手牌→回合正常推进
- [ ] 濒死救援：HP 降至 0→求救→被救→正常继续
- [ ] AOE 结算：沙尘暴→多目标逐个防御→超时正确处理
- [ ] 天谴判定：判定牌→结算→不触发非攻击类被动
- [ ] 牌堆守恒：摸牌+弃牌+洗牌后总牌数不变
- [ ] 30 英雄逐一冒烟测试：技能至少触发一次且无报错

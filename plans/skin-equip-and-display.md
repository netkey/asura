# Plan: 英雄皮肤穿戴与展示系统

> Source PRD: [#11](https://github.com/netkey/asura/issues/11)

## Architectural decisions

- **入口**: `match_join` payload 新增 `skin_id` 字段，不新增独立 RPC
- **存储**: `match_state.players[id].skin_id` — 对局生命周期内，不跨局持久化
- **校验**: skin 归属 hero + 玩家拥有（或 `is_default=true` 的默认皮肤）
- **广播**: `broadcast_update` 的 `players` 数组中含 `skin_id`
- **购买货币**: 金币，沿用已有 `purchase_skin` RPC，本次不改动
- **技能变皮（用户故事 #7）**: 纯客户端实现。服务端不传技能别名，客户端根据 `(skin_id, skill_name)` 本地查表换特效

---

## Phase 1: skin_id 接入 match_join + 广播

**User stories**: #1 (选择英雄时选皮肤), #2 (默认皮肤自动填充), #11 (客户端获取 skin_id)

### What to build

客户端在 `match_join` 时传入 `skin_id`，服务端记录到 `match_state` 并通过 `broadcast_update` 广播给所有玩家。不传则自动填充默认皮肤。

### Acceptance criteria

- [ ] `match_join` payload 接受 `skin_id` 字段（string，可选）
- [ ] `skin_id` 不传或为空时，自动查找并填充该英雄的默认皮肤
- [ ] `match_state.players[uid].skin_id` 记录当前装备的皮肤
- [ ] `broadcast_update` 输出的 `players` 数组中每个玩家含 `skin_id`
- [ ] `match_start` 广播含 `hero_id` + `skin_id`
- [ ] 已有对局（未传 skin_id 的老客户端）不受影响，正常填充默认皮肤

---

## Phase 2: 归属 + 拥有权校验

**User stories**: #1 (只能选已拥有皮肤), #3 (未拥有皮肤不可选), #4 (无付费皮肤的玩家不受干扰)

### What to build

收到 `skin_id` 后校验：1) 该皮肤属于当前选择的 hero；2) 玩家已购买该皮肤或它是默认皮肤。校验失败时拒绝并回退到默认皮肤。

### Acceptance criteria

- [ ] skin 的 `hero_id` 与玩家选择的 hero 不匹配时，拒绝并回退默认皮肤
- [ ] 非默认皮肤且玩家未拥有（`skin_inventory:owned_skins` 中不存在）时，拒绝并回退默认皮肤
- [ ] 默认皮肤（`is_default=true`）直接放行，不检查拥有权
- [ ] 校验失败时返回明确的 error 信息给客户端
- [ ] `skin_inventory` 读取逻辑复用已有 `get_hero_shop` 中的 `owned_skin_set` 构建方式

---

## Phase 3: 商城返回皮肤预览信息

**User stories**: #2 (皮肤缩略图/名称预览), #9 (对局内效果标签), #10 (驱动购买的展示说明)

### What to build

`get_hero_shop` 返回的皮肤条目中增加 `effect_tags`（特效标签，如"击杀特效"、"技能变皮"）和 `preview` 描述。客户端据此渲染商城预览卡片。

### Acceptance criteria

- [ ] `skin_catalog.SKINS` 每条新增可选字段 `effect_tags`（string 数组）和 `preview`（string 描述）
- [ ] `get_hero_shop` 返回的 skin items 中包含 `effect_tags` 和 `preview`
- [ ] 已有皮肤数据补齐 `effect_tags` 和 `preview`（4 英雄 × 6 款付费皮肤）
- [ ] 默认皮肤标记 `effect_tags=[]` 和适当的 `preview` 文本

---

## Client Integration (客户端对接契约)

本节供客户端开发使用，描述与皮肤系统交互的完整接口。

### 资源路径

```
本地:  skins/{hero_id}/{skin_id}/
默认:  skin_id = null → skins/{hero_id}/default/
CDN:   后期由 skin_catalog 的 asset_url 字段控制，客户端逻辑无需修改
```

### match_join — 入参

客户端在匹配加入时通过 Nakama SDK metadata 传入 `skin_id`：

```
JoinMatch(match_id, metadata={"hero_id": "hakim", "skin_id": "hakim_celestial"})
```

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `hero_id` | string | 是 | 选择的英雄 ID |
| `skin_id` | string | 否 | 选择的皮肤 ID；省略、null 或空串均使用默认皮肤 |

### broadcast_update (OpCode 10) — 出参

`players[].skin_id` 返回每个玩家当前装备的皮肤：

```json
{
  "me": {
    "hero": "aladdin",
    "skin_id": "aladdin_golden",
    ...
  },
  "others": [
    {"hero": "hakim", "skin_id": null, ...}
  ]
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `skin_id` | string 或 null | null = 默认皮肤 |

### get_hero_shop — 皮肤商品

```json
{
  "heroes": [...],
  "skins": [
    {
      "category": "skin",
      "id": "aladdin_golden",
      "hero_id": "aladdin",
      "name_cn": "黄金神灯",
      "price": 680,
      "owned": true,
      "buy_rpc": "purchase_skin",
      "effect_tags": ["击杀特效", "技能变皮"],
      "preview": "【神灯】改为金色轨迹特效"
    }
  ]
}
```

| 新增字段 | 类型 | 说明 |
|----------|------|------|
| `effect_tags` | string[] | 特效标签，客户端可选展示为角标 |
| `preview` | string | 预览文案，商城中展示 |

### get_my_skins — 已拥有皮肤

```json
{"owned": ["aladdin_golden", "hakim_celestial"]}
```

客户端据此过滤可选皮肤列表：`owned` 中含有 + 对应 hero 的默认皮肤。

### 技能变皮（客户端实现）

服务端始终下发原始技能名（如 `skill="坚守"`）。客户端维护 `(skin_id, skill_name) → 特效动画` 的本地映射表：

```
映射示例:
  ("saladin_crusader", "坚守") → 技能名显示"圣盾"，动画用 crusader_shield.fx
  ("saladin_default", "坚守")  → 技能名显示"坚守"，动画用 default_shield.fx
```

### 错误处理

| 场景 | 服务端行为 | 客户端处理 |
|------|-----------|-----------|
| `skin_id` 不合法 | 回退默认皮肤，对局正常进行 | 无需额外处理 |
| 客户端传未拥有的皮肤 | 回退默认皮肤 | 确保 UI 不暴露未拥有皮肤 |
| 老客户端未传 `skin_id` | 自动填充默认皮肤 | 兼容，无需改动 |

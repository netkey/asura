-- card_deck.lua — 固定108张标准牌堆，中东主题命名
-- 每张卡牌固定花色/点数，确保判定系统正确运行
-- 洗牌只改变顺序，ID/花色/点数永不改变

local M = {}

-- ==========================================
-- 108 张牌定义
-- 每张牌: { id, type, suit, number, name [, subtype] }
-- number: 1=A, 11=J, 12=Q, 13=K
-- ==========================================
local DECK = {}

-- 序号生成器
local seq = {}

local function add_card(type, suit, num, name, subtype)
    local key = type .. "_" .. (subtype or "")
    seq[key] = (seq[key] or 0) + 1
    local id = string.format("%s_%s_%02d", type, subtype or "none", seq[key])
    local card = {
        id = id,
        type = type,
        suit = suit,
        number = num,
        name = name,
    }
    if subtype then card.subtype = subtype end
    table.insert(DECK, card)
end

-- ==========================================
-- ATTACK — 杀 × 30
-- ==========================================
-- SPADE × 7 (7,8,9,10,J,Q,K)
add_card("ATTACK", "SPADE", 7,  "大马士革弯刀")
add_card("ATTACK", "SPADE", 8,  "大马士革弯刀")
add_card("ATTACK", "SPADE", 9,  "大马士革弯刀")
add_card("ATTACK", "SPADE", 10, "大马士革弯刀")
add_card("ATTACK", "SPADE", 11, "大马士革弯刀")
add_card("ATTACK", "SPADE", 12, "大马士革弯刀")
add_card("ATTACK", "SPADE", 13, "大马士革弯刀")
-- CLUB × 11 (2,3,4,5,6,7,8,9,10,J,Q)
add_card("ATTACK", "CLUB", 2,  "大马士革弯刀")
add_card("ATTACK", "CLUB", 3,  "大马士革弯刀")
add_card("ATTACK", "CLUB", 4,  "大马士革弯刀")
add_card("ATTACK", "CLUB", 5,  "大马士革弯刀")
add_card("ATTACK", "CLUB", 6,  "大马士革弯刀")
add_card("ATTACK", "CLUB", 7,  "大马士革弯刀")
add_card("ATTACK", "CLUB", 8,  "大马士革弯刀")
add_card("ATTACK", "CLUB", 9,  "大马士革弯刀")
add_card("ATTACK", "CLUB", 10, "大马士革弯刀")
add_card("ATTACK", "CLUB", 11, "大马士革弯刀")
add_card("ATTACK", "CLUB", 12, "大马士革弯刀")
-- HEART × 1 (10)
add_card("ATTACK", "HEART", 10, "大马士革弯刀")
-- DIAMOND × 11 (2,3,4,5,6,7,8,9,10,J,Q)
add_card("ATTACK", "DIAMOND", 2,  "大马士革弯刀")
add_card("ATTACK", "DIAMOND", 3,  "大马士革弯刀")
add_card("ATTACK", "DIAMOND", 4,  "大马士革弯刀")
add_card("ATTACK", "DIAMOND", 5,  "大马士革弯刀")
add_card("ATTACK", "DIAMOND", 6,  "大马士革弯刀")
add_card("ATTACK", "DIAMOND", 7,  "大马士革弯刀")
add_card("ATTACK", "DIAMOND", 8,  "大马士革弯刀")
add_card("ATTACK", "DIAMOND", 9,  "大马士革弯刀")
add_card("ATTACK", "DIAMOND", 10, "大马士革弯刀")
add_card("ATTACK", "DIAMOND", 11, "大马士革弯刀")
add_card("ATTACK", "DIAMOND", 12, "大马士革弯刀")

-- ==========================================
-- DEFENSE — 闪 × 15
-- ==========================================
add_card("DEFENSE", "HEART", 2,  "蜃景")
add_card("DEFENSE", "HEART", 3,  "蜃景")
add_card("DEFENSE", "HEART", 4,  "蜃景")
add_card("DEFENSE", "HEART", 5,  "蜃景")
add_card("DEFENSE", "HEART", 6,  "蜃景")
add_card("DEFENSE", "HEART", 7,  "蜃景")
add_card("DEFENSE", "HEART", 8,  "蜃景")
add_card("DEFENSE", "HEART", 9,  "蜃景")
add_card("DEFENSE", "DIAMOND", 2,  "蜃景")
add_card("DEFENSE", "DIAMOND", 3,  "蜃景")
add_card("DEFENSE", "DIAMOND", 4,  "蜃景")
add_card("DEFENSE", "DIAMOND", 5,  "蜃景")
add_card("DEFENSE", "DIAMOND", 6,  "蜃景")
add_card("DEFENSE", "DIAMOND", 7,  "蜃景")
add_card("DEFENSE", "DIAMOND", 8,  "蜃景")

-- ==========================================
-- HEAL — 桃 × 8
-- ==========================================
add_card("HEAL", "HEART", 3,  "椰枣")
add_card("HEAL", "HEART", 4,  "椰枣")
add_card("HEAL", "HEART", 5,  "椰枣")
add_card("HEAL", "HEART", 6,  "椰枣")
add_card("HEAL", "HEART", 7,  "椰枣")
add_card("HEAL", "HEART", 8,  "椰枣")
add_card("HEAL", "HEART", 9,  "椰枣")
add_card("HEAL", "HEART", 12, "椰枣")

-- ==========================================
-- WINE — 酒 × 3
-- ==========================================
add_card("WINE", "SPADE", 3,   "椰枣酒", "damage_plus1")
add_card("WINE", "CLUB", 9,    "阿拉伯烈酒", "damage_plus1")
add_card("WINE", "DIAMOND", 9, "阿拉伯烈酒", "damage_plus1")

-- ==========================================
-- INSTANT_TRICK — 即时锦囊
-- ==========================================

-- 南蛮入侵 × 3 (aoe_attack — 响应者出 ATTACK)
add_card("INSTANT_TRICK", "SPADE",   7,  "沙漠侵袭", "aoe_attack")
add_card("INSTANT_TRICK", "CLUB",    7,  "沙漠侵袭", "aoe_attack")
add_card("INSTANT_TRICK", "HEART",   7,  "沙漠侵袭", "aoe_attack")

-- 万箭齐发 × 3 (aoe_defense — 响应者出 DEFENSE)
add_card("INSTANT_TRICK", "SPADE",   1,  "万箭齐发", "aoe_defense")
add_card("INSTANT_TRICK", "HEART",   1,  "万箭齐发", "aoe_defense")
add_card("INSTANT_TRICK", "DIAMOND", 1,  "万箭齐发", "aoe_defense")

-- 决斗 × 3
add_card("INSTANT_TRICK", "SPADE",   1,  "决斗", "duel")
add_card("INSTANT_TRICK", "CLUB",    1,  "决斗", "duel")
add_card("INSTANT_TRICK", "DIAMOND", 1,  "决斗", "duel")

-- 过河拆桥 × 4
add_card("INSTANT_TRICK", "CLUB",    3,  "过河拆桥", "discard_one")
add_card("INSTANT_TRICK", "SPADE",   3,  "过河拆桥", "discard_one")
add_card("INSTANT_TRICK", "SPADE",   4,  "过河拆桥", "discard_one")
add_card("INSTANT_TRICK", "HEART",   3,  "过河拆桥", "discard_one")

-- 顺手牵羊 × 4
add_card("INSTANT_TRICK", "SPADE",   3,  "顺手牵羊", "steal_one")
add_card("INSTANT_TRICK", "SPADE",   4,  "顺手牵羊", "steal_one")
add_card("INSTANT_TRICK", "CLUB",    3,  "顺手牵羊", "steal_one")
add_card("INSTANT_TRICK", "HEART",   3,  "顺手牵羊", "steal_one")

-- 无中生有 × 4
add_card("INSTANT_TRICK", "HEART",   7,  "无中生有", "draw_two")
add_card("INSTANT_TRICK", "HEART",   8,  "无中生有", "draw_two")
add_card("INSTANT_TRICK", "DIAMOND", 7,  "无中生有", "draw_two")
add_card("INSTANT_TRICK", "DIAMOND", 8,  "无中生有", "draw_two")

-- 桃园结义 × 2
add_card("INSTANT_TRICK", "HEART",   1,  "桃园结义", "mass_heal")
add_card("INSTANT_TRICK", "DIAMOND", 1,  "桃园结义", "mass_heal")

-- 五谷丰登 × 2
add_card("INSTANT_TRICK", "HEART",   3,  "五谷丰登", "mass_draw")
add_card("INSTANT_TRICK", "DIAMOND", 3,  "五谷丰登", "mass_draw")

-- 无懈可击 × 3（抵消一张锦囊牌）
add_card("INSTANT_TRICK", "SPADE",   13, "无懈可击", "counterspell")
add_card("INSTANT_TRICK", "CLUB",    13, "无懈可击", "counterspell")
add_card("INSTANT_TRICK", "DIAMOND", 11, "无懈可击", "counterspell")

-- 借刀杀人 × 2（借目标武器对另一玩家出杀，否则武器归你）
add_card("INSTANT_TRICK", "SPADE",   12, "借刀杀人", "borrow_weapon")
add_card("INSTANT_TRICK", "CLUB",    10, "借刀杀人", "borrow_weapon")

-- 火攻 × 3（目标展示一张手牌，猜中花色则1点火焰伤害）
add_card("INSTANT_TRICK", "HEART",   12, "火攻", "fire_attack")
add_card("INSTANT_TRICK", "HEART",   13, "火攻", "fire_attack")
add_card("INSTANT_TRICK", "DIAMOND", 13, "火攻", "fire_attack")

-- 铁索连环 × 6（连环两名角色，属性伤害传导；可重铸弃牌摸1）
add_card("INSTANT_TRICK", "SPADE",   10, "铁索连环", "iron_chain")
add_card("INSTANT_TRICK", "SPADE",   11, "铁索连环", "iron_chain")
add_card("INSTANT_TRICK", "CLUB",    11, "铁索连环", "iron_chain")
add_card("INSTANT_TRICK", "CLUB",    12, "铁索连环", "iron_chain")
add_card("INSTANT_TRICK", "HEART",   11, "铁索连环", "iron_chain")
add_card("INSTANT_TRICK", "HEART",    9, "铁索连环", "iron_chain")

-- ==========================================
-- DELAYED_TRICK — 延时锦囊
-- ==========================================

-- 乐不思蜀 × 3 (判定: 非HEART → 跳过出牌阶段)
add_card("DELAYED_TRICK", "SPADE",   6,  "乐不思蜀", "skip_play")
add_card("DELAYED_TRICK", "CLUB",    6,  "乐不思蜀", "skip_play")
add_card("DELAYED_TRICK", "HEART",   6,  "乐不思蜀", "skip_play")

-- 兵粮寸断 × 2 (判定: 非CLUB → 跳过摸牌阶段)
add_card("DELAYED_TRICK", "SPADE",   1,  "兵粮寸断", "skip_draw")
add_card("DELAYED_TRICK", "CLUB",    1,  "兵粮寸断", "skip_draw")

-- 闪电 × 2 (判定: SPADE 2-9 → 3点雷电伤害)
add_card("DELAYED_TRICK", "SPADE",   1,  "闪电", "lightning")
add_card("DELAYED_TRICK", "CLUB",    1,  "闪电", "lightning")

-- ==========================================
-- WEAPON — 武器 × 9
-- ==========================================
add_card("WEAPON", "SPADE",   5,  "连弩机",  "unlimited_attack")
add_card("WEAPON", "CLUB",    5,  "贯石斧", "reattempt_discard2")
add_card("WEAPON", "CLUB",    6,  "青龙偃月刀","reattempt_attack")
add_card("WEAPON", "CLUB",    8,  "丈八蛇矛", "spear_discard2")
add_card("WEAPON", "HEART",   5,  "方天画戟", "halberd_triple")
add_card("WEAPON", "DIAMOND", 5,  "古锭刀",   "blade_pierce")
add_card("WEAPON", "DIAMOND", 6,  "双刃剑",   "twin_discard")
add_card("WEAPON", "DIAMOND", 1,  "朱雀羽扇",   "fire_weapon")
add_card("WEAPON", "SPADE",   6,  "麒麟弓",   "bow_strip_horse")

-- ==========================================
-- ARMOR — 防具 × 3
-- ==========================================
add_card("ARMOR", "SPADE",   2,  "八卦阵",  "dodge_judgment")
add_card("ARMOR", "CLUB",    2,  "仁王盾",  "block_black_attack")
add_card("ARMOR", "HEART",   2,  "藤甲",    "fire_weakness")

-- ==========================================
-- HORSE — 马牌 × 8
-- ==========================================
-- offense = -1马（进攻马，攻击距离减少1）
add_card("HORSE", "SPADE",   13, "阿拉伯战马", "offense")
add_card("HORSE", "CLUB",    13, "阿拉伯战马", "offense")
add_card("HORSE", "HEART",   13, "阿拉伯战马", "offense")
add_card("HORSE", "DIAMOND", 13, "阿拉伯战马", "offense")
-- defense = +1马（防守马，被攻击距离增加1）
add_card("HORSE", "SPADE",   12, "骆驼", "defense")
add_card("HORSE", "CLUB",    12, "骆驼", "defense")
add_card("HORSE", "HEART",   12, "骆驼", "defense")
add_card("HORSE", "DIAMOND", 12, "骆驼", "defense")

-- ==========================================
-- 验证
-- ==========================================
assert(#DECK == 122, "牌堆必须是122张，当前 " .. #DECK)

-- ==========================================
-- API
-- ==========================================

--- 创建新牌堆（已洗牌）
function M.create_deck()
    -- 深拷贝
    local deck = {}
    for i, card in ipairs(DECK) do
        deck[i] = {
            id      = card.id,
            type    = card.type,
            suit    = card.suit,
            number  = card.number,
            name    = card.name,
        }
        if card.subtype then deck[i].subtype = card.subtype end
    end
    -- Fisher-Yates 洗牌
    for i = #deck, 2, -1 do
        local j = math.random(i)
        deck[i], deck[j] = deck[j], deck[i]
    end
    return deck
end

--- 牌堆元数据（客户端可查询牌型分布）
function M.get_metadata()
    local stats = {}
    local subtype_stats = {}
    for _, card in ipairs(DECK) do
        stats[card.type] = (stats[card.type] or 0) + 1
        if card.subtype then
            subtype_stats[card.subtype] = (subtype_stats[card.subtype] or 0) + 1
        end
    end
    return {
        total = #DECK,
        by_type = stats,
        by_subtype = subtype_stats,
    }
end

return M

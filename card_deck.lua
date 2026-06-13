-- card_deck.lua — 固定108张标准牌堆，中东主题命名
-- 基于三国杀标准版框架，保留火攻和酒作为变体牌
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
add_card("ATTACK", "SPADE", 7,  "Damascus Blade")
add_card("ATTACK", "SPADE", 8,  "Damascus Blade")
add_card("ATTACK", "SPADE", 9,  "Damascus Blade")
add_card("ATTACK", "SPADE", 10, "Damascus Blade")
add_card("ATTACK", "SPADE", 11, "Damascus Blade")
add_card("ATTACK", "SPADE", 12, "Damascus Blade")
add_card("ATTACK", "SPADE", 13, "Damascus Blade")
-- CLUB × 11 (2,3,4,5,6,7,8,9,10,J,Q)
add_card("ATTACK", "CLUB", 2,  "Damascus Blade")
add_card("ATTACK", "CLUB", 3,  "Damascus Blade")
add_card("ATTACK", "CLUB", 4,  "Damascus Blade")
add_card("ATTACK", "CLUB", 5,  "Damascus Blade")
add_card("ATTACK", "CLUB", 6,  "Damascus Blade")
add_card("ATTACK", "CLUB", 7,  "Damascus Blade")
add_card("ATTACK", "CLUB", 8,  "Damascus Blade")
add_card("ATTACK", "CLUB", 9,  "Damascus Blade")
add_card("ATTACK", "CLUB", 10, "Damascus Blade")
add_card("ATTACK", "CLUB", 11, "Damascus Blade")
add_card("ATTACK", "CLUB", 12, "Damascus Blade")
-- HEART × 1 (10)
add_card("ATTACK", "HEART", 10, "Damascus Blade")
-- DIAMOND × 11 (2,3,4,5,6,7,8,9,10,J,Q)
add_card("ATTACK", "DIAMOND", 2,  "Damascus Blade")
add_card("ATTACK", "DIAMOND", 3,  "Damascus Blade")
add_card("ATTACK", "DIAMOND", 4,  "Damascus Blade")
add_card("ATTACK", "DIAMOND", 5,  "Damascus Blade")
add_card("ATTACK", "DIAMOND", 6,  "Damascus Blade")
add_card("ATTACK", "DIAMOND", 7,  "Damascus Blade")
add_card("ATTACK", "DIAMOND", 8,  "Damascus Blade")
add_card("ATTACK", "DIAMOND", 9,  "Damascus Blade")
add_card("ATTACK", "DIAMOND", 10, "Damascus Blade")
add_card("ATTACK", "DIAMOND", 11, "Damascus Blade")
add_card("ATTACK", "DIAMOND", 12, "Damascus Blade")

-- ==========================================
-- DEFENSE — 闪 × 15
-- ==========================================
add_card("DEFENSE", "HEART", 2,  "Mirage")
add_card("DEFENSE", "HEART", 3,  "Mirage")
add_card("DEFENSE", "HEART", 4,  "Mirage")
add_card("DEFENSE", "HEART", 5,  "Mirage")
add_card("DEFENSE", "HEART", 6,  "Mirage")
add_card("DEFENSE", "HEART", 7,  "Mirage")
add_card("DEFENSE", "HEART", 8,  "Mirage")
add_card("DEFENSE", "HEART", 9,  "Mirage")
add_card("DEFENSE", "DIAMOND", 2,  "Mirage")
add_card("DEFENSE", "DIAMOND", 3,  "Mirage")
add_card("DEFENSE", "DIAMOND", 4,  "Mirage")
add_card("DEFENSE", "DIAMOND", 5,  "Mirage")
add_card("DEFENSE", "DIAMOND", 6,  "Mirage")
add_card("DEFENSE", "DIAMOND", 7,  "Mirage")
add_card("DEFENSE", "DIAMOND", 8,  "Mirage")

-- ==========================================
-- HEAL — 桃 × 8
-- ==========================================
add_card("HEAL", "HEART", 3,  "Date")
add_card("HEAL", "HEART", 4,  "Date")
add_card("HEAL", "HEART", 5,  "Date")
add_card("HEAL", "HEART", 6,  "Date")
add_card("HEAL", "HEART", 7,  "Date")
add_card("HEAL", "HEART", 8,  "Date")
add_card("HEAL", "HEART", 9,  "Date")
add_card("HEAL", "HEART", 12, "Date")

-- ==========================================
-- WINE — 酒 × 3（仅增伤，不可救人）
-- ==========================================
add_card("WINE", "SPADE", 3,   "Desert Heart", "damage_plus1")
add_card("WINE", "CLUB", 9,    "Desert Heart", "damage_plus1")
add_card("WINE", "DIAMOND", 9, "Desert Heart", "damage_plus1")

-- ==========================================
-- INSTANT_TRICK — 即时锦囊
-- ==========================================

-- 南蛮入侵 × 3 (aoe_attack — 响应者出 ATTACK)
add_card("INSTANT_TRICK", "SPADE",   7,  "Sandstorm", "aoe_attack")
add_card("INSTANT_TRICK", "CLUB",    7,  "Sandstorm", "aoe_attack")
add_card("INSTANT_TRICK", "HEART",   7,  "Sandstorm", "aoe_attack")

-- 万箭齐发 × 1 (aoe_defense — 响应者出 DEFENSE)
add_card("INSTANT_TRICK", "DIAMOND", 1,  "Volley", "aoe_defense")

-- 决斗 × 3
add_card("INSTANT_TRICK", "SPADE",   1,  "Duel", "duel")
add_card("INSTANT_TRICK", "CLUB",    1,  "Duel", "duel")
add_card("INSTANT_TRICK", "DIAMOND", 1,  "Duel", "duel")

-- 过河拆桥 × 6
add_card("INSTANT_TRICK", "CLUB",    3,  "Dismantle", "discard_one")
add_card("INSTANT_TRICK", "SPADE",   3,  "Dismantle", "discard_one")
add_card("INSTANT_TRICK", "SPADE",   4,  "Dismantle", "discard_one")
add_card("INSTANT_TRICK", "HEART",   3,  "Dismantle", "discard_one")
add_card("INSTANT_TRICK", "DIAMOND", 3,  "Dismantle", "discard_one")
add_card("INSTANT_TRICK", "SPADE",   12, "Dismantle", "discard_one")

-- 顺手牵羊 × 5
add_card("INSTANT_TRICK", "SPADE",   3,  "Pilfer", "steal_one")
add_card("INSTANT_TRICK", "SPADE",   4,  "Pilfer", "steal_one")
add_card("INSTANT_TRICK", "CLUB",    3,  "Pilfer", "steal_one")
add_card("INSTANT_TRICK", "HEART",   3,  "Pilfer", "steal_one")
add_card("INSTANT_TRICK", "DIAMOND", 3,  "Pilfer", "steal_one")

-- 无中生有 × 4
add_card("INSTANT_TRICK", "HEART",   7,  "Draw Two", "draw_two")
add_card("INSTANT_TRICK", "HEART",   8,  "Draw Two", "draw_two")
add_card("INSTANT_TRICK", "DIAMOND", 7,  "Draw Two", "draw_two")
add_card("INSTANT_TRICK", "DIAMOND", 8,  "Draw Two", "draw_two")

-- 桃园结义 × 1
add_card("INSTANT_TRICK", "HEART",   1,  "Mass Heal", "mass_heal")

-- 五谷丰登 × 2
add_card("INSTANT_TRICK", "HEART",   3,  "Bounty", "mass_draw")
add_card("INSTANT_TRICK", "DIAMOND", 3,  "Bounty", "mass_draw")

-- 无懈可击 × 3
add_card("INSTANT_TRICK", "SPADE",   13, "Counterspell", "counterspell")
add_card("INSTANT_TRICK", "CLUB",    13, "Counterspell", "counterspell")
add_card("INSTANT_TRICK", "DIAMOND", 11, "Counterspell", "counterspell")

-- 借刀杀人 × 2
add_card("INSTANT_TRICK", "SPADE",   12, "Borrow Blade", "borrow_weapon")
add_card("INSTANT_TRICK", "CLUB",    10, "Borrow Blade", "borrow_weapon")

-- 火攻 × 3（目标展示一张手牌，猜中花色则1点火焰伤害）
add_card("INSTANT_TRICK", "HEART",   12, "Fire Attack", "fire_attack")
add_card("INSTANT_TRICK", "HEART",   13, "Fire Attack", "fire_attack")
add_card("INSTANT_TRICK", "DIAMOND", 13, "Fire Attack", "fire_attack")

-- ==========================================
-- DELAYED_TRICK — 延时锦囊
-- ==========================================

-- 乐不思蜀 × 3 (判定非HEART → 跳过出牌阶段)
add_card("DELAYED_TRICK", "SPADE",   6,  "Skip Turn", "skip_play")
add_card("DELAYED_TRICK", "CLUB",    6,  "Skip Turn", "skip_play")
add_card("DELAYED_TRICK", "HEART",   6,  "Skip Turn", "skip_play")

-- 闪电 × 2 (判定SPADE 2-9 → 3点雷电伤害)
add_card("DELAYED_TRICK", "SPADE",   1,  "Lightning", "lightning")
add_card("DELAYED_TRICK", "CLUB",    1,  "Lightning", "lightning")

-- ==========================================
-- WEAPON — 武器 × 6
-- ==========================================
add_card("WEAPON", "SPADE",   5,  "Repeater Crossbow",   "unlimited_attack")
add_card("WEAPON", "CLUB",    5,  "Splitting Axe",   "reattempt_discard2")
add_card("WEAPON", "CLUB",    6,  "Green Dragon Blade", "reattempt_attack")
add_card("WEAPON", "CLUB",    8,  "Serpent Lance",  "spear_discard2")
add_card("WEAPON", "DIAMOND", 6,  "Double Blade",    "ignore_armor")
add_card("WEAPON", "SPADE",   6,  "Qilin Bow",    "bow_strip_horse")

-- ==========================================
-- ARMOR — 防具 × 2
-- ==========================================
add_card("ARMOR", "SPADE",   2,  "Eight Trigrams",  "dodge_judgment")
add_card("ARMOR", "CLUB",    2,  "Benevolence Shield",  "block_black_attack")

-- ==========================================
-- HORSE — 马牌 × 6
-- ==========================================
-- offense = -1马（进攻马，攻击距离减少1）
add_card("HORSE", "SPADE",   13, "Shamal", "offense")
add_card("HORSE", "CLUB",    13, "Saad", "offense")
add_card("HORSE", "HEART",   13, "Raji",   "offense")
-- defense = +1马（防守马，被攻击距离增加1）
add_card("HORSE", "SPADE",   12, "Najd",   "defense")
add_card("HORSE", "CLUB",    12, "Rahil", "defense")
add_card("HORSE", "HEART",   12, "Salim", "defense")

-- ==========================================
-- 验证
-- ==========================================
assert(#DECK == 108, "牌堆必须是108张，当前 " .. #DECK)

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

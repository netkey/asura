-- hero_catalog.lua  英雄主数据
-- tier: 0=免费默认, 1=原版500金, 2=第一批1000金, 3=第二批1500金
-- price 字段支持后期按热度单独调整，无需改动其余逻辑

local M = {}

M.HEROES = {
    -- ── Tier 0: 默认免费英雄 ──────────────────────────────────────────────
    aladdin         = { name="阿拉丁",       price=0,    tier=0,
                        description="【神灯】出牌阶段，弃置2张牌视为使用一张【无中生有】" },

    -- ── Tier 1: 原版英雄 500金 ───────────────────────────────────────────
    alibaba         = { name="阿里巴巴",     price=500,  tier=1,
                        description="【暗号】成功防御后，可对攻击者使用一张【攻击】" },
    saladin         = { name="萨拉丁",       price=500,  tier=1,
                        description="【坚守】受到伤害后，摸1张牌" },
    hakim           = { name="哈基姆",       price=500,  tier=1,
                        description="【星象】摸牌阶段看牌堆顶X张排序（X=存活人数），再摸2张" },
    scheherazade    = { name="舍赫拉莎德",   price=500,  tier=1,
                        description="【千夜】受伤时弃1张，随机看攻击者2张牌选1弃置" },
    jafar           = { name="贾法尔",       price=500,  tier=1,
                        description="【毒计】你的攻击需要目标出2张防御才能抵挡" },

    -- ── Tier 2: 第一批扩展英雄 1000金 ───────────────────────────────────
    ibn_battuta     = { name="伊本白图泰",   price=1000, tier=2,
                        description="【远行】出牌阶段，弃1张牌从弃牌堆顶取1张牌入手" },
    al_khwarizmi    = { name="花拉子密",     price=1000, tier=2,
                        description="【算法】摸牌阶段，看牌堆顶4张排序，选2张入手" },
    avicenna        = { name="阿维森纳",     price=1000, tier=2,
                        description="【医典】出牌阶段弃红桃自回1血，濒死时可用红桃救援" },
    sinbad          = { name="辛巴达",       price=1000, tier=2,
                        description="【七航】每回合结束时可取弃牌堆顶1张牌入手（每局限7次）" },
    hulagu          = { name="旭烈兀",       price=1000, tier=2,
                        description="【铁蹄】攻击时，若目标手牌数多于你，本次伤害+1" },
    rumi            = { name="鲁米",         price=1000, tier=2,
                        description="【旋回】出牌阶段开始时，可将全部手牌弃置，摸等量新牌" },
    zubaydah        = { name="祖拜达",       price=1000, tier=2,
                        description="【仁济】受伤时，令场上血量最低的其他存活玩家回复1点血量" },
    al_biruni       = { name="比鲁尼",       price=1000, tier=2,
                        description="【测量】摸牌阶段，看牌堆顶4张选2张入手，其余弃置" },
    tamerlane       = { name="帖木儿",       price=1000, tier=2,
                        description="【万骑】每回合首次造成伤害摸1张牌；击杀玩家摸3张牌" },
    dunyazad        = { name="杜尼亚扎德",   price=1000, tier=2,
                        description="【续篇】防御成功后，本回合该攻击者不能再对你使用【攻击】" },
    antar           = { name="安塔拉",       price=1000, tier=2,
                        description="【骑士之誓】每回合第一次攻击强制命中（对方无法防御）" },
    nefertiti       = { name="纳芙蒂蒂",     price=1000, tier=2,
                        description="【古仪】回合结束时，若本回合未使用任何【攻击】牌，回复1点血量" },

    -- ── Tier 3: 第二批扩展英雄 1500金 ───────────────────────────────────
    harun_al_rashid = { name="哈伦·拉希德", price=1500, tier=3,
                        description="【哈里发令】出牌阶段，指定一名玩家令其弃1张牌或受1点伤害" },
    suleiman        = { name="苏莱曼",       price=1500, tier=3,
                        description="【封印】出牌阶段，宣告一名其他玩家本回合不能使用【AOE沙尘暴】" },
    khayyam         = { name="海亚姆",       price=1500, tier=3,
                        description="【诗酒】回合结束时，若弃牌堆≥5张，将弃牌堆洗回牌堆" },
    zenobia         = { name="芝诺比娅",     price=1500, tier=3,
                        description="【铁甲女王】攻击手牌最多的玩家时，攻击强制命中" },
    muawiyah        = { name="穆阿维叶",     price=1500, tier=3,
                        description="【谋略】防御成功后，随机夺取攻击者1张手牌" },
    nizamulmulk     = { name="尼扎姆",       price=1500, tier=3,
                        description="【权谋】受到攻击伤害时，令攻击者弃置1张牌" },
    enheduanna      = { name="恩赫杜安娜",   price=1500, tier=3,
                        description="【颂词】摸牌阶段可发动，摸4张牌并交给其他角色1张手牌" },
    al_mansur       = { name="曼苏尔",       price=1500, tier=3,
                        description="【建城】击杀回满血（限3次）；一回合造成≥2伤，回合结束回1血" },
    gilgamesh       = { name="吉尔伽美什",   price=1500, tier=3,
                        description="【不朽】回合结束时，若血量<2，自动回复至2" },
    imru_al_qais    = { name="伊姆鲁盖斯",   price=1500, tier=3,
                        description="【悬诗】回合结束时，若手中【攻击】牌≥3张，额外摸1张牌" },
    basira          = { name="巴希拉",       price=1500, tier=3,
                        description="【洞察】摸牌阶段，宣告一种花色；第一张若花色匹配，额外摸1张" },
    dhul_qarnayn    = { name="双角王",       price=1500, tier=3,
                        description="【铁壁】受伤时弃1基本牌减伤1（每回合1次）；击杀收缴1手牌" },
}

return M

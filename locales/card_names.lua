-- 卡牌名 & 技能名本地化查表
-- 从 docs/card_names.json 衍生，en 为当前游戏内名，ar 待翻译
local M = {}

M.cards = {
  damascus_blade      = { en = "Damascus Blade",       ar = "" },
  mirage              = { en = "Mirage",                ar = "" },
  date                = { en = "Date",                  ar = "" },
  desert_heart        = { en = "Desert Heart",          ar = "" },
  sandstorm           = { en = "Sandstorm",             ar = "" },
  volley              = { en = "Volley",                ar = "" },
  duel                = { en = "Duel",                  ar = "" },
  dismantle           = { en = "Dismantle",             ar = "" },
  pilfer              = { en = "Pilfer",                ar = "" },
  draw_two            = { en = "Draw Two",              ar = "" },
  mass_heal           = { en = "Mass Heal",             ar = "" },
  bounty              = { en = "Bounty",                ar = "" },
  counterspell        = { en = "Counterspell",          ar = "" },
  borrow_blade        = { en = "Borrow Blade",          ar = "" },
  fire_attack         = { en = "Fire Attack",           ar = "" },
  skip_turn           = { en = "Skip Turn",             ar = "" },
  lightning           = { en = "Lightning",             ar = "" },
  repeater_crossbow   = { en = "Repeater Crossbow",     ar = "" },
  splitting_axe       = { en = "Splitting Axe",         ar = "" },
  green_dragon_blade  = { en = "Green Dragon Blade",    ar = "" },
  serpent_lance       = { en = "Serpent Lance",         ar = "" },
  double_blade        = { en = "Double Blade",          ar = "" },
  qilin_bow           = { en = "Qilin Bow",             ar = "" },
  eight_trigrams      = { en = "Eight Trigrams",        ar = "" },
  benevolence_shield  = { en = "Benevolence Shield",    ar = "" },
  shamal              = { en = "Shamal",                ar = "" },
  saad                = { en = "Saad",                  ar = "" },
  raji                = { en = "Raji",                  ar = "" },
  najd                = { en = "Najd",                  ar = "" },
  rahil               = { en = "Rahil",                 ar = "" },
  salim               = { en = "Salim",                 ar = "" },
}

M.skills = {
  magic_lamp       = { hero = "aladdin",      en = "Magic Lamp",          ar = "" },
  continuation     = { hero = "dunyazad",     en = "Continuation",        ar = "" },
  insight          = { hero = "basira",       en = "Insight",             ar = "" },
  iron_hoof        = { hero = "hulagu",       en = "Iron Hoof",           ar = "" },
  poison_plot      = { hero = "jafar",        en = "Poison Plot",         ar = "" },
  decree           = { hero = "suleiman",     en = "Decree",              ar = "" },
  iron_queen       = { hero = "zenobia",      en = "Iron Queen",          ar = "" },
  oath             = { hero = "antar",        en = "Knight's Oath",       ar = "" },
  hold_fast        = { hero = "saladin",      en = "Hold Fast",           ar = "" },
  city_building    = { hero = "al_mansur",    en = "City Building",       ar = "" },
  canon            = { hero = "avicenna",     en = "Canon",               ar = "" },
  whirl            = { hero = "rumi",         en = "Whirl",               ar = "" },
  astrology        = { hero = "hakim",        en = "Astrology",           ar = "" },
  benevolence      = { hero = "zubaydah",     en = "Benevolence",         ar = "" },
  statecraft       = { hero = "nizamulmulk",  en = "Statecraft",          ar = "" },
  fortress         = { hero = "dhul_qarnayn", en = "Fortress",            ar = "" },
  far_realm_west   = { hero = "dhul_qarnayn", en = "Far Realm - West",   ar = "" },
  far_realm_east   = { hero = "dhul_qarnayn", en = "Far Realm - East",   ar = "" },
  thousand_nights  = { hero = "scheherazade", en = "Thousand Nights",     ar = "" },
  seven_voyages    = { hero = "sinbad",       en = "Seven Voyages",       ar = "" },
  cavalry          = { hero = "tamerlane",    en = "Cavalry",             ar = "" },
  poetry_soul      = { hero = "khayyam",      en = "Poetry Soul",         ar = "" },
  strategy         = { hero = "muawiyah",     en = "Strategy",            ar = "" },
  hymn             = { hero = "enheduanna",   en = "Hymn",                ar = "" },
  immortal         = { hero = "gilgamesh",    en = "Immortal",            ar = "" },
  ancient_rite     = { hero = "nefertiti",    en = "Ancient Rite",        ar = "" },
  caliph_decree    = { hero = "harun_al_rashid", en = "Caliph's Decree",  ar = "" },
  journey          = { hero = "ibn_battuta",  en = "Journey",             ar = "" },
  code_word        = { hero = "alibaba",      en = "Code Word",           ar = "" },
  measure          = { hero = "al_biruni",    en = "Measure",             ar = "" },
  algorithm        = { hero = "al_khwarizmi", en = "Algorithm",           ar = "" },
  ode              = { hero = "imru_al_qais", en = "Ode",                 ar = "" },
}

function M.get_card_name(id, lang)
  lang = lang or "en"
  local entry = M.cards[id]
  if not entry then return id end
  local name = entry[lang]
  if name and name ~= "" then return name end
  return entry.en
end

function M.get_skill_name(id, lang)
  lang = lang or "en"
  local entry = M.skills[id]
  if not entry then return id end
  local name = entry[lang]
  if name and name ~= "" then return name end
  return entry.en
end

function M.get_hero_name(hero_id, lang)
  lang = lang or "en"
  -- 英雄名直接从英雄 id 映射（id 本身就是英文名）
  local names = {
    aladdin      = { en = "Aladdin",              ar = "" },
    alibaba      = { en = "Alibaba",              ar = "" },
    saladin      = { en = "Saladin",              ar = "" },
    hakim        = { en = "Hakim",                ar = "" },
    scheherazade = { en = "Scheherazade",          ar = "" },
    jafar        = { en = "Jafar",                ar = "" },
    ibn_battuta  = { en = "Ibn Battuta",          ar = "" },
    al_khwarizmi = { en = "Al-Khwarizmi",         ar = "" },
    avicenna     = { en = "Avicenna",             ar = "" },
    sinbad       = { en = "Sinbad",               ar = "" },
    hulagu       = { en = "Hulagu",               ar = "" },
    rumi         = { en = "Rumi",                 ar = "" },
    zubaydah     = { en = "Zubaydah",             ar = "" },
    al_biruni    = { en = "Al-Biruni",            ar = "" },
    tamerlane    = { en = "Tamerlane",            ar = "" },
    dunyazad     = { en = "Dunyazad",             ar = "" },
    antar        = { en = "Antar",                ar = "" },
    nefertiti    = { en = "Nefertiti",            ar = "" },
    harun_al_rashid = { en = "Harun al-Rashid",   ar = "" },
    suleiman     = { en = "Suleiman",             ar = "" },
    khayyam      = { en = "Khayyam",              ar = "" },
    zenobia      = { en = "Zenobia",              ar = "" },
    muawiyah     = { en = "Muawiyah",             ar = "" },
    nizamulmulk  = { en = "Nizam al-Mulk",        ar = "" },
    enheduanna   = { en = "Enheduanna",           ar = "" },
    al_mansur    = { en = "Al-Mansur",            ar = "" },
    gilgamesh    = { en = "Gilgamesh",            ar = "" },
    imru_al_qais = { en = "Imru' al-Qais",        ar = "" },
    basira       = { en = "Basira",               ar = "" },
    dhul_qarnayn = { en = "Dhul-Qarnayn",         ar = "" },
  }
  local entry = names[hero_id]
  if not entry then return hero_id end
  local name = entry[lang]
  if name and name ~= "" then return name end
  return entry.en
end

return M

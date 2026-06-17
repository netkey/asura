-- localization_manager.lua
-- 加载本地化数据并提供给 RPC 层
-- locales/*.lua 为 Lua module 格式，require 加载，零运行时开销

local en = require("locales.en")
local ar = require("locales.ar")
local card_names = require("locales.card_names")
local hero_catalog = require("hero_catalog")

local VERSION = "2026-06-17-v1"

-- 循环中复用的语言表（避免每次分配新 table）
local LOCALES = { en = true, ar = true }

local M = {}

function M.get_version()
  return VERSION
end

-- 缓存 get_bundle 结果
local _bundle_cache
local _bundle_version

function M.get_bundle()
  if _bundle_cache and _bundle_version == VERSION then
    return _bundle_cache
  end

  local out = {
    version = VERSION,
    locales = {},
    cards   = {},
    skills  = {},
    heroes  = {},
  }

  -- locales: 每个语言的 strings 表
  out.locales.en = { direction = "ltr", strings = en }
  out.locales.ar = { direction = "rtl", strings = ar }

  -- cards: 按语言拆成 key→name 查表
  for lang in pairs(LOCALES) do
    out.cards[lang] = {}
  end
  for id, entry in pairs(card_names.cards) do
    for lang in pairs(LOCALES) do
      local name = entry[lang]
      out.cards[lang][id] = (name and name ~= "") and name or entry.en
    end
  end

  -- skills: 按语言拆
  for lang in pairs(LOCALES) do
    out.skills[lang] = {}
  end
  for id, entry in pairs(card_names.skills) do
    for lang in pairs(LOCALES) do
      local name = entry[lang]
      out.skills[lang][id] = (name and name ~= "") and name or entry.en
    end
  end

  -- heroes: 从 hero_catalog 获取 ID 列表，避免硬编码重复
  for lang in pairs(LOCALES) do
    out.heroes[lang] = {}
  end
  for _, hid in ipairs(hero_catalog.all_ids()) do
    for lang in pairs(LOCALES) do
      out.heroes[lang][hid] = card_names.get_hero_name(hid, lang)
    end
  end

  _bundle_cache = nk.json_encode(out)
  _bundle_version = VERSION
  return _bundle_cache
end

-- 返回版本号（轻量检查）
function M.get_version_json()
  return nk.json_encode({ version = VERSION })
end

-- 广播辅助：将 template_key + params 拼成 { template, params, content }
-- content 为英文本地化回退（客户端无 locale 缓存时可用）
-- params 以 _id 或 _key 结尾的字段由客户端查表，其余直接替换
function M.bc(template_key, params)
  local template = en[template_key]
  local content
  if template and params then
    content = template
    for k, v in pairs(params) do
      -- Lua gsub 中 % 是替换字符串转义符，需要双重转义
      content = content:gsub("{" .. k .. "}", tostring(v):gsub("%%", "%%%%"))
    end
  else
    content = template or template_key
  end
  return {
    template = template_key,
    params = params or {},
    content = content,
  }
end

-- 将 card.name（如 "Damascus Blade"）转为 bundle 查找键（如 "damascus_blade"）
-- 供 bc() 调用点以 card_id 传参使客户端做本地化查找
function M.card_lookup_key(name)
  return name:lower():gsub(" ", "_")
end

-- 日志用：获取本地化卡牌名（回退链 ar→en）
function M.log_card_name(card_id, lang)
  return card_names.get_card_name(card_id, lang)
end

-- 日志用：获取本地化英雄名
function M.log_hero_name(hero_id, lang)
  return card_names.get_hero_name(hero_id, lang)
end

return M

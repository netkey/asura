-- skin_catalog.lua  英雄皮肤目录
--
-- 客户端资源命名约定：
--   本地路径：  skins/{hero_id}/{skin_id}/
--   默认皮肤：  skin_id=nil 时加载 skins/{hero_id}/default/
--   CDN 模式：  asset_url 非 nil 时，客户端从该 URL 下载资源包（当前均为 nil）
--
-- 每个英雄必须有且仅有一条 is_default=true 的皮肤用于回退。
-- 默认皮肤 price=0，不在商城展示，不可购买。

local M = {}

-- ==========================================
-- 皮肤定义表
-- ==========================================
M.SKINS = {

    -- ======== 阿拉丁 ========
    aladdin_default = {
        hero_id    = "aladdin",
        name_cn    = "阿拉丁（默认）",
        price      = 0,
        is_default = true,
        asset_url  = nil,
    },
    aladdin_golden = {
        hero_id    = "aladdin",
        name_cn    = "黄金神灯",
        price      = 680,
        is_default = false,
        asset_url  = nil,
    },
    aladdin_shadow = {
        hero_id    = "aladdin",
        name_cn    = "暗影窃贼",
        price      = 980,
        is_default = false,
        asset_url  = nil,
    },

    -- ======== 哈基姆 ========
    hakim_default = {
        hero_id    = "hakim",
        name_cn    = "哈基姆（默认）",
        price      = 0,
        is_default = true,
        asset_url  = nil,
    },
    hakim_celestial = {
        hero_id    = "hakim",
        name_cn    = "天文学者",
        price      = 680,
        is_default = false,
        asset_url  = nil,
    },
    hakim_ancient = {
        hero_id    = "hakim",
        name_cn    = "远古智者",
        price      = 1280,
        is_default = false,
        asset_url  = nil,
    },

    -- ======== 阿里巴巴 ========
    alibaba_default = {
        hero_id    = "alibaba",
        name_cn    = "阿里巴巴（默认）",
        price      = 0,
        is_default = true,
        asset_url  = nil,
    },
    alibaba_merchant = {
        hero_id    = "alibaba",
        name_cn    = "丝路商人",
        price      = 680,
        is_default = false,
        asset_url  = nil,
    },

    -- ======== 萨拉丁 ========
    saladin_default = {
        hero_id    = "saladin",
        name_cn    = "萨拉丁（默认）",
        price      = 0,
        is_default = true,
        asset_url  = nil,
    },
    saladin_crusader = {
        hero_id    = "saladin",
        name_cn    = "圣战骑士",
        price      = 880,
        is_default = false,
        asset_url  = nil,
    },
}

-- ==========================================
-- 辅助函数
-- ==========================================

-- 返回某英雄的所有皮肤列表（含默认皮肤）
function M.get_by_hero(hero_id)
    local result = {}
    for skin_id, info in pairs(M.SKINS) do
        if info.hero_id == hero_id then
            local entry = {}
            for k, v in pairs(info) do entry[k] = v end
            entry.id = skin_id
            table.insert(result, entry)
        end
    end
    return result
end

-- 返回某英雄的默认 skin_id
function M.get_default(hero_id)
    for skin_id, info in pairs(M.SKINS) do
        if info.hero_id == hero_id and info.is_default then
            return skin_id
        end
    end
    return nil
end

-- 校验 skin_id 是否存在
function M.exists(skin_id)
    return M.SKINS[skin_id] ~= nil
end

return M

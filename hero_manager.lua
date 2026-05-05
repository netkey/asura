local M = {}
-- 自动加载所有英雄脚本
local heroes = {
    -- 原版 6 英雄
    aladdin      = require("heroes.aladdin"),
    alibaba      = require("heroes.alibaba"),
    saladin      = require("heroes.saladin"),
    hakim        = require("heroes.hakim"),
    scheherazade = require("heroes.scheherazade"),
    jafar        = require("heroes.jafar"),
    -- 第一批扩展 12 英雄
    ibn_battuta  = require("heroes.ibn_battuta"),
    al_khwarizmi = require("heroes.al_khwarizmi"),
    avicenna     = require("heroes.avicenna"),
    sinbad       = require("heroes.sinbad"),
    hulagu       = require("heroes.hulagu"),
    rumi         = require("heroes.rumi"),
    zubaydah     = require("heroes.zubaydah"),
    al_biruni    = require("heroes.al_biruni"),
    tamerlane    = require("heroes.tamerlane"),
    dunyazad     = require("heroes.dunyazad"),
    antar        = require("heroes.antar"),
    nefertiti    = require("heroes.nefertiti"),
    -- 第二批扩展 12 英雄
    harun_al_rashid = require("heroes.harun_al_rashid"),
    suleiman     = require("heroes.suleiman"),
    khayyam      = require("heroes.khayyam"),
    zenobia      = require("heroes.zenobia"),
    muawiyah     = require("heroes.muawiyah"),
    nizamulmulk  = require("heroes.nizamulmulk"),
    enheduanna   = require("heroes.enheduanna"),
    al_mansur    = require("heroes.al_mansur"),
    gilgamesh    = require("heroes.gilgamesh"),
    imru_al_qais = require("heroes.imru_al_qais"),
    basira       = require("heroes.basira"),
    dhul_qarnayn = require("heroes.dhul_qarnayn"),
}

function M.trigger(hook_name, dispatcher, state, player_id, ...)
    local hero_id = state.players[player_id].hero
    local hero_mod = heroes[hero_id]
    if hero_mod and hero_mod[hook_name] then
        -- 执行钩子函数
        return hero_mod[hook_name](dispatcher, state, player_id, ...)
    end
    return false
end


-- 处理技能反馈（玩家点击了UI上的确认、取消或选择了卡牌）
function M.handle_response(dispatcher, state, player_id, payload)
    local action = state.pending_action
    if not action then return end

    -- 只有被询问的玩家才能响应
    if action.player_id ~= player_id then return end

    -- 根据 pending_action 记录的 hero_id 找到对应的模块
    local hero_mod = heroes[action.hero_id]
    if hero_mod and hero_mod.on_response then
        -- 调用具体英雄脚本里的响应处理
        hero_mod.on_response(dispatcher, state, player_id, payload)
    end
end

return M

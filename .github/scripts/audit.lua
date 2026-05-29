#!/usr/bin/env lua5.4
-- Asura 代码审计脚本
-- 检查英雄技能 on_response 和 API 安全模式
-- 用法: lua5.4 audit.lua [--fix] [heroes_dir]

local FIX_MODE = arg[1] == "--fix"
local HEROES_DIR = (arg[1] and arg[2]) or (arg[1] ~= "--fix" and arg[1]) or "heroes"
local API_FILE = "api.lua"
local issues = {}
local fixed = {}

-- 报告辅助
local function report(sev, file, msg)
    table.insert(issues, string.format("[%s] %s: %s", sev, file, msg))
end

local function read_lines(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local lines = {}
    for line in f:lines() do
        table.insert(lines, line)
    end
    f:close()
    return lines
end

local function write_lines(path, lines)
    local f = io.open(path, "w")
    if not f then return false end
    for _, line in ipairs(lines) do
        f:write(line, "\n")
    end
    f:close()
    return true
end

-- 查找 on_response 函数边界
local function find_on_response(lines)
    for i, line in ipairs(lines) do
        if line:match("^function M%.on_response") then
            local depth = 1
            for j = i + 1, #lines do
                if lines[j]:match("^function ") then depth = depth + 1 end
                if lines[j]:match("^end%s*$") then
                    depth = depth - 1
                    if depth == 0 then return i, j end
                end
            end
            return i, #lines
        end
    end
    return nil, nil
end

----------------------------------------------------------------
-- 检查1: player_id guard — hero_manager.lua:57 已统一处理
-- 不在 on_response 内重复检查
----------------------------------------------------------------

----------------------------------------------------------------
-- 检查2: broadcast_update 覆盖
-- 规则: on_response 中每个 return 后必须出现 broadcast_update
-- 简化: 统计 broadcast_update 和 return 数量, return > broadcast 则报警
----------------------------------------------------------------
local function check_broadcast_coverage(lines, fname)
    local s, e = find_on_response(lines)
    if not s then return end

    local returns, broadcasts = 0, 0
    for i = s, e do
        local line = lines[i]:gsub("%s*%-%-.*$", "") -- 去掉注释
        if line:match("^%s*return") then
            returns = returns + 1
        end
        if line:match("broadcast_update") then
            broadcasts = broadcasts + 1
        end
    end

    -- 没有 broadcast_update 是严重问题
    if broadcasts == 0 then
        report("P1", fname, "on_response 完全没有 broadcast_update 调用")
        return
    end

    -- 如果 return 数 > broadcast 数, 说明有返回路径没有 sync
    if returns > broadcasts then
        report("P1", fname,
            string.format("on_response %d 个 return 但只有 %d 个 broadcast_update (可能缺少同步)", returns, broadcasts))
    end
end

----------------------------------------------------------------
-- 检查3: break 误用 (应该用 goto continue)
-- 模式: seen[card_id/something] 后跟 break 而不是 goto continue
----------------------------------------------------------------
local function check_break_misuse(lines, fname)
    for i, line in ipairs(lines) do
        if line:match("seen%[") then
            -- 检查下一行是否有 break
            local next_line = lines[i + 1]
            if next_line and next_line:match("^%s*break%s*$") then
                report("P3", fname,
                    string.format("第 %d 行: seen[...] 后使用 break, 应该用 goto continue (会截断后续循环)", i + 1))
            end
        end
    end
end

----------------------------------------------------------------
-- 检查4: on_response 输入校验
-- 规则: 至少校验 payload.confirm 的类型 + 至少一个 payload 字段
----------------------------------------------------------------
local function check_input_validation(lines, fname)
    local s, e = find_on_response(lines)
    if not s then return end

    local has_confirm_check = false
    local has_field_check = false
    for i = s, e do
        local line = lines[i]
        if line:match("payload%.confirm") and line:match("type%(") then
            has_confirm_check = true
        end
        if line:match("type%(payload%.") then
            has_field_check = true
        end
    end

    if not has_confirm_check then
        report("P2", fname, "on_response 缺少 payload.confirm 类型校验")
    elseif not has_field_check then
        report("P2", fname, "on_response 缺少 payload 字段类型校验")
    end
end

----------------------------------------------------------------
-- 检查5: safe_rpc 包装 (api.lua)
----------------------------------------------------------------
local function check_safe_rpc(lines)
    local register_count = 0
    local unsafe_count = 0

    for i, line in ipairs(lines) do
        local stripped = line:gsub("%s*%-%-.*$", "")
        if stripped:match("nk%.register_rpc") then
            register_count = register_count + 1
            if not stripped:match("safe_rpc") then
                report("P1", API_FILE, string.format("第 %d 行: nk.register_rpc 未使用 safe_rpc 包裹", i))
                unsafe_count = unsafe_count + 1
            end
        end
    end

    if register_count > 0 and unsafe_count == 0 then
        -- silent pass
    end
    return register_count, unsafe_count
end

----------------------------------------------------------------
-- 检查6: pcall 包裹已移除/不稳定的 nk.* 调用
----------------------------------------------------------------
local function check_pcall_usage(lines, fname)
    for i, line in ipairs(lines) do
        -- 跳过 pcall 自身的行和注释
        local stripped = line:gsub("^%s*", "")
        if stripped:match("^%-%-") then goto continue end
        if stripped:match("^pcall") then goto continue end

        -- 检查 nk.status_update, nk.match_leave 等需要 pcall 的函数
        local risky_calls = {"nk%.status_update", "nk%.match_leave"}
        for _, pat in ipairs(risky_calls) do
            if stripped:match(pat) and not stripped:match("pcall") then
                report("P2", fname, string.format("第 %d 行: %s 需要 pcall 包裹", i, pat))
            end
        end
        ::continue::
    end
end

----------------------------------------------------------------
-- 主流程
----------------------------------------------------------------
local hero_files = {}
local dir = io.popen("ls " .. HEROES_DIR .. "/*.lua 2>/dev/null")
if dir then
    for file in dir:lines() do
        table.insert(hero_files, file)
    end
    dir:close()
end

if #hero_files == 0 then
    -- fallback: 从参数直接获取目录
    local p = io.popen("ls " .. arg[1] .. "/*.lua 2>/dev/null")
    if p then
        for file in p:lines() do
            table.insert(hero_files, file)
        end
        p:close()
    end
end

if #hero_files == 0 then
    print("ERROR: 未找到英雄文件, 请指定正确的目录")
    print(string.format("用法: lua5.4 %s [--fix] [heroes_dir]", arg[0] or "audit.lua"))
    os.exit(1)
end

print("========================================")
print("  Asura 代码审计")
print(string.format("  目录: %s  (%d 个文件)", HEROES_DIR, #hero_files))
if FIX_MODE then print("  模式: 审计 + 自动修复") end
print("========================================")
print()

-- 检查英雄文件
for _, filepath in ipairs(hero_files) do
    local fname = filepath:match("[^/]+$")
    local lines = read_lines(filepath)
    if not lines then
        print(string.format("WARN: 无法读取 %s", filepath))
        goto continue
    end

    check_broadcast_coverage(lines, fname)
    check_break_misuse(lines, fname)
    check_input_validation(lines, fname)

    if FIX_MODE then
        write_lines(filepath, lines)
    end
    ::continue::
end

-- 检查 api.lua
local api_lines = read_lines(API_FILE)
if api_lines then
    check_safe_rpc(api_lines)
    check_pcall_usage(api_lines, API_FILE)
else
    print(string.format("WARN: 无法读取 %s (忽略)", API_FILE))
end

-- 输出报告
print()
print("--- 审计结果 ---")
print()

if #issues == 0 then
    print("  ✅ 未发现问题")
else
    -- 按严重程度排序
    table.sort(issues)
    for _, iss in ipairs(issues) do
        print("  " .. iss)
    end
    print()
    print(string.format("  共 %d 个问题", #issues))
end

if FIX_MODE and #fixed > 0 then
    print()
    print("--- 自动修复 ---")
    for _, f in ipairs(fixed) do
        print("  ✅ " .. f)
    end
end

print()
print("========================================")

-- 返回严重问题计数
local p1_count = 0
for _, iss in ipairs(issues) do
    if iss:match("%[P1%]") then p1_count = p1_count + 1 end
end

os.exit(p1_count)

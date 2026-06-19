#!/bin/bash
# Asura Bug Fix Loop — 每日 12:00 / 18:00 巡检
# 调用方式: crontab
# 0 12,18 * * * /Users/yalla/work/mycode/asura/.claude/cron_check_bugs.sh >> /tmp/asura_bug_fix.log 2>&1

set -e

PROJECT_DIR="/Users/yalla/work/mycode/asura"
LOG_FILE="/tmp/asura_bug_fix.log"
SEEN_FILE="/tmp/asura_seen_issues"

cd "$PROJECT_DIR"

echo "===== $(date '+%Y-%m-%d %H:%M:%S') ====="

# 拉取最新 issue 列表
NEW_ISSUES=$(gh issue list --repo netkey/asura --limit 20 --state open --label server-bug --json number,title --jq '.[] | "\(.number)|\(.title)"' 2>/dev/null)

if [ -z "$NEW_ISSUES" ]; then
    echo "无 open server-bug issue"
    exit 0
fi

# 检查是否有未处理的新 issue
HAS_NEW=false
while IFS='|' read -r num title; do
    if ! grep -q "^${num}$" "$SEEN_FILE" 2>/dev/null; then
        echo "新 issue: #$num — $title"
        HAS_NEW=true
    fi
done <<< "$NEW_ISSUES"

if [ "$HAS_NEW" = false ]; then
    echo "所有 open issue 已处理"
    exit 0
fi

# 有新 issue，调用 Claude Code 修复
echo "发现新 server-bug issue，启动 Claude Code 修复流程..."

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export HOME="$HOME"

/Users/yalla/.local/bin/claude -p \
    --permission-mode auto \
    "有新 server-bug issue（netkey/asura, label: server-bug），执行修复：
1. gh issue list --repo netkey/asura --label server-bug --state open 列出新 issue
2. 对 /tmp/asura_seen_issues 中未记录的 issue，逐个读取详情
3. 确认 bug 真实性（读相关 Lua 代码）
4. 修复代码 + luacheck lint
5. git checkout -b fix/issue-{N} && git commit && git push
6. gh pr create --label bug --body 'Refs #{N}'（PR 关联 issue，不自动关闭；由 Hermes 生产复测后关闭）
7. gh issue comment {N} 报告修复完成 + PR 链接
8. 处理完的 issue 编号 echo 追加到 /tmp/asura_seen_issues" \
    2>&1

echo "===== 完成 ====="

#!/usr/bin/env python3
"""
Hermes Bug Reporter — VPS 端自动分析测试结果并提交 GitHub Issue

用法:
  python3 hermes_bug_reporter.py <test_log_file>
  python3 hermes_bug_reporter.py --stdin          # 从 stdin 读取
  python3 hermes_bug_reporter.py --last-run       # 读取最近一次测试日志

集成方式 (在 retest_server.py 测试完成后调用):
  subprocess.run([sys.executable, '/root/.hermes/scripts/hermes_bug_reporter.py',
                  test_log_path], check=False)

环境变量:
  GITHUB_TOKEN    GitHub PAT (需要 repo scope)
  GITHUB_REPO     ���认 netkey/asura
"""

import json
import os
import re
import sys
import urllib.request
import urllib.error
from pathlib import Path

REPO = os.environ.get("GITHUB_REPO", "netkey/asura")
TOKEN = os.environ.get("GITHUB_TOKEN", "")
API_BASE = f"https://api.github.com/repos/{REPO}"

# ── 崩溃模式匹配 ─────────────────────────────────────────────
CRASH_PATTERNS = [
    # demo_concurrent.lua 崩溃格式: "错误: ..."
    (r"错误:\s*(.+)", "CRASH"),
    # Lua 运行时错误
    (r"attempt to (call|index|concatenate|perform arithmetic on)\s*(.+)", "RUNTIME_ERROR"),
    (r"bad argument\s*(.+)", "BAD_ARGUMENT"),
    (r"stack traceback:", "STACK_TRACEBACK"),
    # 断言失败
    (r"assertion failed!?\s*(.+)", "ASSERT"),
    # 通用 Lua 错误
    (r"([^:]+):(\d+):\s*(.+)", "LUA_ERROR"),
]

# ── 对局结果解析 ─────────────────────────────────────────────
MATCH_LINE = re.compile(r"对局(\d+)\s+\[(2P|5P)\]\s+(.+?)\s+共(\d+)回合\s+(.+)")
CRASH_LINE = re.compile(r"错误:\s*(.+)")


def parse_test_output(text: str) -> list[dict]:
    """解析测试输出，提取所有崩溃/异常对局"""
    bugs = []
    lines = text.split("\n")

    current_bug = None
    for i, line in enumerate(lines):
        # 匹配崩溃对局
        m = MATCH_LINE.match(line.strip())
        if m:
            match_id = m.group(1)
            mode = m.group(2)
            result = m.group(3).strip()
            turns = m.group(4)
            status = m.group(5).strip()

            if "崩溃" in status:
                current_bug = {
                    "match_id": match_id,
                    "mode": mode,
                    "result": result,
                    "turns": turns,
                    "error_lines": [],
                    "context_before": [],
                }
                # 记录前 3 行上下文
                start = max(0, i - 3)
                current_bug["context_before"] = [
                    l.strip() for l in lines[start:i] if l.strip()
                ]
            continue

        # 收集错误信息
        if current_bug:
            stripped = line.strip()
            if stripped.startswith("错误:") or stripped.startswith("错误："):
                current_bug["error_lines"].append(stripped)
                # 检查后续行是否有更多错误信息
                for j in range(i + 1, min(i + 10, len(lines))):
                    next_line = lines[j].strip()
                    if match_final_summary(next_line):
                        break
                    if next_line and not next_line.startswith("══") and not next_line.startswith("──"):
                        if not MATCH_LINE.match(next_line):
                            current_bug["error_lines"].append(next_line)
                            break
                bugs.append(current_bug)
                current_bug = None

    # 最终汇总检查: "存在 N 局崩溃" 或 exit code 1
    if not bugs:
        for line in lines:
            m = re.search(r"存在\s*(\d+)\s*局崩溃", line)
            if m and int(m.group(1)) > 0:
                bugs.append({
                    "match_id": "?",
                    "mode": "?",
                    "result": "?",
                    "turns": "?",
                    "error_lines": ["测试退出码为 1, 但未能自动解析崩溃详情"],
                    "context_before": [],
                })

    return bugs


def match_final_summary(line: str) -> bool:
    return bool(re.match(r"(随机英雄测试全部|英雄技能触发|══|──)", line))


def find_similar_issues(bug_signature: str) -> list[str]:
    """搜索是否已有类似 issue，返回匹配的 issue 编号列表"""
    # 提取错误消息的关键词
    keywords = re.findall(r"[a-zA-Z_]+", bug_signature)
    if not keywords:
        return []

    query = "+".join(keywords[:6])  # 最多取 6 个关键词
    url = f"{API_BASE}/issues?state=open&labels=bug&per_page=10"

    try:
        req = urllib.request.Request(url)
        req.add_header("Authorization", f"Bearer {TOKEN}")
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("User-Agent", "Hermes-Bug-Reporter/1.0")

        with urllib.request.urlopen(req, timeout=10) as resp:
            issues = json.loads(resp.read().decode())
            # 简单相似度: title 包含相同的关键错误词
            similar = []
            for issue in issues:
                title = issue.get("title", "").lower()
                matches = sum(1 for kw in keywords if kw.lower() in title)
                if matches >= 2:  # 至少 2 个关键词匹配
                    similar.append(str(issue["number"]))
            return similar
    except Exception:
        return []  # 网络/API 错误时保守处理：不阻止提交


def create_github_issue(title: str, body: str, labels: list[str]) -> str | None:
    """创建 GitHub issue，返回 issue URL 或 None"""
    payload = json.dumps({
        "title": title,
        "body": body,
        "labels": labels,
    }).encode()

    url = f"{API_BASE}/issues"
    req = urllib.request.Request(url, data=payload, method="POST")
    req.add_header("Authorization", f"Bearer {TOKEN}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", "Hermes-Bug-Reporter/1.0")
    req.add_header("Content-Type", "application/json")

    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            result = json.loads(resp.read().decode())
            return result.get("html_url")
    except urllib.error.HTTPError as e:
        print(f"[ERROR] GitHub API 返回 {e.code}: {e.reason}", file=sys.stderr)
        body_text = e.read().decode() if e.fp else ""
        print(f"[ERROR] {body_text[:500]}", file=sys.stderr)
        return None
    except Exception as e:
        print(f"[ERROR] 提 issue 失败: {e}", file=sys.stderr)
        return None


def build_issue_body(bug: dict, raw_context: str = "") -> str:
    """构建 issue 正文"""
    lines = [
        "## 自动检测到服务端崩溃",
        "",
        "| 字段 | 值 |",
        "|------|-----|",
        f"| 对局 | #{bug['match_id']} |",
        f"| 模式 | {bug['mode']} |",
        f"| 回合 | {bug['turns']} |",
        "",
        "### 错误信息",
        "```",
    ]
    for err in bug.get("error_lines", []):
        lines.append(err)
    lines.append("```")

    if bug.get("context_before"):
        lines.append("")
        lines.append("### 上下文（崩溃前）")
        lines.append("```")
        for ctx in bug["context_before"][-5:]:  # 最多 5 行
            lines.append(ctx)
        lines.append("```")

    lines.append("")
    lines.append("---")
    lines.append("*此 issue 由 Hermes 自动检测系统生成*")

    return "\n".join(lines)


def main():
    if not TOKEN:
        print("[FATAL] GITHUB_TOKEN 环境变量未设置", file=sys.stderr)
        sys.exit(1)

    # ── 读取输入 ──────────────────────────────────────────
    text = ""
    if len(sys.argv) >= 2:
        if sys.argv[1] == "--stdin":
            text = sys.stdin.read()
        elif sys.argv[1] == "--last-run":
            # 尝试读取最近的测试日志
            candidates = sorted(
                Path("/tmp").glob("retest_*.log"),
                key=lambda p: p.stat().st_mtime, reverse=True,
            )
            if candidates:
                text = candidates[0].read_text(encoding="utf-8", errors="replace")
                print(f"[INFO] 读取日志: {candidates[0]}", file=sys.stderr)
            else:
                print("[FATAL] 未找到测试日志文件", file=sys.stderr)
                sys.exit(1)
        else:
            path = Path(sys.argv[1])
            if not path.exists():
                print(f"[FATAL] 文件不存在: {sys.argv[1]}", file=sys.stderr)
                sys.exit(1)
            text = path.read_text(encoding="utf-8", errors="replace")
    else:
        text = sys.stdin.read()

    if not text.strip():
        print("[INFO] 测试输出为空，无 bug 需要报告")
        sys.exit(0)

    # ── 解析 ──────────────────────────────────────────────
    bugs = parse_test_output(text)

    if not bugs:
        print("[INFO] 未检测到崩溃，无需提交 issue")
        # 仍然输出最终摘要
        for line in text.split("\n"):
            if "随机英雄测试全部运行完毕" in line:
                print(f"[OK] {line.strip()}")
        sys.exit(0)

    print(f"[INFO] 检测到 {len(bugs)} 个崩溃")

    # ── 去重 + 提交 issue ──────────────────────────────────
    created = 0
    skipped = 0
    for bug in bugs:
        sig = " ".join(bug.get("error_lines", []))
        similar = find_similar_issues(sig)

        if similar:
            print(f"[SKIP] 对局#{bug['match_id']}: 已有类似 issue #{','.join(similar)}")
            skipped += 1
            continue

        # 提取第一个错误行作为 title
        first_error = (
            bug.get("error_lines", ["未知崩溃"])[0]
            .replace("错误:", "")
            .replace("错误：", "")
            .strip()[:120]
        )
        title = f"🐛 [Hermes] 对局#{bug['match_id']}: {first_error}"
        body = build_issue_body(bug)

        url = create_github_issue(title, body, ["bug"])
        if url:
            print(f"[OK] {url}")
            created += 1
        else:
            print(f"[FAIL] 对局#{bug['match_id']} 提交失败")

    print(f"\n[SUMMARY] 提交 {created} 个, 跳过 {skipped} 个 (重复), "
          f"检测 {len(bugs)} 个崩溃")

    sys.exit(0 if created > 0 or skipped == len(bugs) else 0)


if __name__ == "__main__":
    main()

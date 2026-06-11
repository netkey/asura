# Hermes Bug Reporter — VPS 部署说明

## 架构

```
deploy.yml (GitHub Actions)
  └─ Notify Hermes to retest → POST /retest
       └─ retest_server.py 运行测试
            └─ 测试完成后调用 hermes_bug_reporter.py  ← 【新增】
                 └─ 自动解析崩溃 → gh issue create --label bug
                      └─ Claude Code Loop 监听到新 issue → 修复 → PR
```

## 一步部署

在 VPS 上执行：

```bash
# 1. 复制脚本到 Hermes 目录
cp /data/nakama/modules/scripts/hermes_bug_reporter.py /root/.hermes/scripts/

# 2. 设置 GitHub Token（Hermes 需要 repo scope 提 issue）
# 在 /root/.hermes/.env 中添加:
echo 'GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx' >> /root/.hermes/.env

# 3. 在 retest_server.py 的测试完成回调中加入:
#    (具体接入点取决于 retest_server.py 的实现)
#
#    import subprocess, sys, os
#    from pathlib import Path
#
#    env = os.environ.copy()
#    # 从 .env 文件加载 GITHUB_TOKEN
#    env_file = Path('/root/.hermes/.env')
#    if env_file.exists():
#        for line in env_file.read_text().splitlines():
#            if '=' in line and not line.startswith('#'):
#                k, v = line.split('=', 1)
#                env[k.strip()] = v.strip()
#
#    subprocess.run(
#        [sys.executable, '/root/.hermes/scripts/hermes_bug_reporter.py',
#         test_log_path],
#        env=env, check=False
#    )

# 4. 验证
echo '错误: attempt to index a nil value (global '"'"'state'"'"')' \
  | python3 /root/.hermes/scripts/hermes_bug_reporter.py --stdin
# 预期输出: [INFO] 检测到 1 个崩溃 → [OK] https://github.com/netkey/asura/issues/N
```

## 工作原理

1. **输入**: 测试日志文件路径、stdin、或 `--last-run`（自动找最新日志）
2. **解析**: 正则匹配 `对局\d+.*崩溃` + `错误: ...` 模式
3. **去重**: 搜索 open bug issue，关键词匹配 ≥2 个则跳过
4. **提交**: GitHub API 创建 issue，label=bug，title 前缀 `🐛 [Hermes]`

## 测试日志格式要求

脚本解析 `demo_concurrent.lua` 的输出格式：
```
对局03  [5P]  未结束  共120回合  ✗ 崩溃
         错误: game_rules.lua:847: attempt to index a nil value (global 'state')
```

如果你的 Hermes 测试输出格式不同，修改 `MATCH_LINE` 和 `CRASH_LINE` 正则即可。

---
description: super-harness 项目初始化 / 升级后刷新：检查前置条件（harness-zh ≥ 0.2.1、git ≥ 2.38、claude CLI），投递资产到 .claude/super-harness/，分析 sprint-status 的 depends_on 覆盖情况
argument-hint: ''
allowed-tools: Bash, Read
---

# /super-harness:init

首次使用和每次升级 plugin 之后都执行本命令。它是幂等的：不会覆盖已有的 `.claude/super-harness/config.yaml`，内容有变化的脚本和 prompt 会先备份再覆盖。

## 1. 找到 plugin 目录

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
[ -n "$PLUGIN_ROOT" ] && [ -f "$PLUGIN_ROOT/scripts/superh.py" ] || PLUGIN_ROOT=""
if [ -z "$PLUGIN_ROOT" ]; then
    PLUGIN_ROOT="$(
        find ~/.claude/plugins/cache ~/.claude/plugins/marketplaces -maxdepth 6 -name plugin.json 2>/dev/null \
        | while IFS= read -r m; do
            command grep -q '"name":[[:space:]]*"super-harness"' "$m" 2>/dev/null || continue
            c="$(dirname "$(dirname "$m")")"
            [ -f "$c/.orphaned_at" ] && continue
            [ -f "$c/scripts/superh.py" ] || continue
            printf '%s\t%s\n' "$(basename "$c")" "$c"
          done | sort -V -r -k1,1 | head -n 1 | cut -f2-
    )"
fi
[ -n "$PLUGIN_ROOT" ] || { echo "找不到 super-harness plugin 目录"; exit 1; }
echo "PLUGIN_ROOT=$PLUGIN_ROOT"
```

找不到时停下，请用户确认已经执行过 `/plugin install super-harness@my-cc-plugin`。

## 2. 前置条件

逐项检查，把结果列成一张表给用户（项目 / 结果 / 处理办法）：

| 项 | 检查方式 | 不满足时 |
|---|---|---|
| 在 git 仓库根目录 | `git rev-parse --show-toplevel` 等于 `$PWD` | 停下 |
| git ≥ 2.38 | `git --version`（合流用到 `rebase --update-refs`） | 停下 |
| claude CLI | `command -v claude` | 停下（worker 是 headless `claude -p` 进程） |
| harness-zh 已部署 | `.claude/harness/scripts/harness-commit.py` 存在，并且 `grep -q build-verify` 能在里面找到 | 停下，请先执行 `/harness-zh:init`（需要 harness-zh ≥ 0.2.1） |
| sprint-status | `python3 .claude/harness/scripts/sprint-status.py count` 成功 | 提醒先跑 bmad-sprint-planning，不停下 |

## 3. 投递

```bash
bash "$PLUGIN_ROOT/scripts/deploy.sh" "$PLUGIN_ROOT" "$PWD"
```

最后一行是 `deploy: installed=… updated=… unchanged=…`，原样告诉用户。退出码非 0 时停下。

## 4. 分析

1. `python3 .claude/super-harness/scripts/superh.py env`：告诉用户 worktree 会放在哪个目录（`worktree_root`），状态存在哪里（`state_dir`）。
2. `python3 .claude/super-harness/scripts/superh.py plan --json`：统计未完成的 story 里有多少条声明了 `depends_on`（`deps` 不为 null）。
   - 一条都没有：说明在默认的 `no_deps_policy: serial` 下，super-harness 的行为和 harness-zh 一样，一次只跑一路。给用户三个办法：在 sprint-status.yaml 里给 story 补 `depends_on`；在 `.claude/super-harness/config.yaml` 的 `deps_overrides` 里补；或者把 `no_deps_policy` 改成 `epic-parallel`（同一 epic 内全部视为独立，冲突交给合流阶段处理）。
   - 有一部分：列出有多少条现在就能并行（`state = ready`）。
3. lane worktree 里需要的基建文件：执行 `python3 .claude/super-harness/scripts/superh.py doctor`（只读）。
   - `STATUS=ok`：把 `OK=` 行的结论告诉用户即可。
   - `STATUS=attention`：把 `PROBLEM=` 行和 `GITIGNORE=` 行原样告诉用户。这些路径复制或软链进 lane 后会让 lane 变脏，worker 无法启动。请用户把 `GITIGNORE=` 给出的行加进项目 `.gitignore` 并提交。由用户决定，你不要自己改 `.gitignore`，也不要改 `.git/info/exclude`。
4. 主 worktree 是否干净：`git status --porcelain`。`.claude/super-harness/` 下的新文件会让主 worktree 变脏，而合流要求主 worktree 干净。请用户二选一：把它们提交进 git（推荐，config.yaml 是项目配置），或者加进 `.gitignore`。由用户决定，你不要自己 commit。

## 5. 收尾

告诉用户：

- 配置文件位置是 `.claude/super-harness/config.yaml`，最该先看的两项是 `max_slots` 和 `no_deps_policy`；
- 用 `/super-harness:run --dry-run` 预览哪些 story 会并行；
- 用 `/super-harness:run` 开跑，`/super-harness:board` 看状态。

#!/bin/bash
# Git hooks installer
#
# 把 .claude/harness/git-hooks/ 下所有 hook 源 cp 到 git 当前 hooks dir 并 chmod +x。
# 幂等：
#   - 目标已存在且 byte-identical：跳过（"unchanged"）
#   - 目标是旧版 harness hook（头 5 行有 "Harness <name> hook" 标记，历代版本都有）：
#     backup 到 <name>.bak.<timestamp> 后覆盖
#   - 目标是项目自己的 hook（无标记，例如 pre-commit 框架写的）：不覆盖，打印串接
#     办法，最后 exit 3。备份后覆盖会让 git 只执行 harness hook，项目原有的密钥
#     扫描 / 格式检查静默失效（super-harness 0.2.1 修复）。
#     确认要覆盖时设 HARNESS_HOOK_FORCE=1 重跑（仍先备份）。
#   - 目标不存在：直接 install
#
# F14: hooks dir 走 `git rev-parse --git-path hooks`，正确支持 git worktree
#      （worktree 的 .git 是文件指针，普通 .git/hooks/ 不存在）。
# F8/E8: 检测 `core.hooksPath` 配置；若用户已自定义 hooks dir，warn 后退出
#      避免 silent no-op（hook 装到 .git/hooks/ 但永不触发）。
#
# 用法：
#   bash .claude/harness/scripts/install_git_hooks.sh
#   或：just install-git-hooks

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SOURCE_DIR="$REPO_ROOT/.claude/harness/git-hooks"

# F8/E8: core.hooksPath 探测
custom_hooks_path="$(git config --get core.hooksPath 2>/dev/null || true)"
if [ -n "$custom_hooks_path" ]; then
    cat >&2 <<EOF
ERROR: git config core.hooksPath = '$custom_hooks_path'
       本 installer 默认装到 git worktree 自身的 hooks dir；core.hooksPath 已
       redirect 到上面那条路径，silent install 不会生效。

处理路径：
  ① 临时清理：git config --unset core.hooksPath  然后重跑本脚本
  ② 手动安装：cp '$SOURCE_DIR'/* '$custom_hooks_path/'  + chmod +x
  ③ 让本 installer 装到 core.hooksPath 路径：还没实现，按需提 issue
EOF
    # exit 3 = 设计上的良性拒装（用户自定义 hooksPath），调用方按 WARN 处理；
    # exit 1 留给真实安装失败（source 目录缺失 / cp/chmod 失败），调用方 halt/引导自查。
    # 契约消费方：init.md §A.4.a / update.md §5+§7.3（review #58）。
    exit 3
fi

# F14: 用 git-path 而非 .git/hooks/，worktree 兼容
# review #18：`git rev-parse --git-path` 的相对输出是相对**CWD**而非 repo root；
# 此前从子目录运行会拼出仓库外路径（静默装错位置 / mkdir 失败）。用 `git -C
# "$REPO_ROOT"` 把解析基准锚定到 repo root，与下方拼接基准一致。
HOOKS_DIR="$(git -C "$REPO_ROOT" rev-parse --git-path hooks)"
# git-path 返回相对路径时（相对 REPO_ROOT，因上面 -C），拼绝对路径
case "$HOOKS_DIR" in
    /*) ;;  # 已是绝对路径
    *) HOOKS_DIR="$REPO_ROOT/$HOOKS_DIR" ;;
esac

if [ ! -d "$SOURCE_DIR" ]; then
    echo "ERROR: hook source directory not found: $SOURCE_DIR" >&2
    exit 1
fi

if [ ! -d "$HOOKS_DIR" ]; then
    mkdir -p "$HOOKS_DIR"
    echo "created hooks dir: $HOOKS_DIR"
fi

ts="$(date +%Y%m%d-%H%M%S)"
installed=0
unchanged=0
refused=0
FORCE="${HARNESS_HOOK_FORCE:-0}"

shopt -s nullglob
for src in "$SOURCE_DIR"/*; do
    [ -f "$src" ] || continue
    name="$(basename "$src")"
    # skip backup / editor temp files (update 投递可能在 source 里留 .bak.<ts>)
    case "$name" in
        *.bak.*|*.backup|*.orig|*~) continue ;;
    esac
    dst="$HOOKS_DIR/$name"

    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        echo "unchanged: $name"
        unchanged=$((unchanged + 1))
        continue
    fi

    if [ -f "$dst" ]; then
        # 不用 `head | grep -q`：pipefail 下 head 可能吃 SIGPIPE，被误判成「无标记」
        is_harness_hook=0
        case "$(head -n 5 "$dst")" in *"Harness $name hook"*) is_harness_hook=1 ;; esac
        if [ "$is_harness_hook" = 0 ] && [ "$FORCE" != "1" ]; then
            refused=$((refused + 1))
            cat >&2 <<HOOKMSG
REFUSED: $dst 是项目自己的 $name hook（不是 harness 装的），不覆盖。
         覆盖后 git 只会执行 harness 的 hook，原有检查会失效。
处理路径（任选其一）：
  ① 串接：在原 hook 里加一行，让它也跑 harness 的检查（失败即拒绝 commit）：
       bash "\$(git rev-parse --show-toplevel)/.claude/harness/git-hooks/$name" "\$@" || exit 1
     用 pre-commit 框架的项目，可以在 .pre-commit-config.yaml 里加一个 local hook 调同一个脚本。
  ② 确认原 hook 不再需要：HARNESS_HOOK_FORCE=1 bash .claude/harness/scripts/install_git_hooks.sh
     （原文件先备份为 $name.bak.<时间戳>）
HOOKMSG
            continue
        fi
        cp "$dst" "$dst.bak.$ts"
        echo "backed up: $name → $name.bak.$ts"
    fi

    cp "$src" "$dst"
    chmod +x "$dst"
    echo "installed: $name → $dst"
    installed=$((installed + 1))
done

echo
if [ "$refused" -gt 0 ]; then
    echo "Installed $installed hook(s); $unchanged unchanged; $refused refused (project-owned hook kept, see stderr)."
    # exit 3 = 良性拒装（与 core.hooksPath 同一语义），调用方按 WARN 处理
    exit 3
fi
if [ "$installed" -gt 0 ]; then
    echo "Installed $installed hook(s); $unchanged unchanged."
    echo "Verify: git commit --allow-empty -m 'test hook install'"
    echo "       (no-trigger commit; should pass silently)"
else
    echo "All $unchanged hook(s) already up to date."
fi

#!/bin/bash
# Git hooks installer
#
# 把 .claude/harness/git-hooks/ 下所有 hook 源 cp 到 git 当前 hooks dir 并 chmod +x。
# 幂等：
#   - 目标已存在且 byte-identical：跳过（"unchanged"）
#   - 目标已存在但内容不同：backup 到 <name>.bak.<timestamp> 后覆盖
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
    exit 1
fi

# F14: 用 git-path 而非 .git/hooks/，worktree 兼容
HOOKS_DIR="$(git rev-parse --git-path hooks)"
# git-path 返回相对路径时，cd 到 REPO_ROOT 让相对解析对齐
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

shopt -s nullglob
for src in "$SOURCE_DIR"/*; do
    [ -f "$src" ] || continue
    name="$(basename "$src")"
    dst="$HOOKS_DIR/$name"

    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        echo "unchanged: $name"
        unchanged=$((unchanged + 1))
        continue
    fi

    if [ -f "$dst" ]; then
        cp "$dst" "$dst.bak.$ts"
        echo "backed up: $name → $name.bak.$ts"
    fi

    cp "$src" "$dst"
    chmod +x "$dst"
    echo "installed: $name → $dst"
    installed=$((installed + 1))
done

echo
if [ "$installed" -gt 0 ]; then
    echo "Installed $installed hook(s); $unchanged unchanged."
    echo "Verify: git commit --allow-empty -m 'test hook install'"
    echo "       (no-trigger commit; should pass silently)"
else
    echo "All $unchanged hook(s) already up to date."
fi

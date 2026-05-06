#!/usr/bin/env bash
# Prev-epic retro action items grep
#
# bmad-create-story 启动时通过 customize.toml activation_steps_prepend 调用；
# 输出 markdown 段 `## 前置 retro action items 状态`，列上一 epic 的 retro
# action items（code / status / chore_spec / 简述），让 spec dev notes 段
# 自动含跨 epic 状态 snapshot。warn-only — 不阻断 spec 创建。
#
# 用法：
#   bash .claude/harness/scripts/grep_prev_retro_action_items.sh <current_epic_num>
#
# 例：
#   bash .claude/harness/scripts/grep_prev_retro_action_items.sh 4
#   → 扫 epic-1-retro + epic-2-retro + epic-3-retro 全部 action items
#
# 退出码：
#   0  正常输出（含 all-clear / no-prev / block-missing 边界）
#   2  sprint-status.yaml 路径不存在 / 参数非法
#
# 设计：纯 bash + grep + sed（POSIX 兼容；macOS BSD awk 不需 gawk match() 扩展）。

set -euo pipefail

SPRINT_STATUS="${SPRINT_STATUS:-_bmad-output/implementation-artifacts/sprint-status.yaml}"

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <current_epic_num>" >&2
    exit 2
fi

current_epic="$1"

if ! [[ "$current_epic" =~ ^[0-9]+$ ]]; then
    echo "ERROR: current_epic_num must be numeric, got: $current_epic" >&2
    exit 2
fi

prev_epic=$((current_epic - 1))

echo "## 前置 retro action items 状态"
echo ""

if [ "$prev_epic" -lt 1 ]; then
    echo "(no prev epic — Epic 1 第一个 story 不需要继承段)"
    exit 0
fi

if [ ! -f "$SPRINT_STATUS" ]; then
    echo "WARN: sprint-status.yaml not found at $SPRINT_STATUS" >&2
    echo "(sprint-status.yaml missing — skip prepend; warn-only)"
    exit 0
fi

if ! grep -qE "^retro_action_items:" "$SPRINT_STATUS"; then
    echo "WARN: retro_action_items block missing — run C1 seed first" >&2
    echo "(retro_action_items block missing — warn-only)"
    exit 0
fi

# 抽 retro_action_items 块（首行 `^retro_action_items:` 到下一顶层 key）
block="$(sed -n '/^retro_action_items:/,/^[a-zA-Z]/p' "$SPRINT_STATUS" | sed '$d')"

echo "| Epic | Code | Status | chore_spec | 简述 |"
echo "|------|------|--------|------------|------|"

current_epic_label=""
pending_code=""
pending_status=""
pending_comment=""

flush_row() {
    local spec="$1"
    if [ -n "$pending_code" ]; then
        local comment="${pending_comment:-—}"
        # markdown table cell escape: pipe / newline
        comment="${comment//|/\\|}"
        echo "| $current_epic_label | $pending_code | $pending_status | $spec | $comment |"
    fi
    pending_code=""
    pending_status=""
    pending_comment=""
}

while IFS= read -r line; do
    # epic header `  epic-N-retro:`
    if [[ "$line" =~ ^[[:space:]]+epic-([0-9]+)-retro:[[:space:]]*$ ]]; then
        flush_row "(no spec)"
        ep="${BASH_REMATCH[1]}"
        if [ "$ep" -le "$prev_epic" ]; then
            current_epic_label="epic-${ep}-retro"
        else
            current_epic_label=""
        fi
        continue
    fi

    [ -z "$current_epic_label" ] && continue

    # action item: `    A1: pending` or `    A1: done    # comment`
    if [[ "$line" =~ ^[[:space:]]+([A-Z][0-9a-z-]*):[[:space:]]+(pending|in-progress|partial|deferred|done)([[:space:]]*#[[:space:]]*(.*))?[[:space:]]*$ ]]; then
        flush_row "(no spec)"
        pending_code="${BASH_REMATCH[1]}"
        pending_status="${BASH_REMATCH[2]}"
        pending_comment="${BASH_REMATCH[4]:-}"
        continue
    fi

    # chore_spec sub-line: `      chore_spec: 'path'`
    if [[ "$line" =~ ^[[:space:]]+chore_spec:[[:space:]]+\'?([^\']+)\'?[[:space:]]*$ ]]; then
        spec="${BASH_REMATCH[1]}"
        spec="${spec%\'}"
        flush_row "$spec"
        continue
    fi
done <<< "$block"

# flush trailing row（最后一项无 chore_spec 跟随）
flush_row "(no spec — 需先立 chore spec)"

exit 0

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
#   0  正常输出（含 all-clear / no-prev / sprint-status-missing / block-missing
#      边界 — warn-only，文件缺失走 stderr WARN + exit 0，不阻 spec 创建）
#   2  参数非法
#
# 设计：纯 bash + grep + awk（POSIX 兼容；macOS BSD awk 不需 gawk match() 扩展）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# review 2026-06-10 #49：默认路径经 read_harness_config.sh 派生（artifacts_root
# 可配置 + 绝对路径，与兄弟脚本对齐），不再硬编码 CWD 相对路径。SPRINT_STATUS
# env override 保留（测试 fixture 用）。warn-only 脚本 — config 基础设施缺失
# （部分部署 skew）时退回旧默认值继续，不 abort。
if [ -f "$SCRIPT_DIR/read_harness_config.sh" ]; then
    # shellcheck source=read_harness_config.sh
    source "$SCRIPT_DIR/read_harness_config.sh"
fi
SPRINT_STATUS="${SPRINT_STATUS:-${HARNESS_SPRINT_STATUS_PATH:-_bmad-output/implementation-artifacts/sprint-status.yaml}}"

# 共享 retro_action_items 文法常量（review 2026-06-10 #16/#17 — code 正则与
# status 枚举的 SoT 在 deferred_work_schema_lib.sh；缺失时内联兜底，值必须
# 与 lib 保持一致）。
if [ -f "$SCRIPT_DIR/deferred_work_schema_lib.sh" ]; then
    # shellcheck source=deferred_work_schema_lib.sh
    source "$SCRIPT_DIR/deferred_work_schema_lib.sh"
fi
RAI_CODE_RE="${DWSL_RAI_CODE_RE:-[A-Z][A-Za-z0-9-]*}"
RAI_STATUS_ENUM_RE="${DWSL_RAI_STATUS_ENUM_RE:-(pending|in-progress|partial|deferred|done|migrated-upstream)}"

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

# 抽 retro_action_items 块（首行 `^retro_action_items:` 之后到下一顶层 key 之前）。
# review 2026-06-10 #13：旧实现 `sed -n '/start/,/end/p' | sed '$d'` 假设范围末行
# 必是下一顶层 key — 当块位于文件末尾（issue #6 bootstrap / C1 seed 的常态布局）
# 时范围延伸到 EOF，`$d` 误删最后一条真实 action item。改用 awk 状态机（与
# grep_pending_dev_retro_items.sh 同款），不依赖该假设。
block="$(awk '/^retro_action_items:/ { f = 1; next } f && /^[^[:space:]#]/ { exit } f { print }' "$SPRINT_STATUS")"

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
    # review 2026-06-10 #17：code 文法 / status 枚举改用共享常量 —— 旧正则
    # `[A-Z][0-9a-z-]*` 漏 mixed-case code（AA1 / A-1-Y2，F1+F2 统一文法），
    # 5 值枚举漏 migrated-upstream，两者都导致整行从继承表静默消失。
    rai_item_re="^[[:space:]]+(${RAI_CODE_RE}):[[:space:]]+${RAI_STATUS_ENUM_RE}([[:space:]]*#[[:space:]]*(.*))?[[:space:]]*\$"
    if [[ "$line" =~ $rai_item_re ]]; then
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

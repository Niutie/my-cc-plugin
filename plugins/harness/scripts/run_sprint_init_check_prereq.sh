#!/usr/bin/env bash
# /run-sprint-init §1 prerequisite gate — BMad planning artifacts MUST-EXIST 检查
#
# 由 .claude/commands/run-sprint-init.md §1 调用；test 入口由 run_sprint_init_test.sh 用。
#
# 输入：
#   --root <path>     项目根目录（默认 HARNESS_REPO_ROOT）；test 用 mktemp dir override
#
# 检查清单（spec MUST-EXIST 段）：
#   _bmad-output/planning-artifacts/product-brief.md
#   _bmad-output/planning-artifacts/prd.md
#   _bmad-output/planning-artifacts/architecture/tech-stack.md
#   _bmad-output/planning-artifacts/architecture/repo-structure.md
#   _bmad-output/implementation-artifacts/sprint-status.yaml
#
# 输出：
#   stdout：JSON 一行（{"all_present": bool, "missing_planning": [...], "missing_sprint_status": bool}）
#   stderr：halt 时按 missing 项印引导文本（硬编码 BMad skill 名 — Q4）
#
# 退出码：
#   0  — 全部 MUST-EXIST 在位
#   2  — 至少 1 个 BMad planning artifact 缺失（→ stderr 引导跑 /bmad-product-brief / /bmad:prd / /bmad:architecture）
#   3  — sprint-status.yaml 缺失（→ stderr 引导跑 /bmad:sprint-planning）
#   4  — 同时缺 planning + sprint-status；优先报 planning（exit 2）
#   1  — 参数错误 / 内部错误

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=read_harness_config.sh
source "$SCRIPT_DIR/read_harness_config.sh" 2>/dev/null

ROOT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)
            ROOT="${2:-}"
            shift 2
            ;;
        -h|--help)
            sed -nE 's/^# ?//p' "$0" | head -30
            exit 0
            ;;
        *)
            echo "ERROR: unknown arg: $1" >&2
            echo "Usage: $0 [--root <path>]" >&2
            exit 1
            ;;
    esac
done

if [ -z "$ROOT" ]; then
    ROOT="${HARNESS_REPO_ROOT:-$(pwd)}"
fi

if [ ! -d "$ROOT" ]; then
    echo "ERROR: --root path not a directory: $ROOT" >&2
    exit 1
fi

# 4 BMad planning MUST-EXIST + 引导 skill 名（Q4 硬编码）
declare -a PLANNING_CHECKS=(
    "_bmad-output/planning-artifacts/product-brief.md|/bmad-product-brief"
    "_bmad-output/planning-artifacts/prd.md|/bmad:prd"
    "_bmad-output/planning-artifacts/architecture/tech-stack.md|/bmad:architecture"
    "_bmad-output/planning-artifacts/architecture/repo-structure.md|/bmad:architecture"
)
SPRINT_STATUS_REL="_bmad-output/implementation-artifacts/sprint-status.yaml"

declare -a MISSING_PLANNING=()
declare -a MISSING_GUIDANCE=()
for entry in "${PLANNING_CHECKS[@]}"; do
    rel="${entry%%|*}"
    skill="${entry##*|}"
    if [ ! -f "$ROOT/$rel" ]; then
        MISSING_PLANNING+=("$rel")
        MISSING_GUIDANCE+=("$skill")
    fi
done

MISSING_SPRINT_STATUS="false"
if [ ! -f "$ROOT/$SPRINT_STATUS_REL" ]; then
    MISSING_SPRINT_STATUS="true"
fi

# JSON stdout (一行 — 与 check_test_harness_env.sh 风格一致)
json_array() {
    local out="["
    local first=1
    for item in "$@"; do
        if [ "$first" -eq 1 ]; then
            first=0
        else
            out="$out, "
        fi
        out="$out\"$item\""
    done
    out="$out]"
    printf '%s' "$out"
}

ALL_PRESENT="true"
if [ "${#MISSING_PLANNING[@]}" -gt 0 ] || [ "$MISSING_SPRINT_STATUS" = "true" ]; then
    ALL_PRESENT="false"
fi

printf '{"all_present": %s, "missing_planning": %s, "missing_sprint_status": %s}\n' \
    "$ALL_PRESENT" \
    "$(json_array "${MISSING_PLANNING[@]+"${MISSING_PLANNING[@]}"}")" \
    "$MISSING_SPRINT_STATUS"

# stderr 引导 + exit code
if [ "${#MISSING_PLANNING[@]}" -gt 0 ]; then
    echo "" >&2
    echo "❌ BMad planning artifacts MUST-EXIST 缺失 ${#MISSING_PLANNING[@]} 项 — /run-sprint-init halt" >&2
    for i in "${!MISSING_PLANNING[@]}"; do
        echo "  - $ROOT/${MISSING_PLANNING[$i]}" >&2
        echo "    请先跑 ${MISSING_GUIDANCE[$i]} 生成该产物" >&2
    done
    if [ "$MISSING_SPRINT_STATUS" = "true" ]; then
        echo "  - $ROOT/$SPRINT_STATUS_REL" >&2
        echo "    请先跑 /bmad:sprint-planning 生成 sprint backlog" >&2
    fi
    exit 2
fi

if [ "$MISSING_SPRINT_STATUS" = "true" ]; then
    echo "" >&2
    echo "❌ sprint-status.yaml 缺失 — /run-sprint-init halt" >&2
    echo "  - $ROOT/$SPRINT_STATUS_REL" >&2
    echo "    请先跑 /bmad:sprint-planning 生成 sprint backlog" >&2
    exit 3
fi

exit 0

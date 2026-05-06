#!/usr/bin/env bash
# /harness-zh:init §1 prerequisite gate — BMad planning artifacts MUST-EXIST 检查
#
# 由 .claude/commands/init.md §1 调用；test 入口由 run_sprint_init_test.sh 用。
#
# 输入：
#   --root <path>     项目根目录（默认 HARNESS_REPO_ROOT）；test 用 mktemp dir override
#
# 检查清单（4 类概念产物 — 单文件或 sharded 任一形式接受；与 /harness-zh:init §A.5 一致）：
#   1) product-brief: glob 匹配 _bmad-output/planning-artifacts/product-brief*.md
#      （BMad 上游会带项目名后缀，如 product-brief-aegis.md）
#   2) prd: 单文件 _bmad-output/planning-artifacts/prd.md
#         或 sharded 目录 _bmad-output/planning-artifacts/prd/
#   3) architecture: 单文件 _bmad-output/planning-artifacts/architecture.md
#         或 sharded 目录 _bmad-output/planning-artifacts/architecture/
#   4) sprint-status: _bmad-output/implementation-artifacts/sprint-status.yaml（路径固定）
#
# 输出：
#   stdout：JSON 一行（{"all_present": bool, "missing_planning": [...], "missing_sprint_status": bool}）
#   stderr：halt 时按 missing 项印引导文本（带 BMad slash 命令名 — 全冒号形式）
#
# 退出码：
#   0  — 全部 MUST-EXIST 在位
#   2  — 至少 1 个 BMad planning artifact 缺失（→ stderr 引导跑 /bmad-product-brief / /bmad-create-prd / /bmad-create-architecture）
#   3  — sprint-status.yaml 缺失（→ stderr 引导跑 /bmad-sprint-planning）
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
            sed -nE 's/^# ?//p' "$0" | head -40
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

# 4 个概念产物 + 引导命令（hyphen 形式 — 与 .claude/skills/bmad-* 直接对应；
# colon 别名 /bmad:<name> 通常也可，部分命令带 "create-" 前缀差异；详见 stderr 注脚）
declare -a MISSING_PLANNING=()
declare -a MISSING_GUIDANCE=()

# 1) product-brief: glob 匹配（BMad 上游 product-brief-{project}.md）
if ! ls "$ROOT/_bmad-output/planning-artifacts/product-brief"*.md >/dev/null 2>&1; then
    MISSING_PLANNING+=("_bmad-output/planning-artifacts/product-brief*.md")
    MISSING_GUIDANCE+=("/bmad-product-brief")
fi

# 2) prd: 单文件 OR sharded 目录
if [ ! -f "$ROOT/_bmad-output/planning-artifacts/prd.md" ] && [ ! -d "$ROOT/_bmad-output/planning-artifacts/prd" ]; then
    MISSING_PLANNING+=("_bmad-output/planning-artifacts/prd.md (或 prd/ sharded 目录)")
    MISSING_GUIDANCE+=("/bmad-create-prd")
fi

# 3) architecture: 单文件 OR sharded 目录
if [ ! -f "$ROOT/_bmad-output/planning-artifacts/architecture.md" ] && [ ! -d "$ROOT/_bmad-output/planning-artifacts/architecture" ]; then
    MISSING_PLANNING+=("_bmad-output/planning-artifacts/architecture.md (或 architecture/ sharded 目录)")
    MISSING_GUIDANCE+=("/bmad-create-architecture")
fi

# 4) sprint-status.yaml: 路径固定
SPRINT_STATUS_REL="_bmad-output/implementation-artifacts/sprint-status.yaml"
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
        local esc="${item//\\/\\\\}"
        esc="${esc//\"/\\\"}"
        out="$out\"$esc\""
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
    echo "❌ BMad planning artifacts MUST-EXIST 缺失 ${#MISSING_PLANNING[@]} 项 — /harness-zh:init halt" >&2
    for i in "${!MISSING_PLANNING[@]}"; do
        echo "  - $ROOT/${MISSING_PLANNING[$i]}" >&2
        echo "    请先跑 ${MISSING_GUIDANCE[$i]} 生成该产物" >&2
    done
    if [ "$MISSING_SPRINT_STATUS" = "true" ]; then
        echo "  - $ROOT/$SPRINT_STATUS_REL" >&2
        echo "    请先跑 /bmad-sprint-planning 生成 sprint backlog" >&2
    fi
    echo "" >&2
    echo "💡 首次使用 BMad（项目根没 _bmad/ 目录）先：" >&2
    echo "    npx bmad-method install --modules bmm,bmb,tea,cis --tools claude-code" >&2
    echo "    /bmad:workflow-init     # 注：workflow-init 只有冒号形式" >&2
    echo "" >&2
    echo "📝 BMad 命令名说明：上述 /bmad-<name> 形式直接对应 .claude/skills/bmad-<name>/；" >&2
    echo "   colon 别名 /bmad:<name> 通常也可（少数较新命令如 workflow-init 仅 colon 形式）。" >&2
    exit 2
fi

if [ "$MISSING_SPRINT_STATUS" = "true" ]; then
    echo "" >&2
    echo "❌ sprint-status.yaml 缺失 — /harness-zh:init halt" >&2
    echo "  - $ROOT/$SPRINT_STATUS_REL" >&2
    echo "    请先跑 /bmad-sprint-planning 生成 sprint backlog" >&2
    exit 3
fi

exit 0

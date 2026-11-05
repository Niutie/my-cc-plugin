#!/usr/bin/env bash
# /super-harness:init §1 prerequisite gate — BMad planning artifacts MUST-EXIST 检查
#
# 由 /super-harness:init §A.5 / §1 调用；test 入口由 run_sprint_init_test.sh 用。
#
# 输入：
#   --root <path>     项目根目录（默认 HARNESS_REPO_ROOT）；test 用 mktemp dir override
#
# 产物目录解析（0.3.1+；之前写死 _bmad-output/...）：
#   planning 目录      ← _bmad/bmm/config.yaml `planning_artifacts`
#                        → 默认 _bmad-output/planning-artifacts
#   implementation 目录 ← _bmad/bmm/config.yaml `implementation_artifacts`
#                        → .claude/harness/harness-project-config.yaml `artifacts_root`
#                        → 默认 _bmad-output/implementation-artifacts
#   BMad 配置里的 `{project-root}` 换成项目根，`{output_folder}` 换成同文件（或
#   _bmad/core/config.yaml）的 output_folder。
#
# 检查清单（3 必需 + 1 可选；单文件或 sharded 任一形式接受；与 /super-harness:init §A.5 一致）：
#   1) prd（必需）: <planning>/prd.md 或 sharded 目录 <planning>/prd/
#   2) architecture（必需）: <planning>/architecture.md 或 <planning>/architecture/
#   3) sprint-status（必需）: <implementation>/sprint-status.yaml
#   4) product-brief（**可选**）: glob <planning>/product-brief*.md
#         （BMad 上游会带项目名后缀；缺则只 WARN 不 fail，project_display_name 从 prd.md 兜底）
#
# 输出：
#   stdout：JSON 一行
#     {"all_present": bool, "missing_planning": [...], "missing_sprint_status": bool,
#      "optional_missing": [...], "planning_dir": "<rel>", "implementation_dir": "<rel>",
#      "planning_source": "bmad-config|default",
#      "implementation_source": "bmad-config|harness-yaml|default"}
#     （*_dir 相对项目根；在项目根之外时为绝对路径）
#   stderr：halt 时按 missing 项印引导文本（BMad 6.11+ skill 名，/bmad-<name> 形式）
#
# 退出码：
#   0  — 全部 MUST-EXIST 在位
#   2  — 至少 1 个 BMad planning artifact 缺失（→ stderr 引导跑 /bmad-prd / /bmad-architecture）
#   3  — sprint-status.yaml 缺失（→ stderr 引导跑 /bmad-sprint-planning）
#   4  — 同时缺 planning + sprint-status；优先报 planning（exit 2）
#   1  — 参数错误 / 内部错误

set -uo pipefail

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
            sed -nE 's/^# ?//p' "$0" | head -45
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
ROOT="$(cd "$ROOT" && pwd)"

# ---------------------------------------------------------------------------
# 产物目录解析
# ---------------------------------------------------------------------------
DEFAULT_PLANNING_REL="_bmad-output/planning-artifacts"
DEFAULT_IMPL_REL="_bmad-output/implementation-artifacts"

# _yaml_scalar <file> <key> — top-level `key: value`，去引号 / 行尾注释；无则空串
_yaml_scalar() {
    [ -f "$1" ] || return 0
    local v
    v="$(grep -E "^$2:[[:space:]]" "$1" 2>/dev/null | head -1 | sed -E "s/^$2:[[:space:]]*//")"
    case "$v" in
        \"*) v="${v#\"}"; v="${v%%\"*}" ;;
        \'*) v="${v#\'}"; v="${v%%\'*}" ;;
        *)   v="${v%%#*}" ;;
    esac
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

# _to_abs <path> — 相对路径按项目根解析；去掉结尾 /
_to_abs() {
    local p="$1"
    case "$p" in
        /*) ;;
        ./*) p="$ROOT/${p#./}" ;;
        *) p="$ROOT/$p" ;;
    esac
    while [ "${p%/}" != "$p" ] && [ "$p" != "/" ]; do p="${p%/}"; done
    printf '%s' "$p"
}

# _bmad_path <key> — 读 _bmad/bmm/config.yaml 的路径型 key，解析占位符，输出绝对路径
_bmad_path() {
    local cfg="$ROOT/_bmad/bmm/config.yaml" v of
    v="$(_yaml_scalar "$cfg" "$1")"
    [ -n "$v" ] || return 0
    case "$v" in
        *"{output_folder}"*)
            of="$(_yaml_scalar "$cfg" output_folder)"
            [ -n "$of" ] || of="$(_yaml_scalar "$ROOT/_bmad/core/config.yaml" output_folder)"
            [ -n "$of" ] || return 0
            v="${v//\{output_folder\}/${of}}"
            ;;
    esac
    v="${v//\{project-root\}/${ROOT}}"
    case "$v" in *"{"*"}"*) return 0 ;; esac   # 不认识的占位符 → 当作未配置
    _to_abs "$v"
}

# _rel <abs> — 显示 / JSON 用：项目根内转相对路径
_rel() {
    case "$1" in
        "$ROOT") printf '.' ;;
        "$ROOT"/*) printf '%s' "${1#"$ROOT"/}" ;;
        *) printf '%s' "$1" ;;
    esac
}

PLANNING_DIR="$(_bmad_path planning_artifacts)"
PLANNING_SOURCE="bmad-config"
if [ -z "$PLANNING_DIR" ]; then
    PLANNING_DIR="$ROOT/$DEFAULT_PLANNING_REL"
    PLANNING_SOURCE="default"
fi

IMPL_DIR="$(_bmad_path implementation_artifacts)"
IMPL_SOURCE="bmad-config"
if [ -z "$IMPL_DIR" ]; then
    _ar="$(_yaml_scalar "$ROOT/.claude/harness/harness-project-config.yaml" artifacts_root)"
    if [ -n "$_ar" ]; then
        IMPL_DIR="$(_to_abs "$_ar")"
        IMPL_SOURCE="harness-yaml"
    else
        IMPL_DIR="$ROOT/$DEFAULT_IMPL_REL"
        IMPL_SOURCE="default"
    fi
fi

PLANNING_REL="$(_rel "$PLANNING_DIR")"
IMPL_REL="$(_rel "$IMPL_DIR")"

# 3 必需产物（缺即 fail）+ 1 可选产物（缺仅 WARN）
# 命令名 = BMad 6.11+ 装进 .claude/skills/bmad-<name>/ 的 skill 名
# （6.12.4 实测：bmad-prd / bmad-architecture / bmad-create-epics-and-stories /
#  bmad-sprint-planning / bmad-product-brief）
declare -a MISSING_PLANNING=()
declare -a MISSING_GUIDANCE=()
declare -a OPTIONAL_MISSING=()
declare -a OPTIONAL_GUIDANCE=()

# 1) prd: 单文件 OR sharded 目录（必需）
if [ ! -f "$PLANNING_DIR/prd.md" ] && [ ! -d "$PLANNING_DIR/prd" ]; then
    MISSING_PLANNING+=("${PLANNING_REL}/prd.md (或 prd/ sharded 目录)")
    MISSING_GUIDANCE+=("/bmad-prd")
fi

# 2) architecture: 单文件 OR sharded 目录（必需）
if [ ! -f "$PLANNING_DIR/architecture.md" ] && [ ! -d "$PLANNING_DIR/architecture" ]; then
    MISSING_PLANNING+=("${PLANNING_REL}/architecture.md (或 architecture/ sharded 目录)")
    MISSING_GUIDANCE+=("/bmad-architecture")
fi

# 4) product-brief: glob 匹配（**可选** — 不进 MISSING_PLANNING，只进 OPTIONAL_MISSING）
if ! ls "$PLANNING_DIR/product-brief"*.md >/dev/null 2>&1; then
    OPTIONAL_MISSING+=("${PLANNING_REL}/product-brief*.md (可选 — 缺则字段 1/15 从 prd.md 兜底)")
    OPTIONAL_GUIDANCE+=("/bmad-product-brief")
fi

# 3) sprint-status.yaml
SPRINT_STATUS_REL="${IMPL_REL}/sprint-status.yaml"
MISSING_SPRINT_STATUS="false"
if [ ! -f "$IMPL_DIR/sprint-status.yaml" ]; then
    MISSING_SPRINT_STATUS="true"
fi

# JSON stdout (一行)
json_str() {
    local esc="${1//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    printf '"%s"' "$esc"
}
json_array() {
    local out="["
    local first=1
    for item in "$@"; do
        if [ "$first" -eq 1 ]; then
            first=0
        else
            out="$out, "
        fi
        out="$out$(json_str "$item")"
    done
    out="$out]"
    printf '%s' "$out"
}

ALL_PRESENT="true"
if [ "${#MISSING_PLANNING[@]}" -gt 0 ] || [ "$MISSING_SPRINT_STATUS" = "true" ]; then
    ALL_PRESENT="false"
fi

printf '{"all_present": %s, "missing_planning": %s, "missing_sprint_status": %s, "optional_missing": %s, "planning_dir": %s, "implementation_dir": %s, "planning_source": "%s", "implementation_source": "%s"}\n' \
    "$ALL_PRESENT" \
    "$(json_array "${MISSING_PLANNING[@]+"${MISSING_PLANNING[@]}"}")" \
    "$MISSING_SPRINT_STATUS" \
    "$(json_array "${OPTIONAL_MISSING[@]+"${OPTIONAL_MISSING[@]}"}")" \
    "$(json_str "$PLANNING_REL")" \
    "$(json_str "$IMPL_REL")" \
    "$PLANNING_SOURCE" \
    "$IMPL_SOURCE"

_abs_disp() {  # 引导文本里显示的路径：相对 → 拼项目根
    case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$ROOT" "$1" ;; esac
}

# stderr 引导 + exit code
if [ "${#MISSING_PLANNING[@]}" -gt 0 ]; then
    echo "" >&2
    echo "❌ BMad **必需** planning artifacts 缺失 ${#MISSING_PLANNING[@]} 项 — /super-harness:init halt" >&2
    for i in "${!MISSING_PLANNING[@]}"; do
        echo "  - $(_abs_disp "${MISSING_PLANNING[$i]}")" >&2
        echo "    请先跑 ${MISSING_GUIDANCE[$i]} 生成该产物" >&2
    done
    if [ "$MISSING_SPRINT_STATUS" = "true" ]; then
        echo "  - $(_abs_disp "$SPRINT_STATUS_REL")" >&2
        echo "    请先跑 /bmad-create-epics-and-stories，再跑 /bmad-sprint-planning 生成 sprint backlog" >&2
    fi
    if [ "${#OPTIONAL_MISSING[@]}" -gt 0 ]; then
        echo "" >&2
        echo "💭 可选缺失（不阻流，仅信息）：" >&2
        for i in "${!OPTIONAL_MISSING[@]}"; do
            echo "  - $(_abs_disp "${OPTIONAL_MISSING[$i]}")" >&2
        done
    fi
    echo "" >&2
    echo "💡 首次使用 BMad（项目根没 _bmad/ 目录）先装：" >&2
    echo "    npx bmad-method install                         # 交互式（推荐，全选 5 模块）" >&2
    echo "    或 npx bmad-method install --modules core,bmm,bmb,cis,tea --tools claude-code --yes" >&2
    echo "    （installer 自动建 _bmad/ 配置 + 写 .claude/skills/bmad-*/，无需额外 init）" >&2
    echo "" >&2
    echo "📝 BMad 命令名说明：/bmad-<name> 对应 .claude/skills/bmad-<name>/（BMad 6.11+）。" >&2
    echo "   6.10 及更早的安装用旧名 /bmad-create-prd、/bmad-create-architecture；" >&2
    echo "   super-harness 的流水线要求 BMad ≥ 6.11，建议先升级 BMad。" >&2
    exit 2
fi

if [ "$MISSING_SPRINT_STATUS" = "true" ]; then
    echo "" >&2
    echo "❌ sprint-status.yaml 缺失 — /super-harness:init halt" >&2
    echo "  - $(_abs_disp "$SPRINT_STATUS_REL")" >&2
    echo "    请先跑 /bmad-create-epics-and-stories，再跑 /bmad-sprint-planning 生成 sprint backlog" >&2
    exit 3
fi

exit 0

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
# 检查清单（3 必需 + 1 可选；与 /super-harness:init §A.5 一致）。每项按顺序认三种布局，
# 先命中的算数：single（单文件）→ run-folder（BMad 6.12+ 运行目录）→ sharded（目录）
#   1) prd（必需）: <planning>/prd.md → <prd_output_path>/<运行目录>/prd.md
#         （默认 prds/prd-<project>-<date>/prd.md）→ sharded 目录 <planning>/prd/
#   2) architecture（必需）: <planning>/architecture.md
#         → <spine_output_path>/<运行目录>/ARCHITECTURE-SPINE.md
#         （默认 architecture/architecture-<project>-<date>/）→ sharded 目录 <planning>/architecture/
#         sharded 目录下要直接有 .md 文件；只有运行目录的 architecture/ 不算 sharded。
#   3) sprint-status（必需）: <implementation>/sprint-status.yaml
#   4) product-brief（**可选**）: glob <planning>/product-brief*.md
#         → <brief_output_path>/<运行目录>/brief.md（默认 briefs/brief-<project>-<date>/）
#         缺则只 WARN 不 fail，project_display_name 从 PRD 兜底
#   运行目录的 output_path / run_folder_pattern 读 _bmad/custom/<skill>.user.toml、
#   _bmad/custom/<skill>.toml、.claude/skills/<skill>/customize.toml（前者优先）。
#   有多个运行目录时 frontmatter `status: final` 的优先，再按目录名里的日期取最新的。
#
# 输出：
#   stdout：JSON 一行
#     {"all_present": bool, "missing_planning": [...], "missing_sprint_status": bool,
#      "optional_missing": [...], "planning_dir": "<rel>", "implementation_dir": "<rel>",
#      "planning_source": "bmad-config|default",
#      "implementation_source": "bmad-config|harness-yaml|default",
#      "prd_path": "<rel>", "prd_form": "single|run-folder|sharded",
#      "architecture_path": "<rel>", "architecture_form": "...",
#      "product_brief_path": "<rel>", "product_brief_form": "..."}
#     （*_dir / *_path 相对项目根；在项目根之外时为绝对路径；没找到时 path、form 为空串。
#      sharded 时 path 是目录）
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
            sed -nE 's/^# ?//p' "$0" | head -60
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

# ---------------------------------------------------------------------------
# BMad 6.12+ 运行目录布局
# ---------------------------------------------------------------------------
# bmad-prd / bmad-architecture / bmad-product-brief 把产物写进
# `<output_path>/<run_folder_pattern>/<文件>`，例如 prds/prd-myproj-2026-11-07/prd.md。
# output_path 和 run_folder_pattern 按 BMad 的覆盖顺序读：
#   _bmad/custom/<skill>.user.toml > _bmad/custom/<skill>.toml
#   > .claude/skills/<skill>/customize.toml > 内置默认值
# 有多个运行目录时：frontmatter `status: final` 的优先，再按目录名里的日期取最新的。

# _toml_scalar <file> <key> — `key = "value"` 一行；无则空串
_toml_scalar() {
    [ -f "$1" ] || return 0
    local v
    v="$(grep -E "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null | head -1 | sed -E "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//")"
    case "$v" in
        \"*) v="${v#\"}"; v="${v%%\"*}" ;;
        \'*) v="${v#\'}"; v="${v%%\'*}" ;;
        *)   v="${v%%#*}" ;;
    esac
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

# _skill_setting <skill> <key> <default> — 按覆盖顺序取第一个非空值
_skill_setting() {
    local f v
    for f in "$ROOT/_bmad/custom/$1.user.toml" "$ROOT/_bmad/custom/$1.toml" \
             "$ROOT/.claude/skills/$1/customize.toml"; do
        v="$(_toml_scalar "$f" "$2")"
        if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
    done
    printf '%s' "$3"
}

# _frontmatter_final <file> — frontmatter 里 status 是 final 时返回 0
_frontmatter_final() {
    awk 'NR==1 && $0!="---" {exit 1}
         NR>1 && $0=="---" {exit 1}
         NR>1 && /^status:[[:space:]]*["\x27]?final["\x27]?[[:space:]]*$/ {found=1; exit 0}
         END {exit found ? 0 : 1}' "$1" 2>/dev/null
}

# _find_run_artifact <skill> <path_key> <default_path> <default_pattern> <文件名>
#   输出选中的文件绝对路径；找不到输出空串
_find_run_artifact() {
    local out pat of glob f d date rank best="" best_key="" key
    out="$(_skill_setting "$1" "$2" "$3")"
    pat="$(_skill_setting "$1" run_folder_pattern "$4")"
    out="${out//\{planning_artifacts\}/${PLANNING_DIR}}"
    out="${out//\{project-root\}/${ROOT}}"
    case "$out" in
        *"{output_folder}"*)
            of="$(_bmad_path output_folder)"
            [ -n "$of" ] || return 0
            out="${out//\{output_folder\}/${of}}"
            ;;
    esac
    case "$out" in *"{"*"}"*) out="${3//\{planning_artifacts\}/${PLANNING_DIR}}" ;; esac
    out="$(_to_abs "$out")"
    [ -d "$out" ] || return 0
    # 运行目录名模式 → glob：每个 {占位符} 换成 *
    glob="$(printf '%s' "$pat" | sed -E 's/\{[^}]*\}/*/g')"
    case "$glob" in ""|*/*) glob="*" ;; esac
    for f in "$out"/$glob/"$5"; do
        [ -f "$f" ] || continue
        d="$(basename "$(dirname "$f")")"
        date="$(printf '%s' "$d" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | tail -1)"
        rank=0
        _frontmatter_final "$f" && rank=1
        key="$rank ${date:-0000-00-00} $d"
        if [ -z "$best" ] || [[ "$key" > "$best_key" ]]; then
            best="$f"; best_key="$key"
        fi
    done
    printf '%s' "$best"
}

# _has_md_files <dir> — 目录下直接有 .md 文件（sharded 布局）时返回 0。
# 只有运行目录的 architecture/ 不算 sharded。
_has_md_files() {
    local f
    for f in "$1"/*.md; do [ -f "$f" ] && return 0; done
    return 1
}

# 3 必需产物（缺即 fail）+ 1 可选产物（缺仅 WARN）
# 命令名 = BMad 6.11+ 装进 .claude/skills/bmad-<name>/ 的 skill 名
# （6.12.4 实测：bmad-prd / bmad-architecture / bmad-create-epics-and-stories /
#  bmad-sprint-planning / bmad-product-brief）
declare -a MISSING_PLANNING=()
declare -a MISSING_GUIDANCE=()
declare -a OPTIONAL_MISSING=()
declare -a OPTIONAL_GUIDANCE=()

# 每项产物命中的路径和布局：single（单文件）/ run-folder（6.12+ 运行目录）/ sharded（目录）
PRD_PATH=""; PRD_FORM=""
ARCH_PATH=""; ARCH_FORM=""
BRIEF_PATH=""; BRIEF_FORM=""

# 1) prd（必需）：prd.md → prds/<运行目录>/prd.md → sharded prd/
if [ -f "$PLANNING_DIR/prd.md" ]; then
    PRD_PATH="$PLANNING_DIR/prd.md"; PRD_FORM="single"
else
    _p="$(_find_run_artifact bmad-prd prd_output_path '{planning_artifacts}/prds' 'prd-{project_name}-{date}' prd.md)"
    if [ -n "$_p" ]; then
        PRD_PATH="$_p"; PRD_FORM="run-folder"
    elif [ -d "$PLANNING_DIR/prd" ] && _has_md_files "$PLANNING_DIR/prd"; then
        PRD_PATH="$PLANNING_DIR/prd"; PRD_FORM="sharded"
    fi
fi
if [ -z "$PRD_PATH" ]; then
    MISSING_PLANNING+=("${PLANNING_REL}/prd.md (或 prds/<运行目录>/prd.md、prd/ sharded 目录)")
    MISSING_GUIDANCE+=("/bmad-prd")
fi

# 2) architecture（必需）：architecture.md → architecture/<运行目录>/ARCHITECTURE-SPINE.md
#    → sharded architecture/（目录下直接有 .md 才算）
if [ -f "$PLANNING_DIR/architecture.md" ]; then
    ARCH_PATH="$PLANNING_DIR/architecture.md"; ARCH_FORM="single"
else
    _p="$(_find_run_artifact bmad-architecture spine_output_path '{planning_artifacts}/architecture' 'architecture-{project_name}-{date}' ARCHITECTURE-SPINE.md)"
    if [ -n "$_p" ]; then
        ARCH_PATH="$_p"; ARCH_FORM="run-folder"
    elif [ -d "$PLANNING_DIR/architecture" ] && _has_md_files "$PLANNING_DIR/architecture"; then
        ARCH_PATH="$PLANNING_DIR/architecture"; ARCH_FORM="sharded"
    fi
fi
if [ -z "$ARCH_PATH" ]; then
    MISSING_PLANNING+=("${PLANNING_REL}/architecture.md (或 architecture/<运行目录>/ARCHITECTURE-SPINE.md、architecture/ sharded 目录)")
    MISSING_GUIDANCE+=("/bmad-architecture")
fi

# 4) product-brief（**可选** — 不进 MISSING_PLANNING，只进 OPTIONAL_MISSING）：
#    glob product-brief*.md → briefs/<运行目录>/brief.md
for _f in "$PLANNING_DIR/product-brief"*.md; do
    if [ -f "$_f" ]; then BRIEF_PATH="$_f"; BRIEF_FORM="single"; break; fi
done
if [ -z "$BRIEF_PATH" ]; then
    _p="$(_find_run_artifact bmad-product-brief brief_output_path '{planning_artifacts}/briefs' 'brief-{project_name}-{date}' brief.md)"
    if [ -n "$_p" ]; then BRIEF_PATH="$_p"; BRIEF_FORM="run-folder"; fi
fi
if [ -z "$BRIEF_PATH" ]; then
    OPTIONAL_MISSING+=("${PLANNING_REL}/product-brief*.md 或 briefs/<运行目录>/brief.md (可选 — 缺则字段 1/15 从 PRD 兜底)")
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

_rel_or_empty() { [ -z "$1" ] || _rel "$1"; }

printf '{"all_present": %s, "missing_planning": %s, "missing_sprint_status": %s, "optional_missing": %s, "planning_dir": %s, "implementation_dir": %s, "planning_source": "%s", "implementation_source": "%s", "prd_path": %s, "prd_form": "%s", "architecture_path": %s, "architecture_form": "%s", "product_brief_path": %s, "product_brief_form": "%s"}\n' \
    "$ALL_PRESENT" \
    "$(json_array "${MISSING_PLANNING[@]+"${MISSING_PLANNING[@]}"}")" \
    "$MISSING_SPRINT_STATUS" \
    "$(json_array "${OPTIONAL_MISSING[@]+"${OPTIONAL_MISSING[@]}"}")" \
    "$(json_str "$PLANNING_REL")" \
    "$(json_str "$IMPL_REL")" \
    "$PLANNING_SOURCE" \
    "$IMPL_SOURCE" \
    "$(json_str "$(_rel_or_empty "$PRD_PATH")")" "$PRD_FORM" \
    "$(json_str "$(_rel_or_empty "$ARCH_PATH")")" "$ARCH_FORM" \
    "$(json_str "$(_rel_or_empty "$BRIEF_PATH")")" "$BRIEF_FORM"

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

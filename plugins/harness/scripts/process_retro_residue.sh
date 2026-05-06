#!/usr/bin/env bash
# Chore C10 — Retro Residue Processor 主入口
#
# 编排 fresh agent 把 retro_action_items 块中"未 done 且未生成 chore spec"的项
# 转为可执行的 chore-retro-c${EPIC}-<code>-<slug>.md 前置 spec。
#
# 架构与 C12 backfill_resolved_markers.sh 一致：shell 只做 IO 编排（不调 LLM），
# 输出 stdout = fresh agent prompt 全文 + 当前 epic retro markdown 全文 + retro_action_items
# 当前块 yaml + 待 process 列表 + 已有 chore_spec 黑名单。主 agent 拷给 fresh agent，
# 收 `=== FILE: ... ===` 块逐个 Write，再 diff merge sprint-status.yaml 给被 process 的项加
# chore_spec 字段。
#
# 用法：
#   bash .claude/harness/scripts/process_retro_residue.sh --epic 1
#   bash .claude/harness/scripts/process_retro_residue.sh --epic 2
#   bash .claude/harness/scripts/process_retro_residue.sh --epic 3
#
# 退出码：
#   0   = 输出 prompt + 待 process 列表（≥ 1 项）；主 agent 接管
#   2   = 无残余（全 done / 全 deferred / 全已有 chore_spec）；幂等成功；不 commit
#   1+  = 错误（参数 / 文件缺失 / yaml 异常）
#
# 测试入口（fixture 模式 — 测试脚本调用）：
#   --sprint-status <path>   覆盖 sprint-status.yaml 路径（默认仓库内）
#   --retro-md <path>        覆盖 retro markdown 路径（默认按 EPIC 自动定位最近一份）
#   --artifact-dir <path>    覆盖 chore-retro-* 现存文件搜索目录（默认仓库内）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=read_harness_config.sh
source "$SCRIPT_DIR/read_harness_config.sh"
ROOT="$HARNESS_REPO_ROOT"
DEFAULT_SPRINT_STATUS="$HARNESS_SPRINT_STATUS_PATH"
DEFAULT_ARTIFACT_DIR="$HARNESS_ARTIFACTS_ROOT"
PROMPT_TEMPLATE="${SCRIPT_DIR}/process_retro_residue_prompt.md"

EPIC=""
SPRINT_STATUS=""
RETRO_MD=""
ARTIFACT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --epic)
            EPIC="${2:-}"
            shift 2
            ;;
        --sprint-status)
            SPRINT_STATUS="${2:-}"
            shift 2
            ;;
        --retro-md)
            RETRO_MD="${2:-}"
            shift 2
            ;;
        --artifact-dir)
            ARTIFACT_DIR="${2:-}"
            shift 2
            ;;
        *)
            echo "ERROR: unknown arg: $1" >&2
            echo "Usage: $0 --epic <1|2|3> [--sprint-status <path>] [--retro-md <path>] [--artifact-dir <path>]" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$EPIC" ]]; then
    echo "ERROR: --epic <1|2|3> required" >&2
    exit 1
fi

if [[ ! "$EPIC" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: --epic must be a positive integer (got: $EPIC)" >&2
    exit 1
fi

SPRINT_STATUS="${SPRINT_STATUS:-$DEFAULT_SPRINT_STATUS}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$DEFAULT_ARTIFACT_DIR}"

if [[ ! -f "$SPRINT_STATUS" ]]; then
    echo "ERROR: sprint-status.yaml not found: $SPRINT_STATUS" >&2
    exit 1
fi

if [[ ! -f "$PROMPT_TEMPLATE" ]]; then
    echo "ERROR: prompt template not found: $PROMPT_TEMPLATE" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. 定位 retro markdown 文件（最近一份）
# ---------------------------------------------------------------------------
if [[ -z "$RETRO_MD" ]]; then
    # 在 ARTIFACT_DIR 中找最近的 epic-${EPIC}-retro-*.md
    RETRO_MD=$(ls -1 "${ARTIFACT_DIR}/epic-${EPIC}-retro-"*.md 2>/dev/null | sort -r | head -n 1 || true)
    if [[ -z "$RETRO_MD" ]]; then
        echo "ERROR: no epic-${EPIC}-retro-*.md found in $ARTIFACT_DIR" >&2
        exit 1
    fi
fi

if [[ ! -f "$RETRO_MD" ]]; then
    echo "ERROR: retro markdown not found: $RETRO_MD" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. 解析 retro_action_items.epic-${EPIC}-retro 块（取每项 code/status/chore_spec）
# ---------------------------------------------------------------------------
# yaml 结构：
#   retro_action_items:
#     epic-${EPIC}-retro:
#       <code>: <status>      # comment
#         chore_spec: '<filename>'    (可选，第二级缩进表示)
#       ...
#
# 简化 parser 假设：
# - retro_action_items 顶层 key 唯一
# - epic-N-retro 二级 key 唯一
# - <code> 形如 [A-Z][0-9]+，行起始 ≥ 4 空格 + 紧跟冒号 + status
# - chore_spec 字段（如果存在）紧跟该 code 行下一行，缩进更深（≥ 6 空格）

# 先用 awk 圈定整个 retro_action_items 块（顶层 key 起到下一个顶层 key），再在块内
# 找 epic-${EPIC}-retro 子段（二级 key 起到下一个二级 key 或块尾）。
RETRO_BLOCK=$(awk -v epic="$EPIC" '
    BEGIN { in_block = 0; in_epic = 0; }
    /^retro_action_items:/ { in_block = 1; next }
    in_block && /^[a-zA-Z_]/ && !/^[[:space:]]/ { in_block = 0; in_epic = 0 }
    in_block && /^[[:space:]]+epic-[0-9]+-retro:/ {
        # 提取 epic 编号
        line = $0
        sub(/^.*epic-/, "", line)
        sub(/-retro:.*$/, "", line)
        if (line == epic) {
            in_epic = 1
        } else {
            in_epic = 0
        }
        next
    }
    in_block && in_epic { print }
' "$SPRINT_STATUS")

if [[ -z "$RETRO_BLOCK" ]]; then
    echo "ERROR: retro_action_items.epic-${EPIC}-retro block not found in $SPRINT_STATUS" >&2
    exit 1
fi

# 从 RETRO_BLOCK 中提取 (code, status, chore_spec)
# - code 行：^[[:space:]]+[A-Z][0-9]+:[[:space:]]+<status>(\s+#.*)?$
# - chore_spec 行：紧跟其后；缩进 ≥ 4 空格（typical 6）；以 'chore_spec:' 开始

declare -a CODES STATUSES CHORE_SPECS
parse_block() {
    local prev_code=""
    while IFS= read -r line; do
        # 匹配 code: status 行
        # Code 文法 [A-Z][A-Za-z0-9-]* 与 check_retro_action_items.sh / harness-commit.py
        # 统一（2026-05-05 codex review F1+F2 修复 — 此前用 [A-Z][0-9]+ 漏 C-bootstrap /
        # C-cond-triggers / C-codex-fixes / C-layout-consolidation / C-path-externalization /
        # C-run-sprint-init 等 alphanumeric-dash code）
        if [[ "$line" =~ ^[[:space:]]+([A-Z][A-Za-z0-9-]*):[[:space:]]+([a-zA-Z-]+)([[:space:]]+#.*)?$ ]]; then
            CODES+=("${BASH_REMATCH[1]}")
            STATUSES+=("${BASH_REMATCH[2]}")
            CHORE_SPECS+=("")
            prev_code="${BASH_REMATCH[1]}"
            continue
        fi
        # 匹配 chore_spec: '<filename>' 行（缩进更深）
        if [[ "$line" =~ ^[[:space:]]+chore_spec:[[:space:]]*[\'\"]?([^\'\"#]+)[\'\"]?[[:space:]]*(#.*)?$ ]]; then
            if [[ -n "$prev_code" ]]; then
                local idx=$((${#CHORE_SPECS[@]} - 1))
                local spec_val="${BASH_REMATCH[1]}"
                # trim
                spec_val="${spec_val%"${spec_val##*[![:space:]]}"}"
                CHORE_SPECS[$idx]="$spec_val"
            fi
            continue
        fi
    done <<< "$RETRO_BLOCK"
}
parse_block

if [[ ${#CODES[@]} -eq 0 ]]; then
    echo "ERROR: no action item codes parsed from epic-${EPIC}-retro block" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. 计算待 process 列表（status ∈ {pending, in-progress, partial} 且 chore_spec 缺失）
# ---------------------------------------------------------------------------
declare -a PENDING_CODES PENDING_STATUSES
declare -a EXISTING_SPECS

for i in "${!CODES[@]}"; do
    local_status="${STATUSES[$i]}"
    local_chore_spec="${CHORE_SPECS[$i]}"
    if [[ -n "$local_chore_spec" ]]; then
        EXISTING_SPECS+=("${CODES[$i]}=${local_chore_spec}")
        continue
    fi
    case "$local_status" in
        pending|in-progress|partial)
            PENDING_CODES+=("${CODES[$i]}")
            PENDING_STATUSES+=("$local_status")
            ;;
        done|deferred)
            # 跳过（终态或未触发）
            ;;
        *)
            echo "WARN: unknown status '${local_status}' for ${CODES[$i]} — skipping" >&2
            ;;
    esac
done

# ---------------------------------------------------------------------------
# 4. 待 process 列表为空 → "no residue" + exit 2
# ---------------------------------------------------------------------------
if [[ ${#PENDING_CODES[@]} -eq 0 ]]; then
    echo "no residue to process for epic-${EPIC}-retro" >&2
    echo "  total action items: ${#CODES[@]}" >&2
    echo "  with chore_spec already: ${#EXISTING_SPECS[@]}" >&2
    echo "  done/deferred: $(( ${#CODES[@]} - ${#EXISTING_SPECS[@]} - ${#PENDING_CODES[@]} ))" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# 5. 输出 prompt 到 stdout（主 agent 接管，喂给 fresh general-purpose agent）
# ---------------------------------------------------------------------------
echo "================================================================="
echo "# CHORE C10 — RETRO RESIDUE PROCESSOR — EPIC=${EPIC}"
echo "================================================================="
echo ""
echo "## ROLE & TASK INSTRUCTIONS（按下面 prompt 模板执行）"
echo ""
# 占位符替换 — \${project_display_name} 由 harness-project-config.yaml 提供值。
# 设计原则：harness 通用化 — clone 到新项目时仅改 yaml，prompt 模板不动。
PROJECT_DISPLAY_NAME="$(read_harness_config_field project_display_name 'this project')"
sed "s/\${project_display_name}/${PROJECT_DISPLAY_NAME//\//\\/}/g" "$PROMPT_TEMPLATE"
echo ""
echo "================================================================="
echo "## 当前 batch 元信息"
echo "================================================================="
echo ""
echo "- **EPIC**：${EPIC}"
echo "- **retro markdown**：\`${RETRO_MD#$ROOT/}\`"
echo "- **action items 总数（epic-${EPIC}-retro 段）**：${#CODES[@]}"
echo "- **已有 chore_spec 字段**：${#EXISTING_SPECS[@]}"
echo "- **待 process（pending / in-progress / partial 且 chore_spec 缺失）**：${#PENDING_CODES[@]}"
echo ""
echo "### 待 process 列表"
echo ""
for i in "${!PENDING_CODES[@]}"; do
    echo "- \`${PENDING_CODES[$i]}\` (status=\`${PENDING_STATUSES[$i]}\`)"
done
echo ""
if [[ ${#EXISTING_SPECS[@]} -gt 0 ]]; then
    echo "### 已有 chore_spec 字段（黑名单 — 不再生成）"
    echo ""
    for entry in "${EXISTING_SPECS[@]}"; do
        echo "- \`${entry}\`"
    done
    echo ""
fi
echo "================================================================="
echo "## 输入文件 1/2 — retro markdown 全文（${RETRO_MD#$ROOT/}）"
echo "================================================================="
echo ""
echo '```markdown'
cat "$RETRO_MD"
echo '```'
echo ""
echo "================================================================="
echo "## 输入文件 2/2 — sprint-status.yaml retro_action_items.epic-${EPIC}-retro 块"
echo "================================================================="
echo ""
echo '```yaml'
echo "retro_action_items:"
echo "  epic-${EPIC}-retro:"
echo "$RETRO_BLOCK"
echo '```'
echo ""
echo "================================================================="
echo "## 输出要求（重申）"
echo "================================================================="
echo ""
echo "对**${#PENDING_CODES[@]} 项**待 process action items 逐项生成 chore spec，"
echo "每个 spec 严格包裹在 \`=== FILE: chore-retro-c${EPIC}-<code>-<slug>.md ===\` 与"
echo "\`=== END FILE ===\` 之间。spec 内容严格按 prompt 模板的 5 段范式（Intent / Boundaries"
echo "/ I/O Matrix / Code Map / Tasks & Acceptance / Design Notes / Verification）。"
echo ""
echo "**所有 FILE block 之后**输出一个 \`=== MANIFEST ===\` block，列每条 chore 的 code → category"
echo "映射（dev | harness）。主 agent 据此写 sprint-status.yaml 的 \`category:\` 字段。"
echo "rubric / 边界判定 / 模糊归 harness 等约束详见 prompt 模板的 \"Category 分类 rubric\" 段。"
echo ""
echo "末尾另起一段给主 agent 的简短总结（≤ 200 字）：本批生成 spec 数 / 跳过数 / dev:harness 比例 / 任何异常。"
echo ""

exit 0

#!/usr/bin/env bash
# Chore C12 — Deferred Resolved Backfill 主入口
#
# 编排 fresh agent 反查 backfill：
#   (a) 解析 --epic N 必传
#   (b) 列出该 epic done story keys（从 sprint-status.yaml）
#   (c) 收集 4 类 artifact（spec / codex-review / dev-result / review-findings）
#   (d) 输出 stdout：prompt 模板 + deferred-work.md 全文 + 各 artifact 内容
#       (单文件 > 1500 行截断避免单批 prompt 过大)
#   (e) post-processing 由主 agent 接管：调 fresh agent → 收 patched md → diff_guardrail
#
# 用法：
#   bash .claude/harness/scripts/backfill_resolved_markers.sh --epic 1
#   bash .claude/harness/scripts/backfill_resolved_markers.sh --epic 2 --max-lines 800   # 调 truncate
#
# 输出（stdout）= fresh agent prompt 完整内容；主 agent 拷给 fresh general-purpose agent。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=read_harness_config.sh
source "$SCRIPT_DIR/read_harness_config.sh"
ROOT="$HARNESS_REPO_ROOT"
SPRINT_STATUS="$HARNESS_SPRINT_STATUS_PATH"
DEFERRED_WORK="$HARNESS_DEFERRED_WORK_PATH"
ARTIFACT_DIR="$HARNESS_ARTIFACTS_ROOT"
PROMPT_TEMPLATE="${SCRIPT_DIR}/backfill_resolved_markers_prompt.md"

EPIC=""
MAX_LINES=1500

while [[ $# -gt 0 ]]; do
    case "$1" in
        --epic)
            EPIC="${2:-}"
            shift 2
            ;;
        --max-lines)
            MAX_LINES="${2:-1500}"
            shift 2
            ;;
        *)
            echo "ERROR: unknown arg: $1" >&2
            echo "Usage: $0 --epic <1|2|3> [--max-lines <N>]" >&2
            exit 2
            ;;
    esac
done

if [[ -z "$EPIC" ]]; then
    echo "ERROR: --epic <1|2|3> required" >&2
    exit 2
fi

if [[ ! "$EPIC" =~ ^[1-3]$ ]]; then
    echo "ERROR: --epic must be 1, 2, or 3 (got: $EPIC)" >&2
    exit 2
fi

for f in "$SPRINT_STATUS" "$DEFERRED_WORK" "$PROMPT_TEMPLATE"; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: required file missing: $f" >&2
        exit 2
    fi
done

# Schema v1 deprecation guard (2026-05-05) — chore C12 done; deferred-work.md
# now uses status-tag schema. Old inline-marker output of this script would
# violate pre-commit hook gate ②. Bail out with clear error if schema v1 tags
# are present (allow override only via FORCE_LEGACY_BACKFILL=1 for fixture-mode
# self-tests against pre-schema-v1 fixtures).
if [[ "${FORCE_LEGACY_BACKFILL:-0}" != "1" ]] && grep -qE '\[status:(pending|resolved|partial|deferred|needs-review)\]' "$DEFERRED_WORK"; then
    cat >&2 <<EOF
ERROR: deferred-work.md uses schema v1 status tags — backfill_resolved_markers
       is the legacy inline-marker tool (chore C12; superseded 2026-05-04).
       Running it would teach fresh agent to write '— Resolved by Story X.Y'
       suffixes that pre-commit hook gate ② will reject.

       For schema v1 backfill (find FUs missing status flip + 历史 sub-entry),
       write a new prompt template per .claude/harness/conventions/deferred-work-schema.md
       §5 历史回填策略 — output should mutate [status:pending]→[status:resolved]
       + append 历史 sub-entry, NOT inline suffix.

       Override (fixture self-test against pre-schema-v1 fixture):
         FORCE_LEGACY_BACKFILL=1 bash $0 --epic <N>
EOF
    exit 3
fi

# 提取 epic-N 段下 status=done 的 story keys（不含 epic-N: done / epic-N-retrospective）
# 用 portable awk（BSD + GNU 兼容；不依赖 gawk-only 的 match($0, /re/, arr) 三参数形式）
done_keys() {
    awk -v epic="$EPIC" '
        /^development_status:/ { in_block = 1; next }
        /^[a-zA-Z_]+:/ && !/^[[:space:]]/ { in_block = 0 }
        in_block && /^[[:space:]]+# ===== Epic[[:space:]]+[0-9]+/ {
            line = $0
            sub(/^.*Epic[[:space:]]+/, "", line)
            sub(/[^0-9].*$/, "", line)
            cur_epic = line
        }
        in_block && cur_epic == epic && /^[[:space:]]+[0-9]+-[0-9]+-[a-z0-9-]+:[[:space:]]*done([[:space:]]|$|#)/ {
            key = $0
            sub(/^[[:space:]]+/, "", key)
            sub(/:.*$/, "", key)
            # 排除 epic-N-retrospective（key 形如 epic-N-retrospective 而非 N-M-...）
            if (key ~ /^[0-9]+-[0-9]+-/) {
                print key
            }
        }
    ' "$SPRINT_STATUS"
}

KEYS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && KEYS+=("$line")
done < <(done_keys)

if [[ ${#KEYS[@]} -eq 0 ]]; then
    echo "ERROR: no done stories found for epic-${EPIC}" >&2
    exit 2
fi

echo "# === backfill_resolved_markers prompt — EPIC=${EPIC} ===" >&2
echo "# done stories collected: ${#KEYS[@]}" >&2
for k in "${KEYS[@]}"; do
    echo "#   - $k" >&2
done
echo "# truncate per file to first ${MAX_LINES} lines" >&2
echo "" >&2

# 输出 prompt（stdout）
echo "================================================================="
echo "# CHORE C12 — DEFERRED RESOLVED BACKFILL — EPIC=${EPIC}"
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
echo "- **done stories（${#KEYS[@]} 个）**："
for k in "${KEYS[@]}"; do
    echo "  - \`${k}\`"
done
echo "- **截断阈值**：每文件前 ${MAX_LINES} 行"
echo ""
echo "================================================================="
echo "## 输入文件 1/2 — deferred-work.md（全文）"
echo "================================================================="
echo ""
echo '```markdown'
cat "$DEFERRED_WORK"
echo '```'
echo ""
echo "================================================================="
echo "## 输入文件 2/2 — sprint-status.yaml development_status 段（核对 done）"
echo "================================================================="
echo ""
echo '```yaml'
awk '/^development_status:/,/^[a-zA-Z_]+:/ { print }' "$SPRINT_STATUS" | head -200
echo '```'
echo ""

# 喂 4 类 artifact
truncate_lines() {
    local f="$1"
    if [[ -f "$f" ]]; then
        local total
        total=$(wc -l < "$f" | tr -d ' ')
        if (( total > MAX_LINES )); then
            head -n "$MAX_LINES" "$f"
            echo ""
            echo "[... truncated: showing first ${MAX_LINES} of ${total} lines; tail omitted to control prompt size ...]"
        else
            cat "$f"
        fi
    else
        echo "[file not found: $f]"
    fi
}

artifact_idx=0
artifact_total=$(( ${#KEYS[@]} * 4 ))
for k in "${KEYS[@]}"; do
    for suffix in ".md" ".codex-review.md" ".dev-result.json" ".review-findings.json"; do
        artifact_idx=$(( artifact_idx + 1 ))
        f="${ARTIFACT_DIR}/${k}${suffix}"
        echo "================================================================="
        echo "## Artifact ${artifact_idx}/${artifact_total} — ${k}${suffix}"
        echo "================================================================="
        echo ""
        # 选合适的代码块语言标签
        case "$suffix" in
            ".md"|".codex-review.md") lang="markdown" ;;
            ".dev-result.json"|".review-findings.json") lang="json" ;;
        esac
        echo "\`\`\`${lang}"
        truncate_lines "$f"
        echo '```'
        echo ""
    done
done

echo "================================================================="
echo "## 输出要求 (重申)"
echo "================================================================="
echo ""
echo "请严格按 prompt 模板的输出格式：完整 patched deferred-work.md 全文，包裹在"
echo "\`=== BEGIN PATCHED DEFERRED-WORK.MD ===\` 与 \`=== END PATCHED DEFERRED-WORK.MD ===\` 之间。"
echo "末尾另起一段给主 agent 的简短总结（≤ 200 字）。"
echo ""
echo "diff_guardrail 校验：仅追加 inline 标记到 FU 行末；任何删除 / 修改原文 → halt。"

#!/bin/bash
# Retro action items checker
#
# 扫 sprint-status.yaml 的 retro_action_items 块，按 category 分流：
#   - dev 类 pending + in-progress → 计 exit code（阻 epic 4/5/6 spec 创建）
#   - harness 类 pending + in-progress → stderr WARN 段，**不**计 exit code
#   - missing category → stderr WARN（schema drift 提示），保守按"不阻"处理
#
# 这是 2026-05-05 B 方案 retro automation refactor 的核心 — harness 类不再
# 阻 epic 推进，只作为待评估建议；dev 类（产品代码 / 测试 / NFR / ADR）保持
# pre-commit gate 强约束。详见 .claude/harness/architecture.md §六 Q4。
#
# 用法：
#   bash .claude/harness/scripts/check_retro_action_items.sh [path-to-sprint-status.yaml]
#
# 退出码：
#   0     全部通过（无 dev pending；harness pending 仅 WARN）
#   1     retro_action_items 块缺失（与 N=1 计数撞码 — 用 stderr "block missing" 文本消歧）
#   2     sprint-status.yaml 路径不存在
#   3-200 N 个 dev 类 pending+in-progress（200 是 cap：避免 256 wrap 到 0 = silent PASS）
#   250   retro_action_items 块存在但内含 0 个 action item（merge 误删 / yaml indent shift 兜底）
#   251   多个 retro_action_items: 顶层 key（重复 paste / merge 冲突未解决）
#
# v1 → v1.1 (review patches 2026-05-03)：E1 CRLF 容错、E3 status enum 白名单
# warn、E4 空块检测、E5 flexible indent、E6 重复 header 检测、E2 exit cap 200。
# v2 (2026-05-05): category 分流 — dev 计 exit / harness WARN 不计；扩展 item
# code regex 容纳 C-bootstrap / C-cond-triggers 等 alphanumeric-dash code。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=read_harness_config.sh
source "$SCRIPT_DIR/read_harness_config.sh"
SPRINT_STATUS="${1:-$HARNESS_SPRINT_STATUS_PATH}"

if [ ! -f "$SPRINT_STATUS" ]; then
    echo "ERROR: sprint-status.yaml not found at $SPRINT_STATUS" >&2
    exit 2
fi

# E6: 重复 retro_action_items 顶层 key（行首无缩进 + 冒号结尾）
header_count="$(grep -cE "^retro_action_items:" "$SPRINT_STATUS" || true)"
if [ "$header_count" -gt 1 ]; then
    echo "ERROR: multiple retro_action_items: top-level keys found ($header_count) — yaml ambiguous, fix before commit" >&2
    exit 251
fi

if ! grep -qE "^retro_action_items:" "$SPRINT_STATUS"; then
    echo "ERROR: retro_action_items block missing in $SPRINT_STATUS — run C1 seed first" >&2
    exit 1
fi

# awk 提取 retro_action_items 块；遇下一个顶层 key 即结束块。
# 块内识别三类行：
#   "  epic-N-retro:"            → 当前 epic 上下文
#   "    <CODE>: <status>"       → action item header（CODE = [A-Z][A-Za-z0-9-]*）
#   "      category: <value>"    → action item 的 category 子字段
#
# 状态机：维护 (current_epic, current_code, current_status, current_category)；
# 每遇新 action item header 或 epic header 或块结束时 flush 上一项。
# E1: 显式 strip \r 容 Windows CRLF 入库。
# E3: 未知 status（不在 5 值 enum 内）走 UNKNOWN 通道 + warn。
# v2: 未知或缺失 category（不在 {dev, harness}）走 NOCAT 通道 + warn，但**不阻**。
result="$(awk '
  function flush_item() {
    if (current_code != "") {
      total++
      if (current_status != "pending" \
          && current_status != "in-progress" \
          && current_status != "partial" \
          && current_status != "deferred" \
          && current_status != "done" \
          && current_status != "migrated-upstream") {
        printf "UNKNOWN_STATUS  %s / %s / %s\n", current_epic, current_code, current_status
        unknown_status++
      } else if (current_status == "pending" || current_status == "in-progress") {
        if (current_category == "dev") {
          printf "PENDING_DEV  %s / %s / %s\n", current_epic, current_code, current_status
          pending_dev++
        } else if (current_category == "harness") {
          printf "PENDING_HARNESS  %s / %s / %s\n", current_epic, current_code, current_status
          pending_harness++
        } else {
          printf "PENDING_NOCAT  %s / %s / %s / category=[%s]\n", current_epic, current_code, current_status, current_category
          pending_nocat++
        }
      }
    }
    current_code=""; current_status=""; current_category=""
  }

  /^retro_action_items:/ { in_block=1; next }
  in_block && /^[^[:space:]#]/ { flush_item(); in_block=0 }

  in_block && /^[[:space:]]+[a-z0-9-]+-retro:[[:space:]]*$/ {
    flush_item()
    match($0, /[a-z0-9-]+-retro/)
    current_epic = substr($0, RSTART, RLENGTH)
    next
  }

  in_block && /^[[:space:]]+[A-Z][A-Za-z0-9-]*:[[:space:]]/ {
    flush_item()
    code = $1
    sub(":$", "", code)
    current_code = code
    current_status = $2
    sub(/\r$/, "", current_status)
    gsub(/["'"'"']/, "", current_status)
    next
  }

  in_block && /^[[:space:]]+category:[[:space:]]/ {
    cat = $2
    sub(/\r$/, "", cat)
    gsub(/["'"'"']/, "", cat)
    current_category = cat
    next
  }

  END {
    flush_item()
    printf "_TOTAL_:%d\n", total+0
    printf "_PENDING_DEV_:%d\n", pending_dev+0
    printf "_PENDING_HARNESS_:%d\n", pending_harness+0
    printf "_PENDING_NOCAT_:%d\n", pending_nocat+0
    printf "_UNKNOWN_STATUS_:%d\n", unknown_status+0
  }
' "$SPRINT_STATUS")"

total="$(printf '%s\n' "$result" | awk -F: '/^_TOTAL_:/{print $2; exit}')"
pending_dev="$(printf '%s\n' "$result" | awk -F: '/^_PENDING_DEV_:/{print $2; exit}')"
pending_harness="$(printf '%s\n' "$result" | awk -F: '/^_PENDING_HARNESS_:/{print $2; exit}')"
pending_nocat="$(printf '%s\n' "$result" | awk -F: '/^_PENDING_NOCAT_:/{print $2; exit}')"
unknown_status="$(printf '%s\n' "$result" | awk -F: '/^_UNKNOWN_STATUS_:/{print $2; exit}')"

# E4: 块存在但 0 项 — 多半是 merge 误删 / yaml indent shift；显式失败防 silent PASS
if [ "$total" -eq 0 ]; then
    echo "ERROR: retro_action_items block exists but contains 0 action items —" >&2
    echo "       likely merge accident or yaml re-indent dropped all items." >&2
    echo "       Check sprint-status.yaml retro_action_items: block (expected ≥ 26 items from C1 seed)." >&2
    exit 250
fi

# E3: warn on unknown status — 不阻断，仅提示拼写错
if [ "$unknown_status" -gt 0 ]; then
    echo "WARN: $unknown_status action item(s) have unrecognized status (not in {pending|in-progress|partial|deferred|done|migrated-upstream}):" >&2
    printf '%s\n' "$result" | grep '^UNKNOWN_STATUS  ' | sed 's/^UNKNOWN_STATUS  /  /' >&2
    echo "      Fix the typo / case in sprint-status.yaml; gate currently treats unknown status as non-blocking." >&2
fi

# v2: warn on missing/unknown category — 不阻断，但提示 schema drift（应补 category 字段）
if [ "$pending_nocat" -gt 0 ]; then
    echo "" >&2
    echo "WARN: $pending_nocat pending action item(s) have missing / unrecognized category (expected 'dev' or 'harness'):" >&2
    printf '%s\n' "$result" | grep '^PENDING_NOCAT  ' | sed 's/^PENDING_NOCAT  /  /' >&2
    echo "      Schema drift — add 'category: dev' or 'category: harness' to each item;" >&2
    echo "      gate currently treats missing-category as non-blocking (defaults to harness)." >&2
fi

# v2: harness 类 pending — stderr WARN，不计 exit code
if [ "$pending_harness" -gt 0 ]; then
    echo "" >&2
    echo "WARN: $pending_harness harness optimization suggestion(s) pending (non-blocking — does NOT gate epic 4/5/6 spec creation):" >&2
    printf '%s\n' "$result" | grep '^PENDING_HARNESS  ' | sed 's/^PENDING_HARNESS  /  /' >&2
    echo "      To file these as GitHub issues for the plugin maintainer, run:" >&2
    echo "          /harness-zh:report-issue" >&2
    echo "      （v0.1.26+ — 自动收集 plugin 版本 / sprint 状态 / 近期 commits + gh CLI 直提；" >&2
    echo "        替代 v0.1.14-0.1.25 的 upstream-feedback.md 通道）。" >&2
fi

# v2: dev 类 pending — 计 exit code，与原 v1 行为一致
if [ "$pending_dev" -gt 0 ]; then
    echo "" >&2
    echo "Pending dev retro action items (BLOCKING): $pending_dev" >&2
    printf '%s\n' "$result" | grep '^PENDING_DEV  ' | sed 's/^PENDING_DEV  /  /' >&2
    # E2: cap exit at 200 — 200+ wrap 到 0 = silent PASS 是设计 bug；保留 200-255 给
    # 错误码空间（250/251/+ 未来扩展）。pending 真到 200 时 stderr 仍有完整列表。
    exit_code="$pending_dev"
    [ "$exit_code" -gt 200 ] && exit_code=200
    exit "$exit_code"
fi

echo "Pending dev retro action items: 0 (all clear; harness pending shown as WARN above if any)" >&2
exit 0

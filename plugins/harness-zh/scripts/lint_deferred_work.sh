#!/usr/bin/env bash
# Deferred-work schema lint — advisory tool（v0.1.20）
#
# 扫描整份 deferred-work.md（不限增量），列出**所有**不符合 schema v1 的 FU bullet。
# 与 pre-commit gate ② 互补：
#   - pre-commit gate ② 只校验**新增行**（防止再写错）
#   - 本工具校验**整文件**（项目历史 backfill 用 — 找出已存在的漂移条目）
#
# 5 类 violation（与 schema §2.1/§3.x 对齐）：
#   (a) FU bullet 头不带完整 4-tag 块
#   (b) [target:...] 值不在 schema §3.3 枚举内（最常见漂移：用 `1-7-全名`
#       story-key 风格而非 `Story 1.7` 短格式 — silently 让 grep_pending_*
#       工具空命中）
#   (c) FU-RETRO-* 命名空间（应在 sprint-status.yaml.retro_action_items）
#   (d) 老 inline 后缀 "— Resolved by Story X.Y (date):"（schema §3.1 废弃）
#   (e) [status:...] 值不在 7 值枚举内（schema §3.1）
#
# 输出：
#   - stdout：每条违规一行，格式 `<line-num>:<violation-type>:<excerpt>`
#   - stderr：分类汇总 + 修复指引
#   - exit code：违规条数（0 = 全合规；> 200 cap 到 200）
#
# 用法：
#   bash .claude/harness/scripts/lint_deferred_work.sh                # 默认 path
#   bash .claude/harness/scripts/lint_deferred_work.sh path/to/dw.md  # 指定 path
#
# 不**自动修**任何东西；solo-dev 看输出后决定批量 sed 还是手工改。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=read_harness_config.sh
source "$SCRIPT_DIR/read_harness_config.sh" 2>/dev/null || {
    # fallback when read_harness_config.sh missing (e.g. test fixture)
    HARNESS_DEFERRED_WORK_PATH="${HARNESS_DEFERRED_WORK_PATH:-_bmad-output/implementation-artifacts/deferred-work.md}"
}

DW_PATH="${1:-${HARNESS_DEFERRED_WORK_PATH:-_bmad-output/implementation-artifacts/deferred-work.md}}"

if [ ! -f "$DW_PATH" ]; then
    echo "ERROR: deferred-work.md not found at: $DW_PATH" >&2
    echo "       Pass path as arg or set HARNESS_DEFERRED_WORK_PATH env var." >&2
    exit 1
fi

# Schema regexes — v0.1.27+: source shared lib (single SoT for both this
# scanner and pre-commit gate ②). Falls back to inline if lib missing.
# 守护对齐 git-hooks/pre-commit gate ②（issue #7 同族）：file 在场 ≠ 常量
# 齐全（截断/旧版 skew），set -u 下裸引 DWSL_* 会 rc=1 崩 — 而本脚本契约
# rc=违规数，崩溃会被误读成「1 violation」。显式 if 而非 ${VAR:-default}：
# default 值含 {4} 量词，内层 } 会截断替换（详 pre-commit 同位置注释）。
if [ -f "$SCRIPT_DIR/deferred_work_schema_lib.sh" ]; then
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/deferred_work_schema_lib.sh"
fi
if [ -n "${DWSL_HEAD_FULL_RE:-}" ] && [ -n "${DWSL_TARGET_VALID_RE:-}" ] \
   && [ -n "${DWSL_STATUS_VALID_RE:-}" ] && [ -n "${DWSL_LEGACY_INLINE_RE:-}" ]; then
    HEAD_FULL_RE="$DWSL_HEAD_FULL_RE"
    TARGET_VALID_RE="$DWSL_TARGET_VALID_RE"
    STATUS_VALID_RE="$DWSL_STATUS_VALID_RE"
    LEGACY_INLINE_RE="$DWSL_LEGACY_INLINE_RE"
else
    HEAD_FULL_RE='^- \*\*FU-[A-Za-z0-9._\-]+\*\* `\[status:[a-z\-]+\]` `\[bucket:[a-zA-Z0-9.+\-]+\]` `\[target:[^]`]*\]` `\[source:[^]`]*\]`'
    TARGET_VALID_RE='^(Story [0-9]+\.[0-9]+([.-][A-Za-z0-9]+)?|Epic [0-9]+( [A-Za-z][A-Za-z0-9 -]*)?|v[0-9]+\.[0-9]+\+ [A-Za-z][A-Za-z0-9-]+|customer-feedback|N/A)$'
    STATUS_VALID_RE='^(pending|in-progress|partial|resolved|deferred|needs-review|superseded)$'
    LEGACY_INLINE_RE='— (\*\*)?(Resolved|Partial resolution) by Story [0-9.]+(\*\*)? \([0-9]{4}-'
fi

# Counters
COUNT_A=0   # missing 4-tag head
COUNT_B=0   # bad target
COUNT_C=0   # FU-RETRO-*
COUNT_D=0   # legacy inline
COUNT_E=0   # bad status
TOTAL=0

# Output buffer (collected, dumped to stdout at end for stable ordering)
VIOLATIONS=""

# Tag-value extraction regexes (used with bash [[ =~ ]] / BASH_REMATCH).
STATUS_EXTRACT_RE='`\[status:([^]`]*)\]`'
TARGET_EXTRACT_RE='`\[target:([^]`]*)\]`'

# review 2026-06-10 #51 主循环重写：
#   - 全部判定改 bash 内建 `[[ =~ ]]`（同为 POSIX ERE，语义与原 grep -E 一致）—
#     原实现每行 fork 最多 7 个 printf|grep/sed 子进程，千行文件数千次 fork，
#     bash 3.2 macOS 上一次 lint 十几秒；现在整文件 0 fork。
#   - excerpt 截断改 `${line:0:100}`（按字符）— 原 `head -c 100` 按字节切，
#     CJK excerpt 会被切成非法 UTF-8，破坏 stdout 的 grep-friendly 机器契约。
#   - 循环条件补 `|| [ -n "$line" ]` — 原实现在文件末行缺换行符时 read 返回
#     非 0，最后一行不进循环，末行违规被静默漏检。
LINE_NUM=0
while IFS= read -r line || [ -n "$line" ]; do
    LINE_NUM=$((LINE_NUM + 1))

    # Only check FU bullet head lines (lines starting with `- **FU-`)
    case "$line" in
        "- **FU-"*)
            # (c) FU-RETRO-* check (highest priority — namespace violation)
            if [[ "$line" == "- **FU-RETRO-"* ]]; then
                excerpt="${line:0:100}"
                VIOLATIONS="${VIOLATIONS}${LINE_NUM}:c-fu-retro-namespace:${excerpt}"$'\n'
                COUNT_C=$((COUNT_C + 1))
                TOTAL=$((TOTAL + 1))
                continue
            fi

            # (a) Missing 4-tag head
            if ! [[ "$line" =~ $HEAD_FULL_RE ]]; then
                excerpt="${line:0:100}"
                VIOLATIONS="${VIOLATIONS}${LINE_NUM}:a-missing-4tag-head:${excerpt}"$'\n'
                COUNT_A=$((COUNT_A + 1))
                TOTAL=$((TOTAL + 1))
                continue
            fi

            # Header is well-formed — extract status + target via BASH_REMATCH
            status_val=""
            [[ "$line" =~ $STATUS_EXTRACT_RE ]] && status_val="${BASH_REMATCH[1]}"
            target_val=""
            [[ "$line" =~ $TARGET_EXTRACT_RE ]] && target_val="${BASH_REMATCH[1]}"

            # (e) Bad status value
            if ! [[ "$status_val" =~ $STATUS_VALID_RE ]]; then
                VIOLATIONS="${VIOLATIONS}${LINE_NUM}:e-bad-status:[status:${status_val}]"$'\n'
                COUNT_E=$((COUNT_E + 1))
                TOTAL=$((TOTAL + 1))
            fi

            # (b) Bad target value
            if ! [[ "$target_val" =~ $TARGET_VALID_RE ]]; then
                VIOLATIONS="${VIOLATIONS}${LINE_NUM}:b-bad-target:[target:${target_val}]"$'\n'
                COUNT_B=$((COUNT_B + 1))
                TOTAL=$((TOTAL + 1))
            fi
            ;;
    esac

    # (d) Legacy inline suffix — anywhere in file (not just FU heads)
    if [[ "$line" =~ $LEGACY_INLINE_RE ]]; then
        excerpt="${line:0:100}"
        VIOLATIONS="${VIOLATIONS}${LINE_NUM}:d-legacy-inline-suffix:${excerpt}"$'\n'
        COUNT_D=$((COUNT_D + 1))
        TOTAL=$((TOTAL + 1))
    fi
done < "$DW_PATH"

# Print all violations to stdout (grep-friendly)
printf '%s' "$VIOLATIONS"

# Summary to stderr
{
    echo ""
    echo "─────────────────────────────────────────────────────"
    echo "deferred-work.md schema v1 lint — $DW_PATH"
    echo "─────────────────────────────────────────────────────"
    echo "  (a) missing 4-tag head     : $COUNT_A"
    echo "  (b) bad [target:...] value : $COUNT_B"
    echo "  (c) FU-RETRO-* namespace   : $COUNT_C"
    echo "  (d) legacy inline suffix   : $COUNT_D"
    echo "  (e) bad [status:...] value : $COUNT_E"
    echo "  ────────────────────────────"
    echo "  total violations            : $TOTAL"
    echo ""

    if [ "$TOTAL" = 0 ]; then
        echo "✓ all FU bullets schema-compliant"
    else
        echo "Schema 权威：.claude/harness/conventions/deferred-work-schema.md"
        echo ""
        if [ "$COUNT_B" -gt 0 ]; then
            echo "(b) target 漂移最常见：用 'X-Y-全名' story-key 风格而非 'Story X.Y'。"
            echo "    批量修示例：sed -i 's/\\[target:1-7-[^]]*\\]/[target:Story 1.7]/g' \"$DW_PATH\""
            echo "    跑 grep_pending_deferred_for_story.sh 1-7-... 在修后会找到该 FU。"
            echo ""
        fi
        if [ "$COUNT_A" -gt 0 ]; then
            echo "(a) 缺 4-tag — 用 schema §2.1 头格式补全 status / bucket / target / source。"
            echo ""
        fi
        if [ "$COUNT_C" -gt 0 ]; then
            echo "(c) FU-RETRO-* 应整体迁到 sprint-status.yaml.retro_action_items（schema §3.2）。"
            echo ""
        fi
    fi
    echo "─────────────────────────────────────────────────────"
} >&2

# Exit code = total violations, capped at 200 (255 wraps to 0 = silent PASS)
EXIT_CODE="$TOTAL"
[ "$EXIT_CODE" -gt 200 ] && EXIT_CODE=200
exit "$EXIT_CODE"

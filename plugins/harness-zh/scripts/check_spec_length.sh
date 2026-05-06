#!/usr/bin/env bash
# Spec length lint
#
# 验 spec 文件行数：≤ 500 通过；500 < N ≤ 800 warn (exit 2)；> 800 阻断
# (exit 1) 除非 frontmatter 含 `large_spec_justification: <reason>` 字段。
#
# 用法：
#   bash .claude/harness/scripts/check_spec_length.sh <spec-path>
#
# 退出码：
#   0   ≤ 500 行（通过）
#   1   > 800 行 + 无 large_spec_justification（阻断）
#   2   500 < N ≤ 800 行（warn）；OR > 800 行 + 含 justification（warn 通过）
#   3   spec 文件不存在 / 参数缺失

set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <spec-path>" >&2
    exit 3
fi

SPEC="$1"

if [ ! -f "$SPEC" ]; then
    echo "ERROR: spec file not found: $SPEC" >&2
    exit 3
fi

lines="$(wc -l < "$SPEC" | tr -d ' ')"

# 抓 frontmatter 内 large_spec_justification 字段（仅看首个 ---...--- 块）
justification=""
if head -n 1 "$SPEC" | grep -q '^---$'; then
    fm="$(sed -n '2,/^---$/p' "$SPEC" | sed '$d')"
    just_line="$(echo "$fm" | grep -E '^large_spec_justification:' | head -n 1 || true)"
    if [ -n "$just_line" ]; then
        justification="${just_line#large_spec_justification:}"
        justification="${justification# }"
        justification="${justification#\"}"
        justification="${justification%\"}"
        justification="${justification#\'}"
        justification="${justification%\'}"
    fi
fi

SOFT_CAP=500
HARD_CAP=800

if [ "$lines" -le "$SOFT_CAP" ]; then
    echo "PASS: $SPEC has $lines lines (≤ $SOFT_CAP soft cap)"
    exit 0
elif [ "$lines" -le "$HARD_CAP" ]; then
    echo "WARN: $SPEC has $lines lines (soft cap $SOFT_CAP < N ≤ hard $HARD_CAP)" >&2
    echo "      考虑 extract D-decisions / canonical pin 段；或在 frontmatter 加 large_spec_justification 字段说明合理性。" >&2
    exit 2
else
    if [ -n "$justification" ]; then
        echo "WARN: $SPEC has $lines lines (> hard $HARD_CAP) — accepted via large_spec_justification: $justification" >&2
        exit 2
    else
        echo "FAIL: $SPEC has $lines lines (> hard cap $HARD_CAP)" >&2
        echo "      解法 A: shrink spec (extract D-decisions to architecture/decisions/d-{epic}-{story}.md)" >&2
        echo "      解法 B: 在 spec frontmatter 加 'large_spec_justification: <reason>' 字段（≥ 1 句话理由）" >&2
        exit 1
    fi
fi

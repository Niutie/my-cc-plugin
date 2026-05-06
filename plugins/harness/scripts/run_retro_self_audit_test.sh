#!/usr/bin/env bash
# run_retro_self_audit self-test
# 实测脚本输出格式 + 表格行数 + 几个状态判定
set -euo pipefail

cd "$(dirname "$0")/../../.."

OUT="$(bash .claude/harness/scripts/run_retro_self_audit.sh 3)"

# 检查表头
if ! echo "$OUT" | head -1 | grep -qE '^\| id \| 描述 \| status \| evidence \|$'; then
    echo "FAIL: 表头格式不正确" >&2
    echo "$OUT" | head -3 >&2
    exit 1
fi

# 检查行数 ≥ 26（A1-A8 + B1-B9 + C1-C9）+ 2 表头
total_rows="$(echo "$OUT" | grep -c '^|' || true)"
if [ "$total_rows" -lt 28 ]; then
    echo "FAIL: 表格行数 $total_rows < 28（期望 ≥ 28：表头 1 + 表头分隔 1 + 26 数据行）" >&2
    exit 1
fi

# 检查 A1 出现且 status 字段是 done/pending/partial/unknown 之一
a1_row="$(echo "$OUT" | grep '^| A1 ' || true)"
if [ -z "$a1_row" ]; then
    echo "FAIL: A1 行缺失" >&2
    exit 1
fi
if ! echo "$a1_row" | grep -qE '\| (done|pending|partial|unknown) \|'; then
    echo "FAIL: A1 status 字段不在 4 类 enum 内" >&2
    echo "  row: $a1_row" >&2
    exit 1
fi

# 检查 C9 行（脚本自身落地后应自报 done）
c9_row="$(echo "$OUT" | grep '^| C9 ' || true)"
if [ -z "$c9_row" ]; then
    echo "FAIL: C9 行缺失" >&2
    exit 1
fi
if ! echo "$c9_row" | grep -q '| done |'; then
    echo "FAIL: C9 应自报 done（脚本已落地）；实际：$c9_row" >&2
    exit 1
fi

# 跑 prev_epic=1 仅扫 A* 系列
OUT_E1="$(bash .claude/harness/scripts/run_retro_self_audit.sh 1)"
e1_rows="$(echo "$OUT_E1" | grep -cE '^\| [ABC][0-9]' || true)"
if [ "$e1_rows" -ne 8 ]; then
    echo "FAIL: prev_epic=1 期望 8 行（A1-A8）；实际 $e1_rows" >&2
    exit 1
fi

echo "PASS: run_retro_self_audit_test.sh ($total_rows total rows for prev_epic=3, $e1_rows for prev_epic=1)"
exit 0

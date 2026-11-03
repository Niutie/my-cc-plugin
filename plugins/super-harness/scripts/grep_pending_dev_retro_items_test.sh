#!/bin/bash
# Self-tests for grep_pending_dev_retro_items.sh (issue #3 — run §0.A.0 preflight enumerator)
#
# 验证 stdout 机器契约（ITEM 行 + 三行汇总），而非 exit code（enumerator 恒 exit 0
# 除文件缺失外）。Fixtures：
#   (a) dev pending+in-progress 混 harness/done → 仅列 dev 待兑现项 + 正确 with/no-spec 分桶
#   (b) 全 done                                 → 0 项
#   (c) 仅 harness pending                       → 0 项（harness 不进 gate ①）
#   (d) 缺 category（NOCAT）                     → 0 项（非 dev → 不进 gate ① dev 计数口径）
#   (e) 块缺失                                   → 0 项 + stderr WARN "block missing"
#   (f) 重复顶层 key                             → 0 项 + stderr WARN "multiple"
#   (g) 文件缺失                                 → exit 2
#   (h) chore_spec 与 check_retro_action_items.sh dev 计数一致性（回归锚）
#
# 整脚本退出码 = 失败 fixture 数（0 = 全过）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENUM="$SCRIPT_DIR/grep_pending_dev_retro_items.sh"
GATE="$SCRIPT_DIR/check_retro_action_items.sh"

if [ ! -f "$ENUM" ]; then
    echo "ERROR: enumerator not found at $ENUM" >&2
    exit 1
fi

failed=0

# assert stdout summary line + optional ITEM-line grep
run_test() {
    local name="$1" fixture="$2" want_pending="$3" want_with="$4" want_no="$5" want_item_re="$6"
    local tmpfile stdout
    tmpfile="$(mktemp)"
    printf '%s' "$fixture" > "$tmpfile"
    stdout="$(bash "$ENUM" "$tmpfile" 2>/dev/null)" || { echo "FAIL [$name]: enumerator exited non-zero" >&2; failed=$((failed+1)); rm -f "$tmpfile"; return; }
    rm -f "$tmpfile"

    local got_pending got_with got_no
    got_pending="$(printf '%s\n' "$stdout" | sed -n 's/^_PENDING_DEV_:\(.*\)$/\1/p')"
    got_with="$(printf '%s\n' "$stdout" | sed -n 's/^_WITH_SPEC_:\(.*\)$/\1/p')"
    got_no="$(printf '%s\n' "$stdout" | sed -n 's/^_NO_SPEC_:\(.*\)$/\1/p')"

    if [ "$got_pending" != "$want_pending" ] || [ "$got_with" != "$want_with" ] || [ "$got_no" != "$want_no" ]; then
        echo "FAIL [$name]: counts pending=$got_pending/with=$got_with/no=$got_no, wanted $want_pending/$want_with/$want_no" >&2
        echo "  stdout: $stdout" >&2
        failed=$((failed+1)); return
    fi
    if [ -n "$want_item_re" ] && ! printf '%s' "$stdout" | grep -qE "$want_item_re"; then
        echo "FAIL [$name]: ITEM line did not match /$want_item_re/" >&2
        echo "  stdout: $stdout" >&2
        failed=$((failed+1)); return
    fi
    echo "PASS [$name]"
}

# --- Fixture A: dev pending/in-progress + harness + done 混 ---
FIX_A="development_status:
  epic-4: done
retro_action_items:
  epic-4-retro:
    D7: pending
      category: dev
      chore_spec: 'chore-retro-c4-D7-foo.md'
    D8: in-progress
      category: dev
    D9: done
      category: dev
      chore_spec: 'chore-retro-c4-D9-bar.md'
    D10: pending
      category: harness
    D11: pending
      category: dev
      chore_spec: 'chore-retro-c4-D11-baz.md'

test_status: {}
"
run_test "dev-mixed" "$FIX_A" 3 2 1 $'^ITEM\tepic-4-retro\tD7\tpending\tchore-retro-c4-D7-foo.md$'
# D8 (no spec) must appear with "-"
tmpd8="$(mktemp)"; printf '%s' "$FIX_A" > "$tmpd8"
if ! bash "$ENUM" "$tmpd8" 2>/dev/null | grep -qE $'^ITEM\tepic-4-retro\tD8\tin-progress\t-$'; then
    echo "FAIL [dev-mixed-D8-nospec]: D8 in-progress no-spec row missing" >&2; failed=$((failed+1))
else
    echo "PASS [dev-mixed-D8-nospec]"
fi
rm -f "$tmpd8"

# --- Fixture B: 全 done ---
run_test "all-done" "retro_action_items:
  epic-1-retro:
    A1: done
      category: dev
    A2: deferred
      category: dev
" 0 0 0 ""

# --- Fixture C: 仅 harness pending ---
run_test "harness-only" "retro_action_items:
  epic-2-retro:
    B1: pending
      category: harness
    B2: in-progress
      category: harness
" 0 0 0 ""

# --- Fixture D: 缺 category（NOCAT，不算 dev）---
run_test "nocat" "retro_action_items:
  epic-2-retro:
    B1: pending
" 0 0 0 ""

# --- Fixture E: 块缺失 ---
EX_E=0; tmpe="$(mktemp)"; printf 'development_status:\n  epic-1: done\n' > "$tmpe"
out_e="$(bash "$ENUM" "$tmpe" 2>&1)" || EX_E=$?
rm -f "$tmpe"
if [ "$EX_E" = 0 ] && printf '%s' "$out_e" | grep -qE "_PENDING_DEV_:0" && printf '%s' "$out_e" | grep -qE "block missing"; then
    echo "PASS [block-missing]"
else
    echo "FAIL [block-missing]: exit=$EX_E out=$out_e" >&2; failed=$((failed+1))
fi

# --- Fixture F: 重复顶层 key ---
EX_F=0; tmpf="$(mktemp)"; printf 'retro_action_items:\n  epic-1-retro:\n    A1: done\nretro_action_items:\n  epic-2-retro:\n    B1: pending\n' > "$tmpf"
out_f="$(bash "$ENUM" "$tmpf" 2>&1)" || EX_F=$?
rm -f "$tmpf"
if [ "$EX_F" = 0 ] && printf '%s' "$out_f" | grep -qE "_PENDING_DEV_:0" && printf '%s' "$out_f" | grep -qiE "multiple"; then
    echo "PASS [dup-header]"
else
    echo "FAIL [dup-header]: exit=$EX_F out=$out_f" >&2; failed=$((failed+1))
fi

# --- Fixture G: 文件缺失 → exit 2 ---
EX_G=0
bash "$ENUM" /nonexistent/path/sprint-status.yaml >/dev/null 2>&1 || EX_G=$?
if [ "$EX_G" = 2 ]; then
    echo "PASS [file-missing]"
else
    echo "FAIL [file-missing]: expected exit 2 got $EX_G" >&2; failed=$((failed+1))
fi

# --- Fixture H: 与 gate dev 计数一致性回归锚 ---
if [ -f "$GATE" ]; then
    tmph="$(mktemp)"; printf '%s' "$FIX_A" > "$tmph"
    gate_exit=0; bash "$GATE" "$tmph" >/dev/null 2>&1 || gate_exit=$?
    enum_pending="$(bash "$ENUM" "$tmph" 2>/dev/null | sed -n 's/^_PENDING_DEV_:\(.*\)$/\1/p')"
    rm -f "$tmph"
    if [ "$gate_exit" = "$enum_pending" ]; then
        echo "PASS [gate-parity] (both report $gate_exit dev pending)"
    else
        echo "FAIL [gate-parity]: gate exit=$gate_exit vs enum pending=$enum_pending" >&2; failed=$((failed+1))
    fi
else
    echo "SKIP [gate-parity] (checker not found)"
fi

echo "-------------------------------------------------------------------"
if [ "$failed" = 0 ]; then
    echo "ALL PASS"
else
    echo "$failed test(s) FAILED"
fi
exit "$failed"

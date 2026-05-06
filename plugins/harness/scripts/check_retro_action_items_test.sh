#!/bin/bash
# Self-tests for check_retro_action_items.sh (Epic 3 retro §C1 + 2026-05-05 v2)
#
# Fixtures：
#   (a) 全 done                              → exit 0   + stderr 含 "all clear"
#   (b) 2 dev pending + 1 dev in-progress    → exit 3   + stderr 含 "BLOCKING" + 3 item 行
#   (c) 块缺失                                → exit 1   + stderr 含 "block missing"
#   (d) 块存在但 0 项 (E4)                    → exit 250 + stderr 含 "0 action items"
#   (e) 重复顶层 key (E6)                     → exit 251 + stderr 含 "multiple retro_action_items"
#   (f) CRLF 行尾 (E1)                        → exit 1   (CRLF dev pending 仍命中)
#   (g) 未知 status (E3)                     → exit 0   + stderr 含 "WARN" + "unrecognized status"
#   (h) flexible indent 6-space (E5)          → exit 1   (1 dev pending; 块识别成功)
#   (i) 仅 harness pending (v2)               → exit 0   + stderr 含 "non-blocking"
#   (j) 混合 dev+harness pending (v2)         → exit 1   + stderr 含 "BLOCKING" + "non-blocking"
#   (k) pending 但缺 category (v2 NOCAT)      → exit 0   + stderr 含 "missing / unrecognized category"
#   (l) C-bootstrap 类 alphanumeric-dash code → exit 1   (extended regex 命中)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="$SCRIPT_DIR/check_retro_action_items.sh"

if [ ! -f "$CHECKER" ]; then
    echo "ERROR: checker not found at $CHECKER" >&2
    exit 1
fi

failed=0

run_test() {
    local name="$1"
    local expected_exit="$2"
    local fixture="$3"
    local expected_stderr_re="$4"

    local tmpfile
    tmpfile="$(mktemp)"
    trap 'rm -f "$tmpfile"' RETURN

    printf '%s' "$fixture" > "$tmpfile"

    local actual_exit=0
    local stderr_output
    stderr_output="$(bash "$CHECKER" "$tmpfile" 2>&1 >/dev/null)" || actual_exit=$?

    if [ "$actual_exit" != "$expected_exit" ]; then
        echo "FAIL [$name]: expected exit=$expected_exit got exit=$actual_exit" >&2
        echo "  stderr: $stderr_output" >&2
        failed=$((failed + 1))
        return
    fi

    if [ -n "$expected_stderr_re" ] && ! printf '%s' "$stderr_output" | grep -qE "$expected_stderr_re"; then
        echo "FAIL [$name]: stderr did not match /$expected_stderr_re/" >&2
        echo "  stderr: $stderr_output" >&2
        failed=$((failed + 1))
        return
    fi

    echo "PASS [$name]"
}

# --- Fixture A: 全 done ---
run_test "all-done" 0 "development_status:
  epic-1: done
retro_action_items:
  epic-1-retro:
    A1: done
      category: dev
    A2: deferred
      category: dev
    A3: partial
      category: harness
" "all clear"

# --- Fixture B: 2 dev pending + 1 dev in-progress (v2: dev 阻断) ---
run_test "pending-dev-mix" 3 "development_status:
  epic-1: done
retro_action_items:
  epic-1-retro:
    A1: pending
      category: dev
    A2: in-progress
      category: dev
  epic-2-retro:
    B1: pending
      category: dev
    B2: done
      category: dev
" "BLOCKING.*: 3"

# --- Fixture C: 块缺失 ---
run_test "block-missing" 1 "development_status:
  epic-1: done
" "block missing"

# --- Fixture D: 块存在但 0 项 (E4) ---
run_test "empty-block" 250 "development_status:
  epic-1: done
retro_action_items:
  epic-1-retro:
" "0 action items"

# --- Fixture E: 重复顶层 key (E6) ---
run_test "duplicate-header" 251 "development_status:
  epic-1: done
retro_action_items:
  epic-1-retro:
    A1: pending
      category: dev
retro_action_items:
  epic-2-retro:
    B1: pending
      category: dev
" "multiple retro_action_items"

# --- Fixture F: CRLF 行尾 (E1) ---
crlf_fixture="$(printf 'development_status:\r\n  epic-1: done\r\nretro_action_items:\r\n  epic-1-retro:\r\n    A1: pending\r\n      category: dev\r\n')"
run_test "crlf-tolerant" 1 "$crlf_fixture" "BLOCKING.*: 1"

# --- Fixture G: 未知 status (E3) ---
run_test "unknown-status-warn" 0 "development_status:
  epic-1: done
retro_action_items:
  epic-1-retro:
    A1: PENDING
      category: dev
    A2: done
      category: dev
    A3: pendng
      category: harness
" "WARN.*unrecognized status"

# --- Fixture H: flexible indent 6-space (E5) ---
# 注：6-space 缩进改成 indent 容错；category 子字段在更深一级
run_test "indent-6-space" 1 "development_status:
  epic-1: done
retro_action_items:
      epic-1-retro:
          A1: pending
            category: dev
" "BLOCKING.*: 1"

# --- Fixture I (v2): 仅 harness pending → 非阻断 ---
run_test "harness-pending-no-block" 0 "development_status:
  epic-1: done
retro_action_items:
  epic-1-retro:
    A1: pending
      category: harness
    A2: in-progress
      category: harness
" "non-blocking"

# --- Fixture J (v2): 混合 dev+harness pending → exit = dev count，但 stderr 都列 ---
run_test "mixed-pending-dev-and-harness" 1 "development_status:
  epic-1: done
retro_action_items:
  epic-1-retro:
    A1: pending
      category: dev
    A2: pending
      category: harness
    A3: in-progress
      category: harness
" "BLOCKING.*: 1"

# --- Fixture K (v2): pending 缺 category → NOCAT WARN，不阻 ---
run_test "pending-missing-category" 0 "development_status:
  epic-1: done
retro_action_items:
  epic-1-retro:
    A1: pending
" "missing / unrecognized category"

# --- Fixture L (v2): alphanumeric-dash code 兼容（C-bootstrap 类）---
run_test "alphanumeric-dash-code" 1 "development_status:
  epic-1: done
retro_action_items:
  epic-3-retro:
    C-bootstrap: pending
      category: dev
    C-cond-triggers: done
      category: harness
" "BLOCKING.*: 1"

echo
if [ "$failed" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi

echo "$failed test(s) failed." >&2
exit 1

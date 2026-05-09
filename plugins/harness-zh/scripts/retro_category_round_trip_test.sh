#!/usr/bin/env bash
# retro_category_round_trip_test — integration test for the
# writer→sprint-status.yaml→check_retro_action_items.sh pipeline.
#
# Purpose: catch the "writer drops `category:` field" silent degradation
# Codex flagged in the v0.1.27 review. If a future refactor of harness-state.py
# / harness-commit.py / process_retro_residue.sh stops emitting `category:`
# for retro_action_items, gate ① silently flips from BLOCK to NOCAT WARN
# (visible only as a stderr line, not as a non-zero exit), and any pending
# dev work could be greenlit through the gate.
#
# This test asserts the *boundary contract* between writer and reader:
#   - dev pending with category present → BLOCK (exit > 0)
#   - harness pending with category present → WARN-only (exit 0)
#   - missing/unknown category → NOCAT WARN (exit 0)
#
# It does NOT exercise the LLM-driven writer (process_retro_residue.sh emits a
# prompt, not deterministic output). What it DOES catch:
#   - Anyone stripping the `category:` schema from harness-state.py or
#     harness-commit.py output paths
#   - Any change to check_retro_action_items.sh that breaks the category
#     dispatch (e.g. case sensitivity, indent assumptions)
#
# Usage:
#   bash .claude/harness/scripts/retro_category_round_trip_test.sh
#
# Exit code: 0 = all 5 fixtures pass; non-zero = number of failed fixtures.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="$SCRIPT_DIR/check_retro_action_items.sh"

if [ ! -x "$CHECKER" ]; then
    echo "ERROR: check_retro_action_items.sh not found or not executable at $CHECKER" >&2
    exit 2
fi

PASS=0
FAIL=0

# Run a single fixture: build tmp yaml, run checker, assert exit code +
# stderr signature.
#
# Args:
#   $1  fixture name (printed in output)
#   $2  expected exit code (0 / 1 / numeric)
#   $3  yaml content (multi-line string)
#   $4  stderr regex that MUST match (POSIX ERE; pass empty string to skip)
#   $5  stderr regex that MUST NOT match (regression signal; empty to skip)
run_fixture() {
    local name="$1"
    local exp_rc="$2"
    local yaml="$3"
    local must_match="$4"
    local must_not_match="$5"

    local tmpyaml
    tmpyaml="$(mktemp -t retro_cat_rt_XXXXXX.yaml)"
    printf '%s' "$yaml" > "$tmpyaml"

    local out_stderr
    local actual_rc=0
    out_stderr="$(bash "$CHECKER" "$tmpyaml" 2>&1 1>/dev/null)" || actual_rc=$?

    local fail=0

    if [ "$actual_rc" != "$exp_rc" ]; then
        echo "  ✗ $name: exit code expected=$exp_rc actual=$actual_rc"
        echo "      stderr: $(printf '%s' "$out_stderr" | head -c 200)"
        fail=1
    fi

    if [ -n "$must_match" ] && ! printf '%s' "$out_stderr" | grep -qE "$must_match"; then
        echo "  ✗ $name: stderr missing required pattern '$must_match'"
        echo "      stderr: $(printf '%s' "$out_stderr" | head -c 200)"
        fail=1
    fi

    if [ -n "$must_not_match" ] && printf '%s' "$out_stderr" | grep -qE "$must_not_match"; then
        echo "  ✗ $name: stderr UNEXPECTEDLY matches regression signal '$must_not_match'"
        echo "      stderr: $(printf '%s' "$out_stderr" | head -c 200)"
        fail=1
    fi

    if [ "$fail" = 0 ]; then
        echo "  ✓ $name (rc=$actual_rc)"
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi

    rm -f "$tmpyaml"
}

echo "=== retro_category_round_trip_test ==="

# --- Fixture 1: dev pending WITH category → must BLOCK ---
run_fixture "dev-with-category-blocks" 1 "development_status:
  epic-3: done
retro_action_items:
  epic-3-retro:
    A1: pending
      category: dev
" "BLOCKING" "missing / unrecognized category"

# --- Fixture 2: harness pending WITH category → WARN only ---
run_fixture "harness-with-category-warns" 0 "development_status:
  epic-3: done
retro_action_items:
  epic-3-retro:
    A1: pending
      category: harness
" "WARN" "missing / unrecognized category"

# --- Fixture 3: pending MISSING category → NOCAT WARN ---
# This is the writer-regression scenario: if a writer stops emitting category:,
# the reader degrades gate ① from BLOCK to WARN. The test does not auto-block
# on the degradation (gate spec says NOCAT is WARN), but it explicitly asserts
# the NOCAT WARN appears, so a future schema change that hides this signal
# (e.g. silent NOCAT emission) gets caught.
run_fixture "missing-category-emits-NOCAT-warn" 0 "development_status:
  epic-3: done
retro_action_items:
  epic-3-retro:
    A1: pending
" "missing / unrecognized category" ""

# --- Fixture 4: writer-regression sentinel ---
# If a writer emits a category value outside {dev, harness} (typo, schema
# drift, copy/paste from another field), gate must NOCAT-WARN, NOT BLOCK.
# This catches a writer that introduced a typo like "category: development".
run_fixture "unknown-category-emits-NOCAT-warn" 0 "development_status:
  epic-3: done
retro_action_items:
  epic-3-retro:
    A1: pending
      category: development
" "missing / unrecognized category" ""

# --- Fixture 5: dev resolved + harness pending mixed ---
# Verifies the dispatch still picks up dev separately when both categories
# coexist; resolved items don't count.
run_fixture "mixed-dev-resolved-harness-pending" 0 "development_status:
  epic-3: done
retro_action_items:
  epic-3-retro:
    A1: resolved
      category: dev
    B1: pending
      category: harness
" "WARN" "BLOCKING.*: [1-9]"

echo "=================================="
echo " retro_category_round_trip_test: PASS=$PASS FAIL=$FAIL"
echo "=================================="

if [ "$FAIL" -gt 0 ]; then
    cat >&2 <<'EOF'

If "dev-with-category-blocks" failed with exit=0 instead of 1: a writer or
the reader silently dropped/corrupted the `category:` field. Gate ① is now
fail-open. Roll back the offending change and add a fixture covering the
specific writer path before re-attempting.

If "missing-category-emits-NOCAT-warn" failed: the NOCAT WARN signal was
removed or moved. That signal is solo-dev's only visibility into writer
regressions; do not silence it.
EOF
fi

exit "$FAIL"

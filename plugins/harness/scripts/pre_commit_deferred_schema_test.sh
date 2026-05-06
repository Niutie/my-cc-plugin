#!/usr/bin/env bash
# Self-test for pre-commit hook gate ② (deferred-work schema v1).
#
# Validates 4 fixture scenarios via temporary deferred-work.md mutation +
# `git add` + invoke installed pre-commit hook + restore. Fixtures are
# inert (FU-99.99.X namespace) so they cannot collide with real FU ids.
#
# Usage:
#   bash .claude/harness/scripts/pre_commit_deferred_schema_test.sh
#
# Exit code: 0 all pass / 1 any fail / 2 prerequisite missing

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/.git/hooks/pre-commit"
DW_REL="_bmad-output/implementation-artifacts/deferred-work.md"
DW_ABS="$REPO_ROOT/$DW_REL"

if [ ! -x "$HOOK" ]; then
    echo "ERROR: pre-commit hook not installed at $HOOK" >&2
    echo "       run: bash .claude/harness/scripts/install_git_hooks.sh" >&2
    exit 2
fi
if [ ! -f "$DW_ABS" ]; then
    echo "ERROR: $DW_REL missing" >&2
    exit 2
fi

cd "$REPO_ROOT"

PASS=0
FAIL=0

run_case() {
    local name="$1"
    local expected_exit="$2"
    local fixture_line="$3"

    cp "$DW_ABS" "$DW_ABS.bak"
    printf '\n%s\n' "$fixture_line" >> "$DW_ABS"
    git add "$DW_REL" 2>/dev/null

    local actual_exit=0
    bash "$HOOK" 2>/dev/null || actual_exit=$?

    git restore --staged "$DW_REL" 2>/dev/null
    mv "$DW_ABS.bak" "$DW_ABS"

    if [ "$actual_exit" = "$expected_exit" ]; then
        echo "  ✓ [$name] exit=$actual_exit (expected $expected_exit)"
        PASS=$((PASS + 1))
    else
        echo "  ✗ [$name] exit=$actual_exit (expected $expected_exit) — FAIL"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== pre-commit gate ② (deferred-work schema v1) self-test ==="

# fixture 1: legal schema v1 bullet — should pass
run_case "legal-4tag" 0 '- **FU-99.99.X** `[status:pending]` `[bucket:other]` `[target:N/A]` `[source:dev-of-99.99]` — self-test legal fixture'

# fixture 2: missing 4-tag head — should fail
run_case "missing-tags" 1 '- **FU-99.99.Y — missing tag head**'

# fixture 3: legacy inline suffix — should fail
run_case "legacy-inline-resolved" 1 '- **FU-99.99.Z** `[status:resolved]` `[bucket:other]` `[target:N/A]` `[source:dev-of-99.99]` — desc — **Resolved by Story 9.9** (2026-05-04): legacy inline suffix should be rejected'

# fixture 4: FU-RETRO-* namespace — should fail
run_case "fu-retro-namespace" 1 '- **FU-RETRO-9.99** `[status:pending]` `[bucket:other]` `[target:N/A]` `[source:dev-of-99.99]` — retro mirror should be rejected'

echo ""
echo "Result: PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" = 0 ] && exit 0 || exit 1

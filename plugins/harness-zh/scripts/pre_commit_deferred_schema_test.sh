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
# Worktree-aware hooks dir: in the main checkout this resolves to .git/hooks/pre-commit;
# in a worktree it resolves to .git/worktrees/<name>/hooks/pre-commit (where install_git_hooks.sh
# actually places the hook). Hardcoding $REPO_ROOT/.git/hooks would mis-locate it under a worktree.
HOOK="$(git rev-parse --git-path hooks/pre-commit)"
case "$HOOK" in
    /*) ;;  # already absolute
    *)  HOOK="$REPO_ROOT/$HOOK" ;;
esac
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

# v0.1.20 — gate ② sub-check (d): target value enumeration

# fixture 5: bad target — story-key drift `1-7-全名` style — should fail
run_case "bad-target-story-key-drift" 1 '- **FU-99.99.D1** `[status:pending]` `[bucket:other]` `[target:1-7-单机一键启动]` `[source:dev-of-99.99]` — story-key drift should be rejected'

# fixture 6: legit Story X.Y short form — should pass
run_case "legit-target-story-short" 0 '- **FU-99.99.D2** `[status:pending]` `[bucket:other]` `[target:Story 9.9]` `[source:dev-of-99.99]` — Story X.Y legit'

# fixture 7: legit Epic phrase form — should pass
run_case "legit-target-epic-phrase" 0 '- **FU-99.99.D3** `[status:pending]` `[bucket:other]` `[target:Epic 6 production lockdown]` `[source:dev-of-99.99]` — Epic phrase legit'

# fixture 8: legit v-phase target — should pass
run_case "legit-target-v-phase" 0 '- **FU-99.99.D4** `[status:pending]` `[bucket:other]` `[target:v0.2+ customer-feedback]` `[source:dev-of-99.99]` — v-phase legit'

# fixture 9: legit customer-feedback (phase-agnostic) — should pass
run_case "legit-target-customer-feedback" 0 '- **FU-99.99.D5** `[status:pending]` `[bucket:other]` `[target:customer-feedback]` `[source:dev-of-99.99]` — customer-feedback legit'

# fixture 10: bad target — random text — should fail
run_case "bad-target-random-text" 1 '- **FU-99.99.D6** `[status:pending]` `[bucket:other]` `[target:future-work]` `[source:dev-of-99.99]` — non-enum value rejected'

echo ""
echo "Result: PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" = 0 ] && exit 0 || exit 1

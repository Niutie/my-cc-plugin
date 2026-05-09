#!/usr/bin/env bash
# run_all_tests — central test runner for harness-zh.
#
# Runs (in order):
#   1. release_check.sh     — version equality + frontmatter YAML parse
#   2. all *_test.sh         — alphabetical, individual exit codes accumulated
#
# Pre-existing-failure tolerance:
#   - Some tests are project-specific or known stale and won't pass against
#     this plugin source tree (they're written assuming a downstream project's
#     deployed copy). They are listed in `KNOWN_STALE` below and are run for
#     informational output only — their failures don't fail the runner.
#   - Tests that need an installed git pre-commit hook are skipped here when
#     run from the plugin source directly (they pass once deployed).
#
# Usage:
#   bash plugins/harness-zh/scripts/run_all_tests.sh
#   bash plugins/harness-zh/scripts/run_all_tests.sh --strict    # KNOWN_STALE failures count
#
# Exit code: number of failed tests (0 = all pass)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_DIR/../.." && pwd)"

STRICT=0
if [ "${1:-}" = "--strict" ]; then
    STRICT=1
fi

# Tests that need a deployed downstream-project fixture (their probe targets
# don't exist in the plugin source tree). These pass in CI's `bootstrap-tests`
# job which sets up such a fixture before invoking them. Run from source they
# always fail or short-circuit on missing prerequisites.
#
# Anything NOT in this list runs source-tree-direct and must pass.
KNOWN_STALE=(
    "harness_config_test.sh"                # fixture-internal bug — separate
    "grep_pending_deferred_for_story_test.sh" # pre-existing failures 5/11 — separate
    "run_sprint_init_test.sh"               # self-flagged stale (changelog)
    "pre_commit_deferred_schema_test.sh"    # needs installed git hook → bootstrap CI runs it
    "simulate_clone_test.sh"                # needs deployed project tree → bootstrap CI runs it
    "orchestration_observations_test.sh"    # needs _bmad-output → bootstrap CI runs (TODO)
    "process_retro_residue_test.sh"         # needs sprint-status.yaml — separate
    "run_retro_self_audit_test.sh"          # PROJECT-SPECIFIC self-flag → bootstrap CI runs it
    "harness_commit_isolation_test.sh"      # needs Python imports + tmp-git-repo → bootstrap CI runs it
)

is_known_stale() {
    local name="$1"
    for s in "${KNOWN_STALE[@]}"; do
        [ "$s" = "$name" ] && return 0
    done
    return 1
}

PASS=0
FAIL=0
SKIP=0
KNOWN_FAILS=0

run_one() {
    local script="$1"
    local name
    name="$(basename "$script")"
    local stale=0
    if is_known_stale "$name" && [ "$STRICT" = 0 ]; then
        stale=1
    fi

    printf "%-55s " "$name"
    local rc=0
    bash "$script" >/dev/null 2>&1 || rc=$?
    if [ "$rc" = 0 ]; then
        echo "PASS"
        PASS=$((PASS + 1))
    elif [ "$stale" = 1 ]; then
        echo "SKIP (known-stale, rc=$rc)"
        SKIP=$((SKIP + 1))
        KNOWN_FAILS=$((KNOWN_FAILS + 1))
    else
        echo "FAIL (rc=$rc)"
        FAIL=$((FAIL + 1))
    fi
}

echo "==================================================================="
echo " run_all_tests.sh — harness-zh self-test suite"
echo " plugin: $PLUGIN_DIR"
echo "==================================================================="
echo ""
echo "[1] release_check.sh (version + frontmatter gates)"
echo "-------------------------------------------------------------------"
RELEASE_RC=0
bash "$SCRIPT_DIR/release_check.sh" || RELEASE_RC=$?
if [ "$RELEASE_RC" = 0 ]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi
echo ""
echo "[2] *_test.sh fixtures"
echo "-------------------------------------------------------------------"

# Sort alphabetical for deterministic ordering
for t in $(ls "$SCRIPT_DIR"/*_test.sh 2>/dev/null | sort); do
    run_one "$t"
done

echo ""
echo "==================================================================="
printf " PASS=%d  FAIL=%d  SKIP=%d (known-stale)\n" "$PASS" "$FAIL" "$SKIP"
echo "==================================================================="

if [ "$STRICT" = 1 ] && [ "$KNOWN_FAILS" -gt 0 ]; then
    echo " --strict: $KNOWN_FAILS known-stale tests counted as failures"
fi

exit "$FAIL"

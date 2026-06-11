#!/usr/bin/env bash
# run_all_tests — central test runner for harness-zh.
#
# Runs (in order):
#   1. release_check.sh     — version equality + frontmatter YAML parse
#   2. all *_test.sh         — alphabetical, individual exit codes accumulated
#
# Known-stale tolerance:
#   - Tests in `KNOWN_STALE` below cannot pass against the plugin source tree
#     BY DESIGN (each entry's comment states the reason and the exact ci.yml
#     job/step that gates it instead). Outside --strict their failures are
#     downgraded to SKIP; with --strict they count as FAIL.
#   - A stale-listed test that PASSES is flagged "remove from KNOWN_STALE"
#     (review #44: a green test left on this list would have any future
#     regression silently swallowed as SKIP).
#   - On FAIL the runner prints the tail of the test's output (review #44:
#     previously all output went to /dev/null — zero diagnostics in CI).
#
# Usage:
#   bash plugins/harness-zh/scripts/run_all_tests.sh
#   bash plugins/harness-zh/scripts/run_all_tests.sh --strict    # KNOWN_STALE failures count
#
# Exit code: number of failed tests (0 = all pass)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

STRICT=0
if [ "${1:-}" = "--strict" ]; then
    STRICT=1
fi

# Tests that CANNOT pass from the plugin source tree by design. Every entry
# MUST name the ci.yml job + step that actually gates it — blanket "CI runs
# it" claims here were previously false for 5 of 9 entries (review #10/#40);
# keep this list honest, minimal, and individually re-verified.
#
# Re-verified 2026-06-10 by running each former entry standalone from the
# source tree: harness_config / grep_pending_deferred_for_story /
# run_sprint_init / pre_commit_deferred_schema / orchestration_observations /
# process_retro_residue / run_retro_self_audit / harness_commit_isolation are
# all rc=0 source-tree-direct after the test-lane rewrites → removed (they now
# gate in the `source-tests` job like every other test).
#
# Anything NOT in this list runs source-tree-direct and must pass.
KNOWN_STALE=(
    # Clones the host repo's deployed .claude/ tree — that IS its test
    # subject, so it can never pass from the bare plugin source. Gated by
    # ci.yml `bootstrap-tests` job, step "Run deployed *_test.sh suite
    # inside fixture" (runs the deployed copy inside the bootstrap fixture).
    "simulate_clone_test.sh"
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
STALE_PASSES=0

# Per-test output capture (review #44: `>/dev/null 2>&1` left CI with zero
# diagnostics on FAIL). Logs live in one mktemp sandbox, cleaned on EXIT.
LOG_DIR="$(mktemp -d -t run_all_tests_logs.XXXXXX)"
trap 'rm -rf "$LOG_DIR"' EXIT

run_one() {
    local script="$1"
    local name
    name="$(basename "$script")"
    # review #54：known-stale 判定与 strict 解耦——无论 STRICT 与否都算出
    # stale；strict 模式下 known-stale 失败计入 FAIL 的同时也累加 KNOWN_FAILS，
    # 让末尾的 "--strict: N known-stale ..." 汇总可达（此前两条件互斥恒不打印）。
    local stale=0
    if is_known_stale "$name"; then
        stale=1
    fi

    printf "%-55s " "$name"
    local log="$LOG_DIR/$name.log"
    local rc=0
    bash "$script" >"$log" 2>&1 || rc=$?
    if [ "$rc" = 0 ]; then
        if [ "$stale" = 1 ]; then
            # review #44: list rot — a passing test on the stale list means
            # any future regression degrades PASS→SKIP invisibly.
            echo "PASS (stale-listed — remove from KNOWN_STALE)"
            STALE_PASSES=$((STALE_PASSES + 1))
        else
            echo "PASS"
        fi
        PASS=$((PASS + 1))
    elif [ "$stale" = 1 ] && [ "$STRICT" = 0 ]; then
        echo "SKIP (known-stale, rc=$rc)"
        SKIP=$((SKIP + 1))
        KNOWN_FAILS=$((KNOWN_FAILS + 1))
    elif [ "$stale" = 1 ]; then
        echo "FAIL (rc=$rc, known-stale)"
        FAIL=$((FAIL + 1))
        KNOWN_FAILS=$((KNOWN_FAILS + 1))
        dump_log_tail "$name" "$log"
    else
        echo "FAIL (rc=$rc)"
        FAIL=$((FAIL + 1))
        dump_log_tail "$name" "$log"
    fi
}

dump_log_tail() {
    local name="$1" log="$2"
    echo "  ---- last 25 lines of $name output ----"
    tail -n 25 "$log" | sed 's/^/  | /'
    echo "  ---------------------------------------"
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

# Glob 展开本身按 locale 排序、天然保空格/CJK 路径（review #21：原 ls|sort
# 命令替换按 IFS 分词，部署到含空格路径的项目时每条路径碎成多段全 FAIL）。
# 无命中时 glob 保留字面 pattern，由 -f 守卫跳过。
for t in "$SCRIPT_DIR"/*_test.sh; do
    [ -f "$t" ] || continue
    run_one "$t"
done

echo ""
echo "==================================================================="
printf " PASS=%d  FAIL=%d  SKIP=%d (known-stale)\n" "$PASS" "$FAIL" "$SKIP"
echo "==================================================================="

if [ "$STRICT" = 1 ] && [ "$KNOWN_FAILS" -gt 0 ]; then
    echo " --strict: $KNOWN_FAILS known-stale tests counted as failures"
fi
if [ "$STALE_PASSES" -gt 0 ]; then
    echo " NOTE: $STALE_PASSES KNOWN_STALE test(s) passed — prune the list (review #44)"
fi

exit "$FAIL"

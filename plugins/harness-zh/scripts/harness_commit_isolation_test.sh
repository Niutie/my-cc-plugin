#!/usr/bin/env bash
# Self-test for harness-commit.py F1 (test_artifact key-prefix enforcement)
# + F2 (worktree-clean check on stages 5-5/T1/T3/T4).
#
# 6 fixture（与 chore-harness-codex-review-fixes-2026-05-04 spec Q4 锁定）：
#   F1-1 合法 key prefix 通过       — KEY=A，commit test_artifacts/A.atdd-checklist.md
#   F1-2 错 key prefix halt         — KEY=A，commit test_artifacts/B.atdd-checklist.md
#   F2-1 stage 5-5 clean 通过       — KEY=A，仅白名单内路径有改动
#   F2-2 stage 5-5 dirty halt       — KEY=A，console-api/internal/foo.go 也有改动
#   边界 F1-3 epic prefix 合法      — EPIC=4，commit test_artifacts/epic-4-test-design.md
#   边界 F2-3 e2e spec 通过         — KEY=A，console-web/tests/e2e/A.spec.ts 改动
#
# review 2026-06-10 #10：HARNESS_PY 此前指向部署副本
# $REPO_ROOT/.claude/harness/scripts/ — 源树跑不了、CI bootstrap 之外零覆盖。
# 改为 $SCRIPT_DIR 同目录文件：源树布局（plugins/harness-zh/scripts/）和部署
# 布局（.claude/harness/scripts/）里 harness-commit.py 都与本测试同目录，两边
# 通跑。fixture 全是 mktemp git repo + --dry-run，无任何部署依赖。
#
# 整脚本退出码 = 失败 fixture 数（0 = 全过）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_PY="$SCRIPT_DIR/harness-commit.py"

if [ ! -f "$HARNESS_PY" ]; then
    echo "ERROR: harness-commit.py not found at $HARNESS_PY" >&2
    exit 1
fi

PASS=0
FAIL=0

# All fixture repos live under one mktemp sandbox, cleaned by EXIT trap
# (NOT RETURN trap — never fires at top level; review #94 bug class).
WORKDIR="$(mktemp -d -t harness_isolation_test.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

# ---- helpers ----
init_fixture_repo() {
    # Creates a temp git repo, returns its path on stdout. Caller cd's into it.
    #
    # We pre-track the artifact / test / source parent dirs with .gitkeep
    # placeholders so subsequent untracked files inside them appear as
    # individual `?? path/file` lines in `git status --porcelain` instead
    # of collapsing to `?? dir/` (the default `--untracked-files=normal`
    # behavior on un-tracked dirs). harness-commit.py now passes -uall, but
    # the pre-tracked layout also keeps fixture diffs minimal.
    local dir
    dir="$(mktemp -d "$WORKDIR/harness_isolation.XXXXXX")"
    (
        cd "$dir"
        git init -q
        git config user.email "test@example.com"
        git config user.name "test"
        git config commit.gpgsign false
        mkdir -p _bmad-output/implementation-artifacts/test_artifacts
        mkdir -p console-web/tests/e2e
        mkdir -p console-api/internal/audit
        touch _bmad-output/implementation-artifacts/.gitkeep
        touch _bmad-output/implementation-artifacts/test_artifacts/.gitkeep
        touch console-web/tests/e2e/.gitkeep
        touch console-api/internal/audit/.gitkeep
        git add -A
        git commit -q -m "seed"
    )
    echo "$dir"
}

run_harness() {
    # $1 = repo dir, $2 = stage, $3 = key, [$4 = epic]
    local dir="$1" stage="$2" key="$3" epic="${4:-}"
    local extra=""
    if [ -n "$epic" ]; then
        extra="--epic $epic"
    fi
    (
        cd "$dir"
        # --dry-run so the script doesn't actually run `git add` and pollute
        # the index — we only want to assert the gate behavior.
        python3 "$HARNESS_PY" "$stage" "$key" $extra --dry-run 2>&1
    )
}

assert_exit_and_keyword() {
    # $1 = label, $2 = output, $3 = exit, $4 = expected exit, $5 = expected keyword
    local label="$1" out="$2" rc="$3" want_rc="$4" want_kw="$5"
    if [ "$rc" != "$want_rc" ]; then
        echo "  ✗ $label — exit $rc, wanted $want_rc" >&2
        echo "    out: $out" >&2
        FAIL=$((FAIL+1))
        return 1
    fi
    if [ -n "$want_kw" ] && ! echo "$out" | grep -q "$want_kw"; then
        echo "  ✗ $label — output missing keyword '$want_kw'" >&2
        echo "    out: $out" >&2
        FAIL=$((FAIL+1))
        return 1
    fi
    echo "  ✓ $label"
    PASS=$((PASS+1))
    return 0
}

# ============================================================================
# F1-1: 合法 key prefix 通过（KEY=story-a）
# ============================================================================
fixture_1_1() {
    local dir
    dir="$(init_fixture_repo)"
    echo "atdd checklist body" > "$dir/_bmad-output/implementation-artifacts/test_artifacts/story-a.atdd-checklist.md"
    # global file change so stage isn't empty after artifact validation
    echo "test:" > "$dir/_bmad-output/implementation-artifacts/sprint-status.yaml"

    local out rc
    set +e
    out="$(run_harness "$dir" "T3" "story-a")"
    rc=$?
    set -e
    assert_exit_and_keyword "F1-1 legal key prefix passes" "$out" "$rc" "0" "STATUS=ok"
    rm -rf "$dir"
}

# ============================================================================
# F1-2: 错 key prefix halt（KEY=story-a, 文件名 story-b.*）
# ============================================================================
fixture_1_2() {
    local dir
    dir="$(init_fixture_repo)"
    echo "atdd checklist body" > "$dir/_bmad-output/implementation-artifacts/test_artifacts/story-b.atdd-checklist.md"
    echo "test:" > "$dir/_bmad-output/implementation-artifacts/sprint-status.yaml"

    local out rc
    set +e
    out="$(run_harness "$dir" "T3" "story-a")"
    rc=$?
    set -e
    assert_exit_and_keyword "F1-2 wrong key prefix halts (CROSS_STORY)" "$out" "$rc" "1" "CROSS_STORY=_bmad-output/implementation-artifacts/test_artifacts/story-b"
    rm -rf "$dir"
}

# ============================================================================
# F2-1: stage 5-5 clean (test_artifacts + sprint-status only, no extras)
# ============================================================================
fixture_2_1() {
    local dir
    dir="$(init_fixture_repo)"
    echo "result" > "$dir/_bmad-output/implementation-artifacts/test_artifacts/story-a-test-result.json"
    echo "checklist" > "$dir/_bmad-output/implementation-artifacts/test_artifacts/story-a.atdd-checklist.md"
    echo "test:" > "$dir/_bmad-output/implementation-artifacts/sprint-status.yaml"

    local out rc
    set +e
    out="$(run_harness "$dir" "5-5" "story-a")"
    rc=$?
    set -e
    assert_exit_and_keyword "F2-1 stage 5-5 clean worktree passes" "$out" "$rc" "0" "STATUS=ok"
    rm -rf "$dir"
}

# ============================================================================
# F2-2: stage 5-5 dirty (一个白名单外的项目代码文件存在)
# ============================================================================
fixture_2_2() {
    local dir
    dir="$(init_fixture_repo)"
    echo "checklist" > "$dir/_bmad-output/implementation-artifacts/test_artifacts/story-a.atdd-checklist.md"
    echo "test:" > "$dir/_bmad-output/implementation-artifacts/sprint-status.yaml"
    # The unrelated dirty path that should trigger F2 halt:
    echo "package audit" > "$dir/console-api/internal/audit/foo.go"

    local out rc
    set +e
    out="$(run_harness "$dir" "5-5" "story-a")"
    rc=$?
    set -e
    assert_exit_and_keyword "F2-2 stage 5-5 dirty worktree halts (DIRTY_WORKTREE)" "$out" "$rc" "1" "DIRTY_WORKTREE=console-api/internal/audit/foo.go"
    rm -rf "$dir"
}

# ============================================================================
# F1-3 边界: epic prefix 合法 (EPIC=4 → epic-4-test-design.md 通过)
# ============================================================================
fixture_1_3() {
    local dir
    dir="$(init_fixture_repo)"
    echo "test design" > "$dir/_bmad-output/implementation-artifacts/test_artifacts/epic-4-test-design.md"
    echo "test:" > "$dir/_bmad-output/implementation-artifacts/sprint-status.yaml"

    local out rc
    set +e
    out="$(run_harness "$dir" "T1" "any-key" "4")"
    rc=$?
    set -e
    assert_exit_and_keyword "F1-3 epic-N test-design passes (EPIC arg validates)" "$out" "$rc" "0" "STATUS=ok"
    rm -rf "$dir"
}

# ============================================================================
# F2-3 边界: e2e spec 路径在白名单 (console-web/tests/e2e/<key>* 通过)
# ============================================================================
fixture_2_3() {
    local dir
    dir="$(init_fixture_repo)"
    echo "checklist" > "$dir/_bmad-output/implementation-artifacts/test_artifacts/story-a.atdd-checklist.md"
    echo "import { test } from '@playwright/test';" > "$dir/console-web/tests/e2e/story-a.spec.ts"
    echo "test:" > "$dir/_bmad-output/implementation-artifacts/sprint-status.yaml"

    local out rc
    set +e
    out="$(run_harness "$dir" "T4" "story-a")"
    rc=$?
    set -e
    assert_exit_and_keyword "F2-3 e2e spec for KEY in whitelist passes" "$out" "$rc" "0" "STATUS=ok"
    rm -rf "$dir"
}

# ============================================================================
echo "harness_commit_isolation_test — 6 fixture（F1+F2 codex review 修复）"
echo "============================================================================"

fixture_1_1
fixture_1_2
fixture_1_3
fixture_2_1
fixture_2_2
fixture_2_3

echo "============================================================================"
echo "PASS=$PASS FAIL=$FAIL"
exit $FAIL

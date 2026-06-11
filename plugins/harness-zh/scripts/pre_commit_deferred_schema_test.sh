#!/usr/bin/env bash
# Self-test for pre-commit hook gate ② (deferred-work schema v1).
#
# review 2026-06-10 #10：此前依赖「当前 repo 已装 hook + 真实 deferred-work.md」
# （还会临时改写真仓库的 deferred-work.md + index）。现改为自举 mktemp 沙箱
# git repo：从同源树拷 git-hooks/pre-commit + scripts/deferred_work_schema_lib.sh
# （源树布局 plugins/harness-zh/{scripts,git-hooks} 与部署布局
# .claude/harness/{scripts,git-hooks} 相对结构一致，两边通跑），种子
# deferred-work.md 后逐 fixture 验证 — 不再触碰宿主仓库任何文件。
#
# Fixtures are inert (FU-99.99.X namespace) so they cannot collide with real
# FU ids. 新增（Phase A 行为）：
#   - deletion-only diff 不再触发 pipefail 静默 exit 1（review #2 修复）
#   - lib 缺失时 hook 内联 fallback regex 仍然有效（legal 放行 + 违规拦截）
#
# Usage:
#   bash plugins/harness-zh/scripts/pre_commit_deferred_schema_test.sh   # 源树
#   bash .claude/harness/scripts/pre_commit_deferred_schema_test.sh     # 部署树
#
# Exit code: 0 all pass / 1 any fail / 2 prerequisite missing

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SRC="$SCRIPT_DIR/../git-hooks/pre-commit"
LIB_SRC="$SCRIPT_DIR/deferred_work_schema_lib.sh"

if [ ! -f "$HOOK_SRC" ]; then
    echo "ERROR: pre-commit hook source missing at $HOOK_SRC" >&2
    exit 2
fi
if [ ! -f "$LIB_SRC" ]; then
    echo "ERROR: deferred_work_schema_lib.sh missing at $LIB_SRC" >&2
    exit 2
fi

# ---- self-bootstrapped sandbox fixture repo (EXIT trap cleanup) ----
WORKDIR="$(mktemp -d -t pre_commit_schema_test.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

FIXTURE="$WORKDIR/repo"
DW_REL="_bmad-output/implementation-artifacts/deferred-work.md"
mkdir -p "$FIXTURE"
(
    cd "$FIXTURE"
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    git config commit.gpgsign false
    mkdir -p .claude/harness/scripts
    mkdir -p _bmad-output/implementation-artifacts
    cp "$LIB_SRC" .claude/harness/scripts/deferred_work_schema_lib.sh
    cat > "$DW_REL" <<'EOF'
# Deferred Work — pre_commit_deferred_schema_test fixture

- **FU-99.99.SEED** `[status:pending]` `[bucket:other]` `[target:N/A]` `[source:dev-of-99.99]` — seeded line for the deletion-only-diff case
EOF
    git add -A
    git commit -q -m "fixture init"
    mkdir -p .git/hooks
    cp "$HOOK_SRC" .git/hooks/pre-commit
    chmod +x .git/hooks/pre-commit
)

HOOK="$FIXTURE/.git/hooks/pre-commit"
DW_ABS="$FIXTURE/$DW_REL"

cd "$FIXTURE"

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
echo "    sandbox: $FIXTURE"

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

# ============================================================================
# fixture 11 (Phase A review #2): deletion-only diff — 纯删除 FU 行（清理/
# 归档场景）不得触发 pipefail 静默 exit 1 阻断 commit
# ============================================================================
cp "$DW_ABS" "$DW_ABS.bak"
grep -vF 'FU-99.99.SEED' "$DW_ABS" > "$DW_ABS.tmp" && mv "$DW_ABS.tmp" "$DW_ABS"
git add "$DW_REL" 2>/dev/null
del_exit=0
bash "$HOOK" 2>/dev/null || del_exit=$?
git restore --staged "$DW_REL" 2>/dev/null
mv "$DW_ABS.bak" "$DW_ABS"
if [ "$del_exit" = "0" ]; then
    echo "  ✓ [deletion-only-diff] exit=0 (纯删除 diff 放行，无 pipefail 静默崩)"
    PASS=$((PASS + 1))
else
    echo "  ✗ [deletion-only-diff] exit=$del_exit (expected 0) — FAIL（review #2 回归）"
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# fixture 12/13: schema lib 缺失 → hook 内联 fallback regex 路径
# （部分部署 skew 防御；同时回归 2026-05-09 的 ${VAR:-default} `{4}` 截断 bug）
# ============================================================================
rm -f "$FIXTURE/.claude/harness/scripts/deferred_work_schema_lib.sh"
run_case "fallback-legal-4tag (lib absent)" 0 '- **FU-99.99.F1** `[status:pending]` `[bucket:other]` `[target:N/A]` `[source:dev-of-99.99]` — inline fallback legal fixture'
run_case "fallback-missing-tags (lib absent)" 1 '- **FU-99.99.F2 — missing tag head, lib absent**'
cp "$LIB_SRC" "$FIXTURE/.claude/harness/scripts/deferred_work_schema_lib.sh"

echo ""
echo "Result: PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" = 0 ] && exit 0 || exit 1

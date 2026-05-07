#!/usr/bin/env bash
# Self-test for lint_deferred_work.sh — schema v1 violation detection
#
# 6 fixtures：legit baseline / 5 类 violation 各一条。
# Exit code = failed fixtures (0 = all pass).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/lint_deferred_work.sh"

if [ ! -x "$LINT" ]; then
    echo "ERROR: lint_deferred_work.sh not executable at $LINT" >&2
    exit 2
fi

PASS=0
FAIL=0
WORKDIR="$(mktemp -d -t lint-dw-test.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

run_fixture() {
    local name="$1"
    local expected_exit="$2"
    local expected_grep="$3"   # 期望 stdout 含的子串（"" = 跳过 stdout 检查）
    local md_content="$4"

    local md_path="$WORKDIR/$name.md"
    printf '%s\n' "$md_content" > "$md_path"

    local actual_exit=0
    local stdout
    stdout="$(bash "$LINT" "$md_path" 2>/dev/null)" || actual_exit=$?

    local pass_exit=0
    local pass_grep=0
    [ "$actual_exit" = "$expected_exit" ] && pass_exit=1
    if [ -z "$expected_grep" ]; then
        pass_grep=1
    elif printf '%s' "$stdout" | grep -qF "$expected_grep"; then
        pass_grep=1
    fi

    if [ "$pass_exit" = 1 ] && [ "$pass_grep" = 1 ]; then
        echo "  ✓ [$name] exit=$actual_exit"
        PASS=$((PASS + 1))
    else
        echo "  ✗ [$name] exit=$actual_exit (expected $expected_exit), stdout grep '$expected_grep' = ${pass_grep}" >&2
        printf '   stdout: %s\n' "$stdout" >&2
        FAIL=$((FAIL + 1))
    fi
}

echo "=== lint_deferred_work.sh self-test ==="

# F1: 全合规 — exit 0
run_fixture "f1-all-legit" 0 "" '# DW

- **FU-1.4.A** `[status:pending]` `[bucket:cross-story]` `[target:Story 1.7]` `[source:dev-of-1.4]` — legit
- **FU-1.4.B** `[status:resolved]` `[bucket:other]` `[target:N/A]` `[source:dev-of-1.4]` — legit
- **FU-1.4.C** `[status:partial]` `[bucket:other]` `[target:Epic 6 retro]` `[source:dev-of-1.4]` — legit
- **FU-1.4.D** `[status:needs-review]` `[bucket:sandbox]` `[target:v0.2+ customer-feedback]` `[source:dev-of-1.4]` — legit
- **FU-1.4.E** `[status:pending]` `[bucket:cross-story]` `[target:Story 1.11.A]` `[source:dev-of-1.4]` — legit (sub-letter)
- **FU-1.4.F** `[status:pending]` `[bucket:other]` `[target:customer-feedback]` `[source:dev-of-1.4]` — legit'

# F2: bad target (story-key drift) — exit 1
run_fixture "f2-bad-target-drift" 1 "b-bad-target:[target:1-7-单机一键启动]" '# DW

- **FU-1.4.A** `[status:pending]` `[bucket:cross-story]` `[target:1-7-单机一键启动]` `[source:dev-of-1.4]` — drift'

# F3: missing 4-tag head — exit 1
run_fixture "f3-missing-tags" 1 "a-missing-4tag-head" '# DW

- **FU-1.4.A** missing tag head'

# F4: FU-RETRO namespace — exit 1
run_fixture "f4-fu-retro" 1 "c-fu-retro-namespace" '# DW

- **FU-RETRO-1.A** `[status:pending]` `[bucket:other]` `[target:Story 1.7]` `[source:epic-1-retro]` — wrong namespace'

# F5: legacy inline suffix — exit 1
run_fixture "f5-legacy-inline" 1 "d-legacy-inline-suffix" '# DW

- **FU-1.4.A** `[status:resolved]` `[bucket:other]` `[target:Story 1.7]` `[source:dev-of-1.4]` — desc — **Resolved by Story 1.7** (2026-05-01): legacy'

# F6: bad status enum — exit 1
run_fixture "f6-bad-status" 1 "e-bad-status:[status:made-up]" '# DW

- **FU-1.4.A** `[status:made-up]` `[bucket:other]` `[target:Story 1.7]` `[source:dev-of-1.4]` — bad status'

# F7: 多类 violations 同时 — exit 4 (b + c + e + a)
run_fixture "f7-mixed-4" 4 "" '# DW

- **FU-1.4.A** `[status:pending]` `[bucket:other]` `[target:Story 1.7]` `[source:dev-of-1.4]` — legit
- **FU-1.4.B** `[status:pending]` `[bucket:other]` `[target:1-7-drift]` `[source:dev-of-1.4]` — bad target
- **FU-1.4.C** `[status:made-up]` `[bucket:other]` `[target:Story 1.7]` `[source:dev-of-1.4]` — bad status
- **FU-RETRO-1.A** `[status:pending]` `[bucket:other]` `[target:Story 1.7]` `[source:epic-1-retro]` — retro
- **FU-1.4.D** missing tags'

# F8: Epic phrase variants（schema §3.3 显式列）— 全合规 exit 0
run_fixture "f8-epic-phrases" 0 "" '# DW

- **FU-1.A** `[status:pending]` `[bucket:other]` `[target:Epic 6]` `[source:dev-of-1.4]` — legit Epic
- **FU-1.B** `[status:pending]` `[bucket:other]` `[target:Epic 6 retro]` `[source:dev-of-1.4]` — legit Epic retro
- **FU-1.C** `[status:pending]` `[bucket:other]` `[target:Epic 6 production lockdown]` `[source:dev-of-1.4]` — legit Epic phrase'

echo ""
echo "============================================================================"
echo "PASS=$PASS FAIL=$FAIL"
exit "$FAIL"

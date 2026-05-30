#!/bin/bash
# Self-test for harness-commit.py issue #5 fixes (v0.1.35):
#
#   I1 — _epic_letter() supports epic > 26 via bijective base-26
#        (27→AA, 52→AZ, 53→BA), backward-compatible for epic ≤ 26.
#   I2 — credentials BLACKLIST no longer false-positives on i18n locale
#        JSON files named `*-credentials.json` (real secret files still blocked).
#   I3 — files under _bmad-output/ but outside implementation-artifacts/
#        (e.g. brainstorming/, planning-artifacts/) halt with OUT_OF_SCOPE_BMAD
#        instead of being silently swept into the story commit.
#
# Runs against the PLUGIN SOURCE harness-commit.py directly (no deployed
# .claude/harness/ needed) via tmp git repos + --dry-run, so it passes in the
# source tree (like retro_fulfill_stage_test.sh, unlike
# harness_commit_isolation_test.sh which needs a deployed copy).
#
# 整脚本退出码 = 失败 fixture 数（0 = 全过）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_PY="$SCRIPT_DIR/harness-commit.py"

if [ ! -f "$HARNESS_PY" ]; then
    echo "ERROR: harness-commit.py not found at $HARNESS_PY" >&2
    exit 1
fi

failed=0

# Pre-track parent dirs with .gitkeep so subsequent untracked files appear as
# individual `?? path/file` lines in `git status --porcelain` instead of
# collapsing to `?? dir/` (harness-commit.py uses bare porcelain).
seed_repo() {
    local dir
    dir="$(mktemp -d -t hc_issue5.XXXXXX)"
    (
        cd "$dir"
        git init -q
        git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
        mkdir -p _bmad-output/implementation-artifacts
        mkdir -p _bmad-output/brainstorming
        mkdir -p web/src/i18n/locales/zh-CN
        mkdir -p infra
        touch _bmad-output/implementation-artifacts/.gitkeep
        touch _bmad-output/brainstorming/.gitkeep
        touch web/src/i18n/locales/zh-CN/.gitkeep
        touch infra/.gitkeep
        printf 'development_status:\n  9-9-story: backlog\n' \
            > _bmad-output/implementation-artifacts/sprint-status.yaml
        printf '# deferred\n' \
            > _bmad-output/implementation-artifacts/deferred-work.md
        git add -A; git commit -q -m seed
    )
    echo "$dir"
}

# ============================================================================
# I1 — _epic_letter bijective base-26 (pure-function unit check via importlib)
# ============================================================================
i1_out="$(python3 - "$HARNESS_PY" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("hc", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
want = {1:"A", 26:"Z", 27:"AA", 52:"AZ", 53:"BA", 702:"ZZ", 703:"AAA"}
bad = [(n, m._epic_letter(n), w) for n, w in want.items() if m._epic_letter(n) != w]
# malformed epic args still map to None
bad += [("0", m._epic_letter(0), None)] if m._epic_letter(0) is not None else []
bad += [("foo", m._epic_letter("foo"), None)] if m._epic_letter("foo") is not None else []
print("OK" if not bad else "BAD " + repr(bad))
PY
)"
if [ "$i1_out" = "OK" ]; then
    echo "PASS [I1-epic-letter >26 + backward-compat]"
else
    echo "FAIL [I1-epic-letter]: $i1_out" >&2; failed=$((failed+1))
fi

# ============================================================================
# I2a — i18n locale `*-credentials.json` no longer halts (BLACKLIST cleared)
# ============================================================================
dir="$(seed_repo)"
(cd "$dir" && printf '{"title":"个人凭证"}\n' \
    > web/src/i18n/locales/zh-CN/personal-credentials.json)
out="$(cd "$dir" && python3 "$HARNESS_PY" 4 9-9-story --dry-run 2>&1)"
rm -rf "$dir"
if printf '%s' "$out" | grep -qE "^STATUS=ok$" \
   && ! printf '%s' "$out" | grep -qE "^BLACKLIST=" \
   && printf '%s' "$out" | grep -qE "STAGED=web/src/i18n/locales/zh-CN/personal-credentials.json"; then
    echo "PASS [I2a-i18n locale credentials.json passes]"
else
    echo "FAIL [I2a-i18n]: out=$out" >&2; failed=$((failed+1))
fi

# ============================================================================
# I2b — a REAL credential file is still blocked (regression guard)
# ============================================================================
dir="$(seed_repo)"
(cd "$dir" && printf 'aws_secret_access_key = AKIA...\n' \
    > infra/aws-credentials.json)
ex=0; out="$(cd "$dir" && python3 "$HARNESS_PY" 4 9-9-story --dry-run 2>&1)" || ex=$?
rm -rf "$dir"
if [ "$ex" != 0 ] \
   && printf '%s' "$out" | grep -qE "^STATUS=halt$" \
   && printf '%s' "$out" | grep -qE "^BLACKLIST=infra/aws-credentials.json"; then
    echo "PASS [I2b-real credentials.json still blocked]"
else
    echo "FAIL [I2b-real-cred]: exit=$ex out=$out" >&2; failed=$((failed+1))
fi

# ============================================================================
# I3a — _bmad-output/brainstorming/ file halts (OUT_OF_SCOPE_BMAD)
# ============================================================================
dir="$(seed_repo)"
(cd "$dir" && printf '# brainstorm\n' \
    > _bmad-output/brainstorming/brainstorming-session-2026-05-30-permissions.md)
ex=0; out="$(cd "$dir" && python3 "$HARNESS_PY" 4 9-9-story --dry-run 2>&1)" || ex=$?
rm -rf "$dir"
if [ "$ex" != 0 ] \
   && printf '%s' "$out" | grep -qE "^STATUS=halt$" \
   && printf '%s' "$out" | grep -qE "OUT_OF_SCOPE_BMAD=_bmad-output/brainstorming/brainstorming-session-2026-05-30-permissions.md"; then
    echo "PASS [I3a-out-of-scope _bmad-output halts]"
else
    echo "FAIL [I3a-out-of-scope]: exit=$ex out=$out" >&2; failed=$((failed+1))
fi

# ============================================================================
# I3b — implementation-artifacts/ file is IN scope (gate doesn't over-fire)
# ============================================================================
dir="$(seed_repo)"
(cd "$dir" && printf '# story 9-9\nStatus: review\n' \
    > _bmad-output/implementation-artifacts/9-9-story.md)
out="$(cd "$dir" && python3 "$HARNESS_PY" 4 9-9-story --dry-run 2>&1)"
rm -rf "$dir"
if printf '%s' "$out" | grep -qE "^STATUS=ok$" \
   && ! printf '%s' "$out" | grep -qE "^OUT_OF_SCOPE_BMAD="; then
    echo "PASS [I3b-implementation-artifacts in scope]"
else
    echo "FAIL [I3b-in-scope]: out=$out" >&2; failed=$((failed+1))
fi

echo "-------------------------------------------------------------------"
if [ "$failed" = 0 ]; then echo "ALL PASS"; else echo "$failed test(s) FAILED"; fi
exit "$failed"

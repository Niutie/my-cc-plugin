#!/usr/bin/env bash
# Self-test for install_git_hooks.sh (super-harness 0.2.1).
#
#   H1 — fresh repo: hook installed, exit 0
#   H2 — rerun: unchanged, exit 0
#   H3 — older harness hook (has the "Harness pre-commit hook" marker): backed up
#        and replaced, exit 0
#   H4 — project-owned hook (no marker): kept byte-identical, REFUSED on stderr,
#        exit 3 (benign refusal, same contract as core.hooksPath)
#   H5 — HARNESS_HOOK_FORCE=1: project hook backed up and replaced, exit 0
#   H6 — core.hooksPath set: refused, exit 3 (pre-existing contract unchanged)
#   H7 — the chaining line printed by H4's REFUSED message really runs the harness
#        hook and blocks the commit when it fails
#
# Works from the plugin source tree and from a deployed .claude/harness/scripts/.
# Exit code = FAIL count.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/install_git_hooks.sh"
HOOK_SRC="$SCRIPT_DIR/../git-hooks/pre-commit"
[ -f "$INSTALLER" ] && [ -f "$HOOK_SRC" ] || { echo "ERROR: installer or hook source missing" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d -t hooks-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

new_repo() {
    local r="$WORK/$1"
    mkdir -p "$r/.claude/harness/scripts" "$r/.claude/harness/git-hooks"
    git -C "$r" init -q .
    cp "$INSTALLER" "$r/.claude/harness/scripts/"
    cp "$HOOK_SRC" "$r/.claude/harness/git-hooks/pre-commit"
    printf '%s' "$r"
}

# run_inst <repo> [env assignments...] → $OUT $ERR $RC
run_inst() {
    local r="$1"; shift
    RC=0
    OUT="$(cd "$r" && env "$@" bash .claude/harness/scripts/install_git_hooks.sh 2>"$WORK/err")" || RC=$?
    ERR="$(cat "$WORK/err")"
}

R="$(new_repo r1)"
HOOK="$R/.git/hooks/pre-commit"
run_inst "$R"
[ "$RC" = 0 ] && cmp -s "$HOOK_SRC" "$HOOK" && [ -x "$HOOK" ] && ok "H1 fresh install" || bad "H1 rc=$RC $OUT $ERR"

run_inst "$R"
[ "$RC" = 0 ] && printf '%s\n' "$OUT" | grep -q '^unchanged: pre-commit' && ok "H2 rerun unchanged" || bad "H2 rc=$RC $OUT"

printf '#!/bin/bash\n# Harness pre-commit hook\n# (older harness version)\nexit 0\n' > "$HOOK"
run_inst "$R"
[ "$RC" = 0 ] && cmp -s "$HOOK_SRC" "$HOOK" && ls "$HOOK".bak.* >/dev/null 2>&1 \
    && ok "H3 older harness hook backed up and upgraded" || bad "H3 rc=$RC $OUT $ERR"

R="$(new_repo r2)"
HOOK="$R/.git/hooks/pre-commit"
mkdir -p "$(dirname "$HOOK")"
printf '#!/bin/sh\n# managed by the project: secret scan\nexit 0\n' > "$HOOK"
cp "$HOOK" "$WORK/own-hook"
run_inst "$R"
[ "$RC" = 3 ] && cmp -s "$WORK/own-hook" "$HOOK" && printf '%s\n' "$ERR" | grep -q '^REFUSED: ' \
    && ! ls "$HOOK".bak.* >/dev/null 2>&1 \
    && ok "H4 project-owned hook kept, exit 3 + REFUSED" || bad "H4 rc=$RC $OUT $ERR"
H4ERR="$ERR"

run_inst "$R" HARNESS_HOOK_FORCE=1
[ "$RC" = 0 ] && cmp -s "$HOOK_SRC" "$HOOK" && ls "$HOOK".bak.* >/dev/null 2>&1 \
    && ok "H5 HARNESS_HOOK_FORCE=1 replaces with backup" || bad "H5 rc=$RC $OUT $ERR"

# H7 — the chaining line printed in REFUSED actually propagates a harness failure
CHAIN="$(printf '%s\n' "$H4ERR" | grep 'git-hooks/pre-commit' | grep '|| exit 1' | head -n 1 | sed 's/^ *//')"
R="$(new_repo r4)"
HOOK="$R/.git/hooks/pre-commit"
mkdir -p "$(dirname "$HOOK")"
printf '#!/bin/sh\n# project hook\n%s\nexit 0\n' "$CHAIN" > "$HOOK"; chmod +x "$HOOK"
printf '#!/bin/bash\necho harness-gate-ran >&2\nexit 1\n' > "$R/.claude/harness/git-hooks/pre-commit"
git -C "$R" -c user.email=t@e -c user.name=t commit -q --allow-empty -m probe 2>"$WORK/h7" && H7RC=0 || H7RC=$?
[ -n "$CHAIN" ] && [ "$H7RC" != 0 ] && grep -q harness-gate-ran "$WORK/h7" \
    && ok "H7 printed chaining line blocks the commit when the harness hook fails" || bad "H7 chain='$CHAIN' rc=$H7RC $(cat "$WORK/h7")"

R="$(new_repo r3)"
git -C "$R" config core.hooksPath .githooks
run_inst "$R"
[ "$RC" = 3 ] && ok "H6 core.hooksPath still refused with exit 3" || bad "H6 rc=$RC"

echo
echo "PASS=$PASS FAIL=$FAIL"
exit "$FAIL"

#!/usr/bin/env bash
# Self-test for git-hooks/pre-commit gate ① / gate ② wiring (0.3.1 fixes).
#
#   S — SIGPIPE bypass: with thousands of staged paths the old
#       `producer | grep -q` pattern returned 141 under pipefail, the `if` read
#       false and the gate was skipped. Both gates must still fire.
#   M — gate ① before the first epic retro: sprint-status.yaml without a
#       `retro_action_items:` block passes silently in block AND warn mode.
#       sprint-status.yaml missing → passes. 250 / 251 get their own message
#       (block mode rejects, warn mode only warns); real pending dev → rejects.
#   A — artifacts dir follows harness-project-config.yaml `artifacts_root`
#       (gate ① trigger + gate ② ledger path); config without artifacts_root
#       does not print read_harness_config WARN on every commit.
#   I — installed layout: hook copied to .git/hooks/pre-commit, scripts at
#       .claude/harness/scripts, real `git commit` is rejected / accepted.
#
# Sandbox: every fixture is a fresh mktemp git repo (EXIT trap cleanup).
# Source-tree and deployed-tree layouts are the same relative structure
# ({scripts,git-hooks}/ siblings), so this runs from either.
#
# Exit code: number of failed cases (0 = all pass); 2 = prerequisite missing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SRC="$SCRIPT_DIR/../git-hooks/pre-commit"
for f in "$HOOK_SRC" "$SCRIPT_DIR/check_retro_action_items.sh" "$SCRIPT_DIR/read_harness_config.sh" \
         "$SCRIPT_DIR/deferred_work_schema_lib.sh" "$SCRIPT_DIR/harness_config.py"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: missing prerequisite $f" >&2
        exit 2
    fi
done

unset HARNESS_CONFIG_PATH 2>/dev/null || true
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

WORKDIR="$(mktemp -d -t pre_commit_gate_test.XXXXXX)" || exit 2
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

DEF_ART="_bmad-output/implementation-artifacts"
PENDING_DEV="$(printf '%s\n' 'development_status:' '  9-1-foo: backlog' 'retro_action_items:' \
    '  epic-8-retro:' '    H1:' '      status: pending' '      category: dev')"
NO_BLOCK="$(printf '%s\n' 'development_status:' '  9-1-foo: backlog')"
EMPTY_BLOCK="$(printf '%s\n' 'development_status:' '  9-1-foo: backlog' 'retro_action_items:' '  epic-8-retro:')"
DUP_BLOCK="$(printf '%s\n' 'retro_action_items:' '  epic-7-retro:' '    A1: done' \
    'development_status:' '  9-1-foo: backlog' 'retro_action_items:' '  epic-8-retro:' '    A2: done')"
GOOD_FU='- **FU-99.1.A** `[status:pending]` `[bucket:other]` `[target:Story 9.2]` `[source:dev-of-9.1]` — ok'
BAD_FU='- **FU-99.1.B** — missing the 4-tag block'

# new_repo <name> <retro_gate|''> <artifacts_root|''> <sprint-status content|'-'>
# Deployed layout (.claude/harness/{scripts,git-hooks}), hook installed to
# .git/hooks/pre-commit. Prints the repo dir.
new_repo() {
    local dir="$WORKDIR/$1" gate="$2" art_cfg="$3" ss="$4"
    local art="${art_cfg:-$DEF_ART}"
    mkdir -p "$dir"
    (
        cd "$dir" || exit 1
        git init -q
        git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
        mkdir -p .claude/harness/scripts .claude/harness/git-hooks "$art"
        for f in check_retro_action_items.sh read_harness_config.sh deferred_work_schema_lib.sh harness_config.py; do
            cp "$SCRIPT_DIR/$f" .claude/harness/scripts/
        done
        cp "$HOOK_SRC" .claude/harness/git-hooks/pre-commit
        {
            echo "project_name: fixture"
            [ -n "$gate" ] && echo "retro_gate: '$gate'"
            [ -n "$art_cfg" ] && echo "artifacts_root: $art_cfg"
        } > .claude/harness/harness-project-config.yaml
        [ "$ss" != "-" ] && printf '%s\n' "$ss" > "$art/sprint-status.yaml"
        printf '# Deferred Work\n' > "$art/deferred-work.md"
        git add -A
        git commit -q -m seed
        mkdir -p "$(git rev-parse --git-path hooks)"
        cp .claude/harness/git-hooks/pre-commit "$(git rev-parse --git-path hooks)/pre-commit"
        chmod +x "$(git rev-parse --git-path hooks)/pre-commit"
    ) >/dev/null 2>&1 || { echo "fixture $1 setup failed" >&2; return 1; }
    echo "$dir"
}

# run_hook <dir> → sets HRC / HERR (runs the installed hook directly)
run_hook() {
    HRC=0
    HERR="$(cd "$1" && bash "$(git rev-parse --git-path hooks)/pre-commit" 2>&1 >/dev/null)" || HRC=$?
}

# many_files <dir> <n>: stage n files whose paths sort AFTER the artifacts
# dir, with long names so `git diff --name-only` exceeds the 64KB pipe buffer.
many_files() {
    (
        cd "$1" || exit 1
        mkdir -p zz-bulk
        local i=0
        while [ "$i" -lt "$2" ]; do
            : > "zz-bulk/file-with-a-fairly-long-name-to-fill-the-pipe-buffer-$i.txt"
            i=$((i + 1))
        done
        git add zz-bulk
    )
}

echo "== S: SIGPIPE bypass with thousands of staged paths =="
d="$(new_repo s1 block '' "$PENDING_DEV")"
(cd "$d" && echo x > "$DEF_ART/spec-9-1-foo.md" && git add -A)
many_files "$d" 3000
run_hook "$d"
if [ "$HRC" = 1 ] && grep -q "未兑现 dev 类" <<<"$HERR"; then
    ok "S1 gate ① still blocks with 3000 extra staged files"
else
    bad "S1 expected rc=1 + pending message, got rc=$HRC err=$(head -5 <<<"$HERR")"
fi

d="$(new_repo s2 '' '' "$NO_BLOCK")"
(cd "$d" && printf '\n%s\n' "$BAD_FU" >> "$DEF_ART/deferred-work.md" && git add -A)
many_files "$d" 3000
run_hook "$d"
if [ "$HRC" = 1 ] && grep -q "违反 schema v1" <<<"$HERR"; then
    ok "S2 gate ② still blocks a malformed FU bullet with 3000 extra staged files"
else
    bad "S2 expected rc=1 + schema message, got rc=$HRC err=$(head -5 <<<"$HERR")"
fi

echo "== M: gate ① exit-code contract =="
for mode in block warn; do
    d="$(new_repo "m1-$mode" "$mode" '' "$NO_BLOCK")"
    (cd "$d" && echo x > "$DEF_ART/spec-9-1-foo.md" && git add -A)
    run_hook "$d"
    if [ "$HRC" = 0 ] && [ -z "$HERR" ]; then
        ok "M1 retro_action_items block missing → silent pass (retro_gate=$mode)"
    else
        bad "M1 ($mode) expected rc=0 + empty stderr, got rc=$HRC err=$HERR"
    fi
done

d="$(new_repo m2 block '' -)"
(cd "$d" && echo x > "$DEF_ART/spec-9-1-foo.md" && git add -A)
run_hook "$d"
if [ "$HRC" = 0 ] && grep -q "未找到 sprint-status.yaml" <<<"$HERR"; then
    ok "M2 sprint-status.yaml missing → pass with a NOTE"
else
    bad "M2 expected rc=0 + NOTE, got rc=$HRC err=$HERR"
fi

d="$(new_repo m3 block '' "$DUP_BLOCK")"
(cd "$d" && echo x > "$DEF_ART/spec-9-1-foo.md" && git add -A)
run_hook "$d"
if [ "$HRC" = 1 ] && grep -q "多个 retro_action_items" <<<"$HERR" && ! grep -q "未兑现 dev 类" <<<"$HERR"; then
    ok "M3 duplicate header (251) → own message, block mode rejects"
else
    bad "M3 expected rc=1 + duplicate-key message, got rc=$HRC err=$HERR"
fi

d="$(new_repo m4 warn '' "$DUP_BLOCK")"
(cd "$d" && echo x > "$DEF_ART/spec-9-1-foo.md" && git add -A)
run_hook "$d"
if [ "$HRC" = 0 ] && grep -q "^WARN: gate ① 无法确认" <<<"$HERR" && ! grep -q "未兑现 dev 类" <<<"$HERR"; then
    ok "M4 duplicate header (251), warn mode → WARN, pass"
else
    bad "M4 expected rc=0 + structure WARN, got rc=$HRC err=$HERR"
fi

d="$(new_repo m5 warn '' "$EMPTY_BLOCK")"
(cd "$d" && echo x > "$DEF_ART/spec-9-1-foo.md" && git add -A)
run_hook "$d"
if [ "$HRC" = 0 ] && grep -q "0 个 action item" <<<"$HERR" && ! grep -q "未兑现 dev 类" <<<"$HERR"; then
    ok "M5 empty block (250), warn mode → own WARN, pass"
else
    bad "M5 expected rc=0 + empty-block WARN, got rc=$HRC err=$HERR"
fi

d="$(new_repo m6 block '' "$EMPTY_BLOCK")"
(cd "$d" && echo x > "$DEF_ART/spec-9-1-foo.md" && git add -A)
run_hook "$d"
if [ "$HRC" = 1 ] && grep -q "0 个 action item" <<<"$HERR"; then
    ok "M6 empty block (250), block mode → rejects with own message"
else
    bad "M6 expected rc=1 + empty-block message, got rc=$HRC err=$HERR"
fi

echo "== A: artifacts_root from harness-project-config.yaml =="
d="$(new_repo a1 block docs/impl "$PENDING_DEV")"
(cd "$d" && echo x > docs/impl/spec-9-1-foo.md && git add -A)
run_hook "$d"
if [ "$HRC" = 1 ] && grep -q "未兑现 dev 类" <<<"$HERR"; then
    ok "A1 custom artifacts_root: new spec under docs/impl triggers gate ①"
else
    bad "A1 expected rc=1, got rc=$HRC err=$HERR"
fi

d="$(new_repo a2 block docs/impl "$PENDING_DEV")"
(cd "$d" && mkdir -p "$DEF_ART" && echo x > "$DEF_ART/spec-9-1-foo.md" && git add -A)
run_hook "$d"
if [ "$HRC" = 0 ]; then
    ok "A2 custom artifacts_root: spec under the default dir does not trigger"
else
    bad "A2 expected rc=0, got rc=$HRC err=$HERR"
fi

d="$(new_repo a3 '' docs/impl "$NO_BLOCK")"
(cd "$d" && printf '\n%s\n' "$BAD_FU" >> docs/impl/deferred-work.md && git add -A)
run_hook "$d"
if [ "$HRC" = 1 ] && grep -q "违反 schema v1" <<<"$HERR"; then
    ok "A3 custom artifacts_root: gate ② checks docs/impl/deferred-work.md"
else
    bad "A3 expected rc=1, got rc=$HRC err=$HERR"
fi

d="$(new_repo a4 warn '' "$NO_BLOCK")"
(cd "$d" && echo x > "$DEF_ART/spec-9-1-foo.md" && printf '\n%s\n' "$GOOD_FU" >> "$DEF_ART/deferred-work.md" && git add -A)
run_hook "$d"
if [ "$HRC" = 0 ] && ! grep -q "read_harness_config" <<<"$HERR"; then
    ok "A4 config without artifacts_root: no read_harness_config WARN on commit"
else
    bad "A4 expected rc=0 + no config WARN, got rc=$HRC err=$HERR"
fi

echo "== I: installed hook via real git commit =="
d="$(new_repo i1 block '' "$PENDING_DEV")"
rc=0; out="$(cd "$d" && echo x > "$DEF_ART/spec-9-1-foo.md" && git add -A && git commit -q -m spec 2>&1)" || rc=$?
if [ "$rc" != 0 ] && grep -q "未兑现 dev 类" <<<"$out" \
   && [ "$(cd "$d" && git rev-list --count HEAD)" = 1 ]; then
    ok "I1 git commit rejected by installed hook (pending dev, block)"
else
    bad "I1 expected commit rejected, got rc=$rc out=$out"
fi
d="$(new_repo i2 block '' "$NO_BLOCK")"
rc=0; out="$(cd "$d" && echo x > "$DEF_ART/spec-9-1-foo.md" && git add -A && git commit -q -m spec 2>&1)" || rc=$?
if [ "$rc" = 0 ] && [ "$(cd "$d" && git rev-list --count HEAD)" = 2 ]; then
    ok "I2 git commit accepted before the first retro (block mode)"
else
    bad "I2 expected commit accepted, got rc=$rc out=$out"
fi

echo ""
echo "PASS=$PASS FAIL=$FAIL"
exit "$FAIL"

#!/usr/bin/env bash
# Self-test for harness-commit.py worktree-status reading (0.3.1):
#
#   R — renames: the ORIGINAL path of a rename goes through the blacklist and
#       cross-story gates too (pre-fix only the new path was kept, so
#       `git mv _bmad/core/config.yaml x.yaml` or moving another story's spec
#       passed with STATUS=ok). Legit renames — staged (`git mv`) and plain
#       `mv` (deletion side unstaged) — still stage and commit cleanly.
#   U — submodules: untracked files inside a submodule no longer show up as a
#       dirty ` M vendor/sub` (pre-fix: step 6 halted UNSTAGED=vendor/sub after
#       other paths were staged; build-verify reported DIRTY_WORKTREE). A moved
#       submodule commit still counts as a change.
#
# Runs the PLUGIN SOURCE harness-commit.py inside mktemp git repos.
# Exit code = failed case count (0 = all pass).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_PY="$SCRIPT_DIR/harness-commit.py"
if [ ! -f "$HARNESS_PY" ]; then
    echo "ERROR: harness-commit.py not found at $HARNESS_PY" >&2
    exit 2
fi

unset HARNESS_CONFIG_PATH 2>/dev/null || true
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

PASS=0
FAIL=0
WORKDIR="$(mktemp -d -t hc-rename-sub.XXXXXX)" || exit 2
trap 'rm -rf "$WORKDIR"' EXIT

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

ART="_bmad-output/implementation-artifacts"

seed_repo() {
    local dir="$WORKDIR/$1"
    mkdir -p "$dir"
    (
        cd "$dir" || exit 1
        git init -q
        git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
        git config core.excludesfile /dev/null
        mkdir -p "$ART" _bmad/core src
        printf 'development_status:\n  9-9-story: backlog\n  9-2-other: backlog\n' > "$ART/sprint-status.yaml"
        printf '# deferred\n' > "$ART/deferred-work.md"
        printf -- '---\nstatus: done\n---\n# other\n' > "$ART/spec-9-2-other.md"
        printf 'k: v\n' > _bmad/core/config.yaml
        printf 'print(1)\n' > src/a.py
        git add -A
        git commit -q -m seed
    ) >/dev/null 2>&1 || { echo "seed $1 failed" >&2; return 1; }
    echo "$dir"
}

hc() {  # hc <dir> <args...> → sets OUT / EX
    local dir="$1"; shift
    EX=0
    OUT="$(cd "$dir" && python3 "$HARNESS_PY" "$@" 2>&1)" || EX=$?
}

has() { grep -qxF -- "$1" <<<"$OUT"; }

echo "== R: renames =="
d="$(seed_repo r1)"
(cd "$d" && git mv _bmad/core/config.yaml src_config.yaml)
hc "$d" 4 9-9-story --dry-run
if [ "$EX" = 1 ] && has "STATUS=halt" && has "BLACKLIST=_bmad/core/config.yaml (_bmad/**)"; then
    ok "R1 git mv out of _bmad/ → BLACKLIST on the original path"
else
    bad "R1 expected BLACKLIST=_bmad/core/config.yaml, got exit=$EX out=$OUT"
fi

d="$(seed_repo r2)"
(cd "$d" && mkdir -p docs && git mv "$ART/spec-9-2-other.md" docs/other.md)
hc "$d" 4 9-9-story --dry-run
if [ "$EX" = 1 ] && has "STATUS=halt" && has "CROSS_STORY=$ART/spec-9-2-other.md"; then
    ok "R2 git mv of another story's spec → CROSS_STORY on the original path"
else
    bad "R2 expected CROSS_STORY=$ART/spec-9-2-other.md, got exit=$EX out=$OUT"
fi

d="$(seed_repo r3)"
(cd "$d" && git mv src/a.py src/b.py)
hc "$d" 4 9-9-story
if [ "$EX" = 0 ] && has "STATUS=ok" && has "STAGED=src/a.py" && has "STAGED=src/b.py" \
   && (cd "$d" && git commit -q -m mv && [ -z "$(git status --porcelain)" ] \
       && ! git cat-file -e HEAD:src/a.py 2>/dev/null && git cat-file -e HEAD:src/b.py); then
    ok "R3 legit git mv of project code → ok, commit leaves a clean tree"
else
    bad "R3 expected ok + clean commit, got exit=$EX out=$OUT status=$(cd "$d" && git status --porcelain)"
fi

d="$(seed_repo r4)"
(cd "$d" && mv src/a.py src/c.py)
hc "$d" 4 9-9-story
if [ "$EX" = 0 ] && has "STATUS=ok" && has "STAGED=src/a.py" && has "STAGED=src/c.py" \
   && (cd "$d" && git commit -q -m mv && [ -z "$(git status --porcelain)" ] \
       && ! git cat-file -e HEAD:src/a.py 2>/dev/null && git cat-file -e HEAD:src/c.py); then
    ok "R4 plain mv (unstaged deletion side) → git add stages the deletion, clean commit"
else
    bad "R4 expected ok + clean commit, got exit=$EX out=$OUT status=$(cd "$d" && git status --porcelain)"
fi

# R5 — parser fallback: an `R ` record (e.g. status.renames leaking through)
# yields the original path as a `D ` entry.
r5="$(python3 - "$SCRIPT_DIR" <<'PY' 2>/dev/null
import importlib.util, sys
sys.path.insert(0, sys.argv[1])
spec = importlib.util.spec_from_file_location("hc", sys.argv[1] + "/harness-commit.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m._parse_porcelain_z("R  new.yaml\0_bmad/core/config.yaml\0C  cp.txt\0src.txt\0?? x\0"))
PY
)"
if [ "$r5" = "[('R ', 'new.yaml'), ('D ', '_bmad/core/config.yaml'), ('C ', 'cp.txt'), ('??', 'x')]" ]; then
    ok "R5 _parse_porcelain_z keeps a rename's original path"
else
    bad "R5 unexpected parse: $r5"
fi

echo "== U: submodules =="
SUBSRC="$WORKDIR/subsrc"
mkdir -p "$SUBSRC"
(cd "$SUBSRC" && git init -q && git config user.email t@t.t && git config user.name t \
    && git config commit.gpgsign false && echo lib > lib.txt && git add -A && git commit -q -m lib) >/dev/null 2>&1

sub_repo() {
    local d
    d="$(seed_repo "$1")" || return 1
    (cd "$d" && git -c protocol.file.allow=always submodule add -q "$SUBSRC" vendor/sub \
        && git commit -q -m add-sub) >/dev/null 2>&1 || { echo "submodule setup $1 failed" >&2; return 1; }
    echo "$d"
}

d="$(sub_repo u1)"
(cd "$d" && echo build > vendor/sub/untracked.out && echo 'print(2)' > src/a.py)
hc "$d" 4 9-9-story
if [ "$EX" = 0 ] && has "STATUS=ok" && has "STAGED=src/a.py" && ! grep -q "vendor/sub" <<<"$OUT"; then
    ok "U1 untracked file inside submodule ignored; stage 4 ok, no UNSTAGED=vendor/sub"
else
    bad "U1 expected ok without vendor/sub, got exit=$EX out=$OUT"
fi

d="$(sub_repo u2)"
(cd "$d" && echo build > vendor/sub/untracked.out)
hc "$d" build-verify 9-9-story --base HEAD
if ! grep -q "DIRTY_WORKTREE=vendor/sub" <<<"$OUT"; then
    ok "U2 build-verify does not report DIRTY_WORKTREE=vendor/sub"
else
    bad "U2 build-verify still reports the submodule dirty: $OUT"
fi

d="$(sub_repo u3)"
(cd "$d/vendor/sub" && echo v2 > lib.txt && git -c user.email=t@t.t -c user.name=t commit -q -am v2) >/dev/null 2>&1
hc "$d" 4 9-9-story --dry-run
if [ "$EX" = 0 ] && has "STAGED=vendor/sub"; then
    ok "U3 moved submodule commit still counts as a change"
else
    bad "U3 expected STAGED=vendor/sub, got exit=$EX out=$OUT"
fi

echo ""
echo "PASS=$PASS FAIL=$FAIL"
exit "$FAIL"

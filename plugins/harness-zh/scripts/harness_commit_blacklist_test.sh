#!/usr/bin/env bash
# Self-test for harness-commit.py safety-gate fixes (review 2026-06-10 #1/#7):
#
#   A — repo-ROOT credential files hit the blacklist (glob_match now has
#       gitignore `**/` semantics: zero or more leading segments, so
#       `**/.env*` matches bare `.env`; `**/secrets/**` matches top-level
#       `secrets/api.txt`). Pre-fix these all silently bypassed the gate.
#   B — a fully-untracked NEW directory is expanded by `git status --porcelain
#       -uall`, so a nested `config/.env` is visible to the scan (pre-fix the
#       dir collapsed to one opaque `?? config/` line → full bypass).
#   C — junk tier (.DS_Store / *.tmp / *.swp) is auto-skipped FOR PATHS NOT IN
#       HEAD: never staged, never a halt, one `NOTE: skipped junk file:`
#       stderr line each. A junk-only worktree counts as empty (skip_if_empty
#       stage → STATUS=skip). R1 regression coverage (2026-06-10): `**/*.log`
#       is NOT a junk pattern (untracked debug.log commits normally, C1);
#       tracked junk-pattern paths are never filtered — a `git rm`'d tracked
#       .DS_Store deletion commits (C5) and a tracked access.log modification
#       stays in the commit (C6); a staged-NEW (`A `, absent from HEAD) junk
#       file is still unstaged + skipped (C7).
#   D — exemptions do NOT regress: i18n locale `*-credentials.json` passes;
#       BMad artifacts-dir md/json/yaml are exempt from the blacklist (they
#       still hit the cross-story/classification gates, just never BLACKLIST=).
#
# Runs against the PLUGIN SOURCE harness-commit.py directly via tmp git repos
# + --dry-run (same sandbox approach as harness_commit_issue5_test.sh).
# Exit code = failed fixture count (0 = all pass).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_PY="$SCRIPT_DIR/harness-commit.py"

if [ ! -f "$HARNESS_PY" ]; then
    echo "ERROR: harness-commit.py not found at $HARNESS_PY" >&2
    exit 2
fi

# Hermetic: a caller-exported config override must not leak into the sandbox.
unset HARNESS_CONFIG_PATH 2>/dev/null || true
# Hermetic git: the host's global/system config (e.g. a core.excludesFile that
# ignores .DS_Store) must not hide fixture files from `git status` — both for
# our git calls and for the ones harness-commit.py shells out to. The env vars
# need git ≥ 2.32; the repo-level `core.excludesfile /dev/null` in seed_repo
# covers older gits (repo config overrides global).
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

PASS=0
FAIL=0
WORKDIR="$(mktemp -d -t hc-blacklist.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# seed_repo <name> → prints repo dir. Baseline tree is fully committed (clean
# worktree) so fixtures control exactly which paths porcelain reports.
seed_repo() {
    local dir="$WORKDIR/$1"
    mkdir -p "$dir"
    (
        cd "$dir"
        git init -q
        git config user.email t@t.t
        git config user.name t
        git config commit.gpgsign false
        git config core.excludesfile /dev/null
        mkdir -p _bmad-output/implementation-artifacts
        touch _bmad-output/implementation-artifacts/.gitkeep
        printf 'development_status:\n  9-9-story: backlog\n' \
            > _bmad-output/implementation-artifacts/sprint-status.yaml
        printf '# deferred\n' \
            > _bmad-output/implementation-artifacts/deferred-work.md
        git add -A
        git commit -q -m seed
    )
    echo "$dir"
}

# ============================================================================
# A — repo-root credential files all halt (finding #7: `**/` matches zero segs)
# ============================================================================
dir="$(seed_repo a-root-creds)"
(
    cd "$dir"
    printf 'SECRET=1\n'        > .env
    printf '{"k":"v"}\n'       > credentials.json
    printf 'PEMPEM\n'          > server.pem
    mkdir -p secrets
    printf 'token\n'           > secrets/api.txt
)
ex=0; out="$(cd "$dir" && python3 "$HARNESS_PY" 4 9-9-story --dry-run 2>&1)" || ex=$?
if [ "$ex" != 0 ] && printf '%s\n' "$out" | grep -qx "STATUS=halt"; then
    ok "A1 root credential worktree halts (exit=$ex)"
else
    bad "A1 expected halt, got exit=$ex out=$out"
fi
for want in \
    'BLACKLIST=.env (**/.env*)' \
    'BLACKLIST=credentials.json (**/credentials.json)' \
    'BLACKLIST=server.pem (**/*.pem)' \
    'BLACKLIST=secrets/api.txt (**/secrets/**)'
do
    if printf '%s\n' "$out" | grep -qxF -- "$want"; then
        ok "A2 $want"
    else
        bad "A2 missing '$want' in: $out"
    fi
done

# ============================================================================
# B — nested .env inside a brand-new untracked dir is seen via -uall (finding #1)
# ============================================================================
dir="$(seed_repo b-new-dir)"
(
    cd "$dir"
    mkdir -p config
    printf 'SECRET=1\n' > config/.env
    printf 'app\n'      > config/app.py
)
ex=0; out="$(cd "$dir" && python3 "$HARNESS_PY" 4 9-9-story --dry-run 2>&1)" || ex=$?
if [ "$ex" != 0 ] && printf '%s\n' "$out" | grep -qx "STATUS=halt" \
   && printf '%s\n' "$out" | grep -qxF 'BLACKLIST=config/.env (**/.env*)'; then
    ok "B1 nested config/.env in NEW untracked dir hits blacklist"
else
    bad "B1 expected BLACKLIST=config/.env halt, got exit=$ex out=$out"
fi
# -uall expansion proof: CHANGED_ALL lists the sibling file individually
# (pre-fix porcelain reported only the opaque `config/` dir line).
if printf '%s\n' "$out" | grep -q "CHANGED_ALL=.*config/app\.py"; then
    ok "B2 CHANGED_ALL lists expanded sibling config/app.py (-uall)"
else
    bad "B2 CHANGED_ALL did not expand new-dir contents: $out"
fi

# ============================================================================
# C — junk tier auto-skip: never staged, never halt, stderr NOTE
# ============================================================================
dir="$(seed_repo c-junk)"
(
    cd "$dir"
    mkdir -p src
    printf 'print(1)\n' > src/app.py
    printf 'junk\n'     > .DS_Store
    printf 'junk\n'     > foo.tmp
    printf 'junk\n'     > foo.swp
    printf 'log line\n' > debug.log
)
ex=0
out="$(cd "$dir" && python3 "$HARNESS_PY" 4 9-9-story --dry-run 2>/dev/null)" || ex=$?
errout="$(cd "$dir" && python3 "$HARNESS_PY" 4 9-9-story --dry-run 2>&1 >/dev/null)" || true
# R1(a): *.log is NOT junk — an untracked debug.log enters the commit normally.
if [ "$ex" = 0 ] && printf '%s\n' "$out" | grep -qx "STATUS=ok" \
   && printf '%s\n' "$out" | grep -qx "STAGED=src/app.py" \
   && printf '%s\n' "$out" | grep -qx "STAGED=debug.log"; then
    ok "C1 junk-laden worktree commits OK (legit files staged, incl. untracked debug.log)"
else
    bad "C1 expected STATUS=ok + STAGED=src/app.py + STAGED=debug.log, got exit=$ex out=$out"
fi
for junk in .DS_Store foo.tmp foo.swp; do
    if printf '%s\n' "$errout" | grep -qxF "NOTE: skipped junk file: $junk"; then
        ok "C2 stderr NOTE for $junk"
    else
        bad "C2 missing stderr 'NOTE: skipped junk file: $junk' in: $errout"
    fi
done
# Negative guards (paired with the positive C1/C2 asserts above):
if ! printf '%s\n' "$out" | grep -q "^BLACKLIST=" \
   && ! printf '%s\n' "$out" | grep -qE "^STAGED=(\.DS_Store|foo\.tmp|foo\.swp)$" \
   && ! printf '%s\n' "$errout" | grep -qF "NOTE: skipped junk file: debug.log"; then
    ok "C3 junk never halts/never enters STAGED; debug.log never NOTEd as junk"
else
    bad "C3 junk leaked into BLACKLIST/STAGED or debug.log treated as junk: $out / $errout"
fi

# C4 — junk-ONLY worktree counts as empty: skip_if_empty stage → STATUS=skip
# (exit 2), proving junk can never produce a halt of its own.
dir="$(seed_repo c4-junk-only)"
(
    cd "$dir"
    printf 'junk\n' > .DS_Store
    printf 'junk\n' > foo.tmp
)
ex=0; out="$(cd "$dir" && python3 "$HARNESS_PY" 5-fallback 9-9-story --dry-run 2>&1)" || ex=$?
if [ "$ex" = 2 ] && printf '%s\n' "$out" | grep -qx "STATUS=skip" \
   && printf '%s\n' "$out" | grep -qxF "NOTE: skipped junk file: .DS_Store" \
   && printf '%s\n' "$out" | grep -qxF "NOTE: skipped junk file: foo.tmp"; then
    ok "C4 junk-only worktree → STATUS=skip exit 2 (never halt)"
else
    bad "C4 expected STATUS=skip exit 2, got exit=$ex out=$out"
fi

# C5 — R1 regression: a TRACKED .DS_Store deleted via `git rm` is NOT junk-
# filtered — the staged deletion survives the pipeline and commits. (Pre-fix:
# filter_junk_paths ran `git restore --staged` on the 'D ' entry and dropped
# it, so the deletion silently never committed.) Non-dry-run to exercise the
# real unstage path + step-6 remainder check.
dir="$(seed_repo c5-rm-tracked-ds)"
(
    cd "$dir"
    printf 'junk\n' > .DS_Store
    git add .DS_Store
    git commit -q -m track-ds-store
    git rm -q .DS_Store
)
ex=0; out="$(cd "$dir" && python3 "$HARNESS_PY" 4 9-9-story 2>&1)" || ex=$?
if [ "$ex" = 0 ] && printf '%s\n' "$out" | grep -qx "STATUS=ok" \
   && printf '%s\n' "$out" | grep -qx "STAGED=.DS_Store" \
   && ! printf '%s\n' "$out" | grep -qF "NOTE: skipped junk file: .DS_Store"; then
    ok "C5 tracked .DS_Store deletion stays staged (no junk filtering)"
else
    bad "C5 expected STATUS=ok + STAGED=.DS_Store + no junk NOTE, got exit=$ex out=$out"
fi
if (cd "$dir" && git diff --cached --name-status | grep -qE '^D[[:space:]]+\.DS_Store$' \
    && git commit -q -m del-ds-store && [ -z "$(git status --porcelain)" ]); then
    ok "C5b staged deletion actually commits (worktree clean after)"
else
    bad "C5b tracked .DS_Store deletion did not commit cleanly: $(cd "$dir" && git status --porcelain)"
fi

# C6 — R1 regression: a TRACKED access.log modification is NOT junk-filtered
# (and *.log is no longer a junk pattern at all) — the edit enters the commit.
# (Pre-fix: the ' M' entry was dropped, so the edit silently never committed.)
dir="$(seed_repo c6-tracked-log)"
(
    cd "$dir"
    printf 'line1\n' > access.log
    git add access.log
    git commit -q -m track-log
    printf 'line2\n' >> access.log
)
ex=0; out="$(cd "$dir" && python3 "$HARNESS_PY" 4 9-9-story 2>&1)" || ex=$?
if [ "$ex" = 0 ] && printf '%s\n' "$out" | grep -qx "STATUS=ok" \
   && printf '%s\n' "$out" | grep -qx "STAGED=access.log" \
   && ! printf '%s\n' "$out" | grep -qF "NOTE: skipped junk file: access.log"; then
    ok "C6 tracked access.log modification stays in commit (not unstaged/dropped)"
else
    bad "C6 expected STATUS=ok + STAGED=access.log + no junk NOTE, got exit=$ex out=$out"
fi
if (cd "$dir" && git diff --cached --name-only | grep -qx 'access.log' \
    && git commit -q -m log-edit && [ -z "$(git status --porcelain)" ]); then
    ok "C6b tracked .log edit actually commits (worktree clean after)"
else
    bad "C6b tracked access.log edit did not commit cleanly: $(cd "$dir" && git status --porcelain)"
fi

# C7 — retained behavior: a staged-NEW junk file ('A ', absent from HEAD) is
# unstaged via `git restore --staged` + skipped; legit sibling still commits.
dir="$(seed_repo c7-staged-new-junk)"
(
    cd "$dir"
    mkdir -p src
    printf 'print(1)\n' > src/app.py
    printf 'junk\n'     > .DS_Store
    git add .DS_Store
)
ex=0; out="$(cd "$dir" && python3 "$HARNESS_PY" 4 9-9-story 2>&1)" || ex=$?
if [ "$ex" = 0 ] && printf '%s\n' "$out" | grep -qx "STATUS=ok" \
   && printf '%s\n' "$out" | grep -qx "STAGED=src/app.py" \
   && ! printf '%s\n' "$out" | grep -qx "STAGED=.DS_Store" \
   && printf '%s\n' "$out" | grep -qxF "NOTE: skipped junk file: .DS_Store"; then
    ok "C7 staged-new .DS_Store unstaged + skipped (legit sibling staged)"
else
    bad "C7 expected ok + STAGED=src/app.py only + junk NOTE, got exit=$ex out=$out"
fi
if (cd "$dir" && git status --porcelain | grep -qx '?? .DS_Store' \
    && ! git diff --cached --name-only | grep -qx '.DS_Store'); then
    ok "C7b .DS_Store back to untracked (restore --staged ran), not in index"
else
    bad "C7b .DS_Store index state wrong: $(cd "$dir" && git status --porcelain)"
fi

# ============================================================================
# D — exemptions do not regress
# ============================================================================
# D1 — i18n locale `*-credentials.json` passes (issue #5 exemption), here in a
# fully-untracked new dir so it also exercises the -uall + exemption combo.
dir="$(seed_repo d1-i18n)"
(
    cd "$dir"
    mkdir -p web/src/i18n/locales/zh-CN
    printf '{"title":"个人凭证"}\n' \
        > web/src/i18n/locales/zh-CN/personal-credentials.json
)
ex=0; out="$(cd "$dir" && python3 "$HARNESS_PY" 4 9-9-story --dry-run 2>&1)" || ex=$?
if [ "$ex" = 0 ] && printf '%s\n' "$out" | grep -qx "STATUS=ok" \
   && printf '%s\n' "$out" | grep -qx "STAGED=web/src/i18n/locales/zh-CN/personal-credentials.json" \
   && ! printf '%s\n' "$out" | grep -q "^BLACKLIST="; then
    ok "D1 i18n locale *-credentials.json exempt (STATUS=ok, staged)"
else
    bad "D1 i18n exemption regressed: exit=$ex out=$out"
fi

# D2 — BMad artifacts-dir engineering products are exempt from the BLACKLIST
# tier: a credential-named yaml inside implementation-artifacts/ must NOT
# report BLACKLIST= — it falls through to the cross-story isolation gate
# instead (CROSS_STORY=, since it carries no story-key prefix).
dir="$(seed_repo d2-artifacts)"
(
    cd "$dir"
    printf 'k: v\n' > _bmad-output/implementation-artifacts/db-credentials.yaml
)
ex=0; out="$(cd "$dir" && python3 "$HARNESS_PY" 4 9-9-story --dry-run 2>&1)" || ex=$?
if [ "$ex" != 0 ] && printf '%s\n' "$out" | grep -qx "STATUS=halt" \
   && printf '%s\n' "$out" | grep -qx "CROSS_STORY=_bmad-output/implementation-artifacts/db-credentials.yaml" \
   && ! printf '%s\n' "$out" | grep -q "^BLACKLIST="; then
    ok "D2 artifacts-dir credential-named yaml: no BLACKLIST (cross-story gate instead)"
else
    bad "D2 artifacts exemption regressed: exit=$ex out=$out"
fi

echo ""
echo "============================================================================"
echo "PASS=$PASS FAIL=$FAIL"
exit "$FAIL"

#!/usr/bin/env bash
# gitignore_policy_test.sh — git tracking policy for .claude/harness/ (0.3.1+).
#
# Policy: deployed assets are ignored, the two user-edited configs are tracked.
#   /.claude/harness/*
#   !/.claude/harness/harness-project-config.yaml
#   !/.claude/harness/parallel.yaml
#
#   G*  ensure_gitignore.sh: create / idempotent / no trailing newline / partial
#       block / legacy `/.claude/harness` line replaced / --check exit codes /
#       conflicting `.claude/` rule reported / already-tracked assets hinted
#   R*  real project after deploy + ensure_gitignore: only .gitignore + the two
#       configs show as untracked; after the first commit the tree is clean and a
#       redeploy that updates a file (backup under .claude/harness/.backup/)
#       leaves it clean
#   L*  superh.py doctor / prepare with the policy: tracked configs come from the
#       checkout, the ignored rest is copied, the lane is clean; an uncommitted
#       config is reported as COMMIT=, never as GITIGNORE=/.claude/harness
#
# Runs from the plugin source tree; everything lives in one mktemp sandbox.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$HERE/.." && pwd)"
EG="$HERE/ensure_gitignore.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }

TMP="$(cd "$(mktemp -d)" && pwd -P)" || exit 1
trap 'rm -rf "$TMP"' EXIT

POLICY='/.claude/harness/*
!/.claude/harness/harness-project-config.yaml
!/.claude/harness/parallel.yaml'

newrepo() {  # newrepo <dir>
    mkdir -p "$1" && git -C "$1" init -q -b main . \
        && git -C "$1" config user.email t@example.com && git -C "$1" config user.name T \
        && git -C "$1" config commit.gpgsign false
}
policy_lines() { grep -vE '^(#|$)' "$1/.gitignore"; }

echo "== G: ensure_gitignore.sh"
G1="$TMP/g1"; newrepo "$G1"
OUT="$(bash "$EG" "$G1")"; RC=$?
[ "$RC" -eq 0 ] && [ "$(policy_lines "$G1")" = "$POLICY" ] && echo "$OUT" | grep -q '^GITIGNORE_STATUS=added' \
    && ok "G1 creates .gitignore with the policy block" || bad "G1 rc=$RC $OUT"
cp "$G1/.gitignore" "$TMP/g1.before"
OUT="$(bash "$EG" "$G1")"
cmp -s "$G1/.gitignore" "$TMP/g1.before" && echo "$OUT" | grep -q '^GITIGNORE_STATUS=unchanged' \
    && ok "G2 second run is a no-op" || bad "G2 $OUT"
bash "$EG" "$G1" --check >/dev/null; [ $? -eq 0 ] && ok "G3 --check exit 0 when complete" || bad "G3"

G4="$TMP/g4"; newrepo "$G4"; printf 'node_modules' > "$G4/.gitignore"   # no trailing newline
bash "$EG" "$G4" --check >/dev/null; RC=$?
cp "$G4/.gitignore" "$TMP/g4.before"
[ "$RC" -eq 4 ] && cmp -s "$G4/.gitignore" "$TMP/g4.before" && ok "G4 --check exit 4 and writes nothing" || bad "G4 rc=$RC"
bash "$EG" "$G4" >/dev/null
head -1 "$G4/.gitignore" | grep -qx 'node_modules' && [ "$(policy_lines "$G4" | sed 1d)" = "$POLICY" ] \
    && ok "G5 appends after a last line without newline, user line intact" || { bad "G5"; cat "$G4/.gitignore"; }

G6="$TMP/g6"; newrepo "$G6"; printf '/.claude/harness/*\n' > "$G6/.gitignore"
OUT="$(bash "$EG" "$G6")"
[ "$(policy_lines "$G6")" = "$POLICY" ] && [ "$(echo "$OUT" | grep -c '^GITIGNORE_ADDED=')" -eq 2 ] \
    && ok "G6 only the missing negations are appended" || { bad "G6 $OUT"; cat "$G6/.gitignore"; }

G7="$TMP/g7"; newrepo "$G7"; printf 'dist/\n/.claude/harness\n' > "$G7/.gitignore"   # ≤0.3.0 doctor advice
OUT="$(bash "$EG" "$G7")"
! grep -qx '/.claude/harness' "$G7/.gitignore" && grep -qx 'dist/' "$G7/.gitignore" \
    && echo "$OUT" | grep -q '^GITIGNORE_REPLACED=/.claude/harness$' \
    && ok "G7 legacy /.claude/harness line removed (it blocks re-including the configs)" || { bad "G7 $OUT"; cat "$G7/.gitignore"; }
mkdir -p "$G7/.claude/harness" && touch "$G7/.claude/harness/parallel.yaml"
git -C "$G7" check-ignore -q .claude/harness/parallel.yaml && bad "G8 parallel.yaml still ignored" || ok "G8 parallel.yaml re-included"

G9="$TMP/g9"; newrepo "$G9"; printf '.claude/\n' > "$G9/.gitignore"
mkdir -p "$G9/.claude/harness" && touch "$G9/.claude/harness/harness-project-config.yaml"
OUT="$(bash "$EG" "$G9")"
echo "$OUT" | grep -q '^GITIGNORE_CONFLICT=.claude/harness/harness-project-config.yaml <- .gitignore:1:.claude/' \
    && ok "G9 a broader .claude/ rule is reported as a conflict" || bad "G9 $OUT"

G10="$TMP/g10"; newrepo "$G10"; mkdir -p "$G10/.claude/harness/scripts"
echo x > "$G10/.claude/harness/scripts/a.sh"; echo y > "$G10/.claude/harness/harness-project-config.yaml"
git -C "$G10" add -A && git -C "$G10" commit -qm all
OUT="$(bash "$EG" "$G10")"
echo "$OUT" | grep -q '^GITIGNORE_TRACKED_ASSETS=1$' && echo "$OUT" | grep -q '^GITIGNORE_UNTRACK_HINT=git rm -r -q --cached .claude/harness' \
    && ok "G10 already-committed assets are counted with an untrack hint" || bad "G10 $OUT"

echo "== R: deployed project"
R="$TMP/proj"; newrepo "$R"
mkdir -p "$R/_bmad-output/implementation-artifacts"
DEPLOY_QUIET=1 bash "$PLUGIN_DIR/scripts/deploy_assets.sh" "$PLUGIN_DIR" "$R" >/dev/null 2>&1
cp "$PLUGIN_DIR/templates/harness-project-config.yaml.template" "$R/.claude/harness/harness-project-config.yaml"
bash "$EG" "$R" >/dev/null
UNTRACKED="$(git -C "$R" status --porcelain -uall | sort)"
EXPECT="$(printf '?? .claude/harness/harness-project-config.yaml\n?? .claude/harness/parallel.yaml\n?? .gitignore\n')"
[ "$UNTRACKED" = "$EXPECT" ] && ok "R1 only .gitignore + the two configs are untracked" || { bad "R1"; echo "$UNTRACKED"; }
git -C "$R" add .gitignore .claude/harness/harness-project-config.yaml .claude/harness/parallel.yaml \
    && git -C "$R" commit -qm "chore: super-harness" && ok "R2 the commit init §6 tells the user to make succeeds" || bad "R2"
[ -z "$(git -C "$R" status --porcelain -uall)" ] && ok "R3 tree clean after the first commit" || bad "R3"
echo "# local edit" >> "$R/.claude/harness/pipeline.md"
DEPLOY_PURGE=1 DEPLOY_QUIET=1 bash "$PLUGIN_DIR/scripts/deploy_assets.sh" "$PLUGIN_DIR" "$R" >/dev/null 2>&1
ls "$R/.claude/harness/.backup/"*/.claude/harness/pipeline.md >/dev/null 2>&1 \
    && [ -z "$(git -C "$R" status --porcelain -uall)" ] \
    && ! ls "$R/.claude/harness/"*.bak.* >/dev/null 2>&1 \
    && ok "R4 update backup lands in .claude/harness/.backup/, tree stays clean" || { bad "R4"; git -C "$R" status --porcelain -uall; }

echo "== L: lanes with the policy"
SH="python3 $R/.claude/harness/scripts/superh.py"
cat > "$R/.claude/harness/parallel.yaml" <<EOF
max_slots: 1
worktree_root: '$TMP/wt'
copy_paths: [.claude/harness]
EOF
cat > "$R/_bmad-output/implementation-artifacts/sprint-status.yaml" <<'EOF'
development_status:
  epic-1:
    status: backlog
  1-1-alpha:
    status: backlog
EOF
git -C "$R" add -A && git -C "$R" commit -qm "sprint + parallel config"
OUT="$(cd "$R" && $SH doctor)"
echo "$OUT" | grep -q '^STATUS=ok' && ! echo "$OUT" | grep -q '^GITIGNORE=' \
    && ok "L1 doctor ok with the policy in place" || { bad "L1"; echo "$OUT"; }
OUT="$(cd "$R" && $SH prepare 1-1-alpha)"
W="$TMP/wt/1-1-alpha"
echo "$OUT" | grep -q '^STATUS=ok' \
    && [ -f "$W/.claude/harness/scripts/superh.py" ] \
    && grep -qx 'max_slots: 1' "$W/.claude/harness/parallel.yaml" \
    && [ -z "$(git -C "$W" status --porcelain -uall)" ] \
    && ok "L2 lane: configs from checkout, ignored assets copied, worktree clean" || { bad "L2"; echo "$OUT"; git -C "$W" status --porcelain -uall; }
(cd "$R" && $SH abandon 1-1-alpha --yes >/dev/null 2>&1)

# config created but not committed yet → COMMIT=, not GITIGNORE=/.claude/harness
git -C "$R" rm -q --cached .claude/harness/parallel.yaml && git -C "$R" commit -qm "untrack parallel.yaml"
OUT="$(cd "$R" && $SH doctor)"
echo "$OUT" | grep -q '^PROBLEM=.claude/harness/parallel.yaml' && echo "$OUT" | grep -qx 'COMMIT=.claude/harness/parallel.yaml' \
    && ! echo "$OUT" | grep -qx 'GITIGNORE=/.claude/harness' && echo "$OUT" | grep -q '^STATUS=attention' \
    && ok "L3 uncommitted config → COMMIT= hint, no /.claude/harness advice" || { bad "L3"; echo "$OUT"; }

# no policy at all → the hint is the policy block, never the bare directory
printf "" > "$R/.gitignore" && git -C "$R" add .gitignore && git -C "$R" commit -qm "drop policy" >/dev/null
OUT="$(cd "$R" && $SH doctor)"
echo "$OUT" | grep -qx 'GITIGNORE=/.claude/harness/\*' && echo "$OUT" | grep -qx 'GITIGNORE=!/.claude/harness/harness-project-config.yaml' \
    && ! echo "$OUT" | grep -qx 'GITIGNORE=/.claude/harness' \
    && ok "L4 doctor suggests the policy block" || { bad "L4"; echo "$OUT"; }

echo
echo "gitignore_policy_test: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

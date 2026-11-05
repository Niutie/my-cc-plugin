#!/usr/bin/env bash
# parked_deps_test.sh — issue #14 / #15 回归测试。
#
#   D*  sprint-status 顶层 story_dependencies（BMad 6.12.4 只认单行写法时的依赖来源）
#       superh plan 读它、deps_overrides 优先、块写法 depends_on 仍然有效
#   E*  ext- 前缀的外部条件：等待、tick/board 单列；run-inline 的 next 也跳过
#   K*  parked_statuses：不派发、不挡 epic 屏障、不挡 retro；全挂起的 epic 不跑 retro
#   B*  epic_barrier: false 时跨 epic 并行
#   S*  sprint-status.py next / next-in-epic / epic-all-done / open-epics
#   R*  harness-commit：EPIC_PARKED=，有挂起 story 时 retro 不把 epic 标 done
#
# 用法：bash parked_deps_test.sh（从 plugin 源码树运行）

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$HERE/.." && pwd)"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }

TMP="$(cd "$(mktemp -d)" && pwd -P)" || exit 1
trap 'rm -rf "$TMP"' EXIT
ART=_bmad-output/implementation-artifacts

# new_proj <name> <parked_statuses yaml line or ''> — echoes project dir
new_proj() {
    local d="$TMP/$1"
    mkdir -p "$d/$ART" "$d/.claude/harness/scripts"
    (
        cd "$d" || exit 1
        git init -q -b sprint .
        git config user.email t@example.com
        git config user.name Tester
        git config commit.gpgsign false
        cp "$PLUGIN_DIR"/scripts/*.py "$PLUGIN_DIR"/scripts/*.sh .claude/harness/scripts/
        {
            echo "project_display_name: 'Fixture'"
            echo "artifacts_root: '$ART'"
            [ -n "$2" ] && echo "$2"
        } > .claude/harness/harness-project-config.yaml
        printf '.claude/\n' > .gitignore
    )
    echo "$d"
}
SH() { (cd "$1" && shift && python3 .claude/harness/scripts/superh.py "$@"); }
SS() { (cd "$1" && shift && python3 .claude/harness/scripts/sprint-status.py "$@"); }
commit_all() { (cd "$1" && git add -A && git commit -qm "${2:-fixture}"); }
jq_py() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

echo "== D: story_dependencies"
P="$(new_proj d '')"
cat > "$P/$ART/sprint-status.yaml" <<'EOF'
development_status:
  epic-1: in-progress
  1-1-a: done
  1-2-b: backlog
  1-3-c: backlog
  1-4-d: backlog
  1-5-e:
    status: backlog
    depends_on: [1-4]
  epic-1-retrospective: optional

story_dependencies:
  1-2-b: [1-1]
  1-3-c:
    - 1-2
  1-4-d: []   # explicitly independent
EOF
commit_all "$P"
PLAN="$(SH "$P" plan --json)"
st() { echo "$PLAN" | jq_py "[s for s in d['stories'] if s['key']=='$1'][0]['$2']"; }
[ "$(st 1-2-b state)" = ready ] && [ "$(st 1-2-b deps)" = "['1-1']" ] && ok "D1 story_dependencies read, satisfied dep → ready" || bad "D1 $(st 1-2-b state) $(st 1-2-b deps)"
[ "$(st 1-3-c state)" = waiting ] && echo "$(st 1-3-c reasons)" | grep -q '等待依赖 1-2-b' && ok "D2 block-list form, unmet dep waits" || bad "D2 $(st 1-3-c reasons)"
[ "$(st 1-4-d state)" = ready ] && ok "D3 [] = independent (not serial fallback)" || bad "D3 $(st 1-4-d reasons)"
[ "$(st 1-5-e deps)" = "['1-4']" ] && ok "D4 block depends_on still read" || bad "D4 $(st 1-5-e deps)"
printf 'deps_overrides:\n  1-3-c: []\n' > "$P/.claude/harness/parallel.yaml"
PLAN="$(SH "$P" plan --json)"
[ "$(st 1-3-c state)" = ready ] && ok "D5 deps_overrides beats story_dependencies" || bad "D5 $(st 1-3-c reasons)"
rm -f "$P/.claude/harness/parallel.yaml"

echo "== S: run-inline next honours declared deps"
OUT="$(SS "$P" next 2>/dev/null)"; [ "$OUT" = 1-2-b ] && ok "S1 next = first backlog with deps met" || bad "S1 next=$OUT"
(cd "$P" && python3 .claude/harness/scripts/sprint-status.py set 1-2-b in-progress >/dev/null)
OUT="$(SS "$P" next 2>/dev/null)"; [ "$OUT" = 1-4-d ] && ok "S2 next skips 1-3-c (waits for 1-2-b)" || bad "S2 next=$OUT"
OUT="$(SS "$P" next-in-epic 1 2>/dev/null)"; [ "$OUT" = 1-4-d ] && ok "S3 next-in-epic same rule" || bad "S3 $OUT"
(cd "$P" && python3 .claude/harness/scripts/sprint-status.py set 1-4-d in-progress >/dev/null)
ERR="$(SS "$P" next 2>&1 >/dev/null)"; RC=$?
[ "$RC" = 1 ] && echo "$ERR" | grep -q '^waiting=.*1-3-c(1-2-b)' && echo "$ERR" | grep -q '1-5-e(1-4-d)' \
    && ok "S4 all backlog blocked → exit 1 + waiting= on stderr" || bad "S4 rc=$RC err=$ERR"

echo "== E: ext- conditions"
P="$(new_proj e '')"
cat > "$P/$ART/sprint-status.yaml" <<'EOF'
development_status:
  epic-1: in-progress
  1-1-a: backlog
  1-2-b: backlog
  epic-1-retrospective: optional
story_dependencies:
  1-1-a: [ext-contract-signoff]
  1-2-b: []
EOF
commit_all "$P"
PLAN="$(SH "$P" plan --json)"
[ "$(st 1-1-a state)" = waiting ] && [ "$(st 1-1-a external)" = "['ext-contract-signoff']" ] \
    && echo "$(st 1-1-a reasons)" | grep -q '等待外部条件 ext-contract-signoff' && ok "E1 ext- dep waits, listed as external" || bad "E1 $(st 1-1-a reasons)"
TICK="$(SH "$P" tick)"
echo "$TICK" | jq_py "d['external']" | grep -q "ext-contract-signoff" && ok "E2 tick lists external conditions" || bad "E2"
SH "$P" board 2>/dev/null | grep -q '等待外部条件' && ok "E3 board has an external-conditions section" || bad "E3"
OUT="$(SS "$P" next 2>/dev/null)"; [ "$OUT" = 1-2-b ] && ok "E4 run-inline next skips ext- waiting story" || bad "E4 next=$OUT"

echo "== K: parked_statuses"
P="$(new_proj k 'parked_statuses: [mainline-pending, spec-pending]')"
cat > "$P/$ART/sprint-status.yaml" <<'EOF'
development_status:
  epic-1: in-progress
  1-1-a: done
  1-2-b: mainline-pending
  1-3-c: spec-pending
  epic-1-retrospective: optional
  epic-2: backlog
  2-1-x: backlog
  epic-2-retrospective: optional
  epic-3: backlog
  3-1-y: mainline-pending
  epic-3-retrospective: optional
EOF
commit_all "$P"
PLAN="$(SH "$P" plan --json)"
[ "$(st 1-2-b state)" = parked ] && ok "K1 parked status → state parked" || bad "K1 $(st 1-2-b state)"
echo "$PLAN" | jq_py "d['retro_due']" | grep -qx '\[1\]' && ok "K2 retro due for epic 1 (done + parked), not for all-parked epic 3" || bad "K2 $(echo "$PLAN" | jq_py "d['retro_due']")"
REAS="$(st 2-1-x reasons)"
echo "$REAS" | grep -q 'epic 1 还有未完成' && bad "K3 parked stories hold the epic barrier: $REAS" || ok "K3 parked stories don't hold the epic barrier"
echo "$REAS" | grep -q 'epic 1 的 retro 还没 done' && ok "K4 retro_barrier still waits for epic 1 retro" || bad "K4 $REAS"
TICK="$(SH "$P" tick)"
[ "$(echo "$TICK" | jq_py "d['next_action']")" = retro ] && echo "$TICK" | jq_py "d['parked']" | grep -q '1-2-b' \
    && ok "K5 tick: next_action=retro, parked listed" || bad "K5 $(echo "$TICK" | jq_py "d['next_action']")"
SS "$P" epic-all-done 1 >/dev/null 2>"$TMP/k6.err"; RC=$?
[ "$RC" = 0 ] && grep -q '^parked=1-2-b(mainline-pending),1-3-c(spec-pending)' "$TMP/k6.err" && ok "K6 epic-all-done 0 with parked= note" || bad "K6 rc=$RC $(cat "$TMP/k6.err")"
SS "$P" epic-all-done 3 >/dev/null 2>"$TMP/k7.err"; RC=$?
[ "$RC" = 1 ] && grep -q '没有 done 的 story' "$TMP/k7.err" && ok "K7 all-parked epic: epic-all-done 1" || bad "K7 rc=$RC"
OUT="$(SS "$P" open-epics)"
TAB="$(printf '\t')"
echo "$OUT" | grep -qx "1${TAB}optional${TAB}all-done" && echo "$OUT" | grep -qx "2${TAB}optional${TAB}active" && echo "$OUT" | grep -qx "3${TAB}optional${TAB}parked" \
    && ok "K8 open-epics: all-done / active / parked" || bad "K8 $OUT"
# only parked stories left anywhere → finished, not stalled
P2="$(new_proj k2 'parked_statuses: [mainline-pending]')"
cat > "$P2/$ART/sprint-status.yaml" <<'EOF'
development_status:
  epic-1: in-progress
  1-1-a: done
  1-2-b: mainline-pending
  epic-1-retrospective: done
EOF
commit_all "$P2"
P="$P2"; TICK="$(SH "$P" tick)"
[ "$(echo "$TICK" | jq_py "d['next_action']")" = finished ] && ok "K9 only parked left → finished" || bad "K9 $(echo "$TICK" | jq_py "d['next_action']")"

echo "== B: epic_barrier false"
P="$(new_proj b '')"
cat > "$P/$ART/sprint-status.yaml" <<'EOF'
development_status:
  epic-1: in-progress
  1-1-a: backlog
  epic-1-retrospective: optional
  epic-2: backlog
  2-1-x: backlog
  epic-2-retrospective: optional
story_dependencies:
  1-1-a: []
  2-1-x: []
EOF
commit_all "$P"
PLAN="$(SH "$P" plan --json)"
[ "$(st 2-1-x state)" = waiting ] && ok "B1 default: epic barrier holds 2-1-x" || bad "B1 $(st 2-1-x state)"
printf 'epic_barrier: false\n' > "$P/.claude/harness/parallel.yaml"
PLAN="$(SH "$P" plan --json)"
[ "$(st 2-1-x state)" = ready ] && ok "B2 epic_barrier: false → cross-epic parallel" || bad "B2 $(st 2-1-x reasons)"

echo "== R: harness-commit retro with parked stories"
P="$(new_proj r 'parked_statuses: [mainline-pending]')"
cat > "$P/$ART/sprint-status.yaml" <<'EOF'
development_status:
  epic-9: in-progress
  9-1-foo: done
  9-2-bar: mainline-pending
  9-3-baz: wont-do
  epic-9-retrospective: optional
EOF
printf -- '---\nepic: 9\nverdict: rejected\n---\n# retro\n' > "$P/$ART/epic-9-retro-2026-11-05.md"
commit_all "$P"
OUT="$(cd "$P" && python3 .claude/harness/scripts/harness-commit.py 6-done 9-1-foo --epic 9 2>&1)"
echo "$OUT" | grep -qx 'EPIC_PARKED=9-2-bar(mainline-pending)' && echo "$OUT" | grep -qx 'EPIC_WONT_DO=9-3-baz' \
    && ok "R1 EPIC_PARKED= reported apart from EPIC_WONT_DO=" || bad "R1 $OUT"
(cd "$P" && python3 - <<'PY'
import importlib.util
spec = importlib.util.spec_from_file_location("hc", ".claude/harness/scripts/harness-commit.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m._sync_sprint_status_for_stage("6", "9-1-foo", "9")
PY
) >/dev/null 2>&1
[ "$(SS "$P" status epic-9-retrospective)" = done ] && [ "$(SS "$P" status epic-9)" = in-progress ] \
    && ok "R2 stage 6: retro → done, epic stays in-progress while stories are parked" || bad "R2 retro=$(SS "$P" status epic-9-retrospective) epic=$(SS "$P" status epic-9)"
(cd "$P" && python3 .claude/harness/scripts/sprint-status.py set 9-2-bar done >/dev/null && python3 .claude/harness/scripts/sprint-status.py set epic-9-retrospective optional >/dev/null)
(cd "$P" && python3 - <<'PY'
import importlib.util
spec = importlib.util.spec_from_file_location("hc", ".claude/harness/scripts/harness-commit.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m._sync_sprint_status_for_stage("6", "9-1-foo", "9")
PY
) >/dev/null 2>&1
[ "$(SS "$P" status epic-9)" = done ] && ok "R3 nothing parked → stage 6 marks epic done" || bad "R3 epic=$(SS "$P" status epic-9)"

echo "== F: flatten-deps + deps-migrate commit"
P="$(new_proj f '')"
F="$P/$ART/sprint-status.yaml"
cat > "$F" <<'EOF'
development_status:
  epic-1: in-progress
  1-1-a:
    status: done
    depends_on: []
  1-2-b:   # keep me
    status: backlog
    depends_on:
      - 1-1
      - ext-sign
  1-3-c: backlog
  epic-1-retrospective: optional

story_dependencies:
  1-3-c: [1-2]
EOF
commit_all "$P"
snap() { SH "$P" plan --json | jq_py "[(s['key'], s['state'], s['deps']) for s in d['stories']]"; }
BEFORE="$(snap)"
SS "$P" flatten-deps --check >/dev/null; RC=$?
[ "$RC" = 3 ] && ok "F1 --check reports block layout (rc 3)" || bad "F1 rc=$RC"
SS "$P" flatten-deps >/dev/null; RC=$?
if grep -qx '  1-1-a: done' "$F" && grep -qx '  1-2-b: backlog  # keep me' "$F" \
   && grep -qxF '  1-2-b: [1-1, ext-sign]' "$F" && grep -qxF '  1-3-c: [1-2]' "$F" \
   && [ "$(grep -c '^story_dependencies:' "$F")" = 1 ]; then
    ok "F2 blocks flattened, deps merged into the existing story_dependencies"
else
    bad "F2 rc=$RC"; cat "$F"
fi
AFTER="$(snap)"
[ "$BEFORE" = "$AFTER" ] && ok "F3 scheduling unchanged by the rewrite" || bad "F3 before=$BEFORE after=$AFTER"
SS "$P" flatten-deps --check >/dev/null; RC=$?
[ "$RC" = 0 ] && ok "F4 idempotent (--check rc 0 after rewrite)" || bad "F4 rc=$RC"
OUT="$(cd "$P" && python3 .claude/harness/scripts/harness-commit.py deps-migrate - 2>&1)"; RC=$?
[ "$RC" = 0 ] && echo "$OUT" | grep -q '^STATUS=ok' && ok "F5 harness-commit deps-migrate stages sprint-status" || bad "F5 rc=$RC $OUT"
cat > "$F" <<'EOF'
development_status:
  1-1-a:
    status: backlog
    owner: alice
EOF
SS "$P" flatten-deps >/dev/null 2>"$TMP/f6.err"; RC=$?
[ "$RC" = 4 ] && grep -q '^PROBLEM=1-1-a' "$TMP/f6.err" && grep -q 'owner: alice' "$F" \
    && ok "F6 unknown nested field → refuse, file untouched" || bad "F6 rc=$RC"

echo ""
echo "parked_deps_test: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]

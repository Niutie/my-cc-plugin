#!/usr/bin/env bash
# superh_test.sh — super-harness 调度层回归测试（不调用真实 claude）。
#
# 在临时目录建一个伪下游项目：harness 脚本以「未入库 + gitignore」方式部署
# （覆盖 copy_paths 补齐路径），sprint-status 用 BMad 多行块格式带 depends_on。
# 用一个假的 claude 可执行文件扮演 worker：读 stdin、在 lane worktree 里模拟
# bmad-build-auto 的提交（含 sprint-status / deferred-work 改动）、打 tag、调用
# `superh.py report`，并输出 stream-json 事件。
#
# 覆盖：
#   P*  plan / tick 的就绪判定（depends_on、串行回退、epic 屏障）
#   L*  prepare + launch + report 全链路，lane 阶段推导
#   I*  两路并行合流：第一路 ff，第二路 rebase + 账本冲突自动消解 + tag 搬迁 +
#       worktree 内 build-verify
#   V*  合流验证门：没 rebase 的 lane 跳过；rebase 过的 lane 验证失败 → held、
#       sprint 分支不动；在 lane 里修好并 commit 后重跑 integrate 合入
#   C*  真代码冲突 → exit 3 → 人工解决后 integrate 续跑
#   X*  mark / cleanup / abandon
#
# 用法：bash superh_test.sh   （从 plugin 源码树运行，脚本取同目录的 harness 脚本）

# No pipefail: assertions are `echo "$OUT" | grep -q ...`, and grep -q exits on the
# first match — the writer may then take SIGPIPE, which pipefail would turn into a
# spurious failure (seen as an intermittent M6).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$HERE/.." && pwd)"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }

# pwd -P: on macOS mktemp lives under /var -> /private/var; git reports the
# resolved path, so compare against the physical one.
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
PROJ="$TMP/proj"
mkdir -p "$PROJ"
cd "$PROJ"

git init -q -b sprint .
git config user.email t@example.com
git config user.name Tester
git config commit.gpgsign false
git config tag.gpgsign false

ART=_bmad-output/implementation-artifacts
mkdir -p "$ART" src .claude/harness/scripts .claude/harness/prompts
cp "$PLUGIN_DIR"/scripts/*.py "$PLUGIN_DIR"/scripts/*.sh .claude/harness/scripts/
cat > .claude/harness/harness-project-config.yaml <<'EOF'
project_display_name: 'Fixture'
artifacts_root: '_bmad-output/implementation-artifacts'
EOF
cp "$PLUGIN_DIR/prompts/"*.md .claude/harness/prompts/

# fake claude: acts as the worker inside the lane worktree
FAKE="$TMP/fake-claude"
cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null   # consume prompt
echo '{"type":"system","subtype":"init","session_id":"sess-'"$SUPERH_KEY"'"}'
KEY="$SUPERH_KEY"
ART=_bmad-output/implementation-artifacts
MODE="$(cat "$SUPERH_MAIN_ROOT/.fake-mode-$KEY" 2>/dev/null || echo ok)"
git tag "harness/$KEY/start"
case "$MODE" in
  blocked)
    python3 "$SUPERH_MAIN_ROOT/.claude/harness/scripts/superh.py" report "$KEY" --status blocked --summary "bmad-build-auto HALT: intent gap"
    echo '{"type":"result","result":"blocked","is_error":false}'
    exit 0 ;;
  silent)
    echo '{"type":"result","result":"forgot to report","is_error":false}'
    exit 0 ;;
esac
# "implementation"
case "$MODE" in
  conflict) printf 'shared line from %s\n' "$KEY" > src/shared.txt ;;
  *)        printf 'code for %s\n' "$KEY" > "src/$KEY.txt" ;;
esac
# bmad-build-auto touching the shared ledgers
python3 - "$ART/sprint-status.yaml" "$KEY" <<'PY'
import sys, re
p, key = sys.argv[1], sys.argv[2]
t = open(p, encoding="utf-8").read()
t = re.sub(r"(\n  %s:\n    status: )backlog" % re.escape(key), r"\1review", t)
t = re.sub(r"last_updated: .*", "last_updated: build-of-%s" % key, t)
open(p, "w", encoding="utf-8").write(t)
PY
printf -- '- FU-%s.A1 from build of %s\n' "$KEY" "$KEY" >> "$ART/deferred-work.md"
printf 'epic context compiled while building %s\n' "$KEY" > "$ART/epic-1-context.md"
cat > "$ART/spec-$KEY.md" <<SPEC
---
status: done
baseline_revision: $(git rev-parse HEAD)
followup_review_recommended: false
---
# spec $KEY

## Auto Run Result

Status: done
SPEC
git add -A
git commit -qm "feat($KEY): implement"
git tag "harness/$KEY/built"
python3 .claude/harness/scripts/harness-commit.py build-verify "$KEY" > "$SUPERH_MAIN_ROOT/.bv-$KEY.log" 2>&1 || true
python3 "$SUPERH_MAIN_ROOT/.claude/harness/scripts/superh.py" report "$KEY" --status ready --summary "built ok"
echo '{"type":"result","result":"done","is_error":false,"total_cost_usd":0.01,"num_turns":3}'
EOF
chmod +x "$FAKE"

cat > .claude/harness/parallel.yaml <<EOF
max_slots: 2
no_deps_policy: serial
worktree_root: '$TMP/wt'
claude_bin: '$FAKE'
copy_paths: [.claude/harness]
EOF

cat > "$ART/sprint-status.yaml" <<'EOF'
generated: 2026-11-01
last_updated: 2026-11-01
development_status:
  epic-1:
    status: backlog
  1-1-alpha:
    status: backlog
    depends_on: []
  1-2-beta:
    status: backlog
    depends_on: []
  1-3-gamma:
    status: backlog
    depends_on: [1-1-alpha]
  1-4-delta:
    status: backlog
  epic-1-retrospective:
    status: optional
  epic-2:
    status: backlog
  2-1-epsilon:
    status: backlog
    depends_on:
      - 1.2
EOF
printf '# deferred work\n' > "$ART/deferred-work.md"
mkdir -p _bmad/custom
cat > _bmad/custom/bmad-build-auto.toml <<'EOF'
[workflow]
[[workflow.review_layers]]
id = "codex-cross-model"
instruction = "run /codex:adversarial-review on the diff"
EOF
printf 'base\n' > src/shared.txt
printf '.claude/\n.fake-mode-*\n.bv-*\n' > .gitignore
git add -A
git commit -qm "init"

SH="python3 $PROJ/.claude/harness/scripts/superh.py"
result_edit() {  # result_edit <KEY> '<python statements on d>'
python3 - "$(git rev-parse --git-common-dir)/super-harness/lanes/$1.result.json" "$2" <<'PY'
import json, sys
p, code = sys.argv[1], sys.argv[2]
d = json.load(open(p)); exec(code); json.dump(d, open(p, "w"))
PY
}
PM() { $SH postmerge "$1" | sed -n 's/^NEXT=//p'; }
lane_edit() {  # lane_edit <KEY> '<python statements on d>' — simulate an interrupted dispatcher
python3 - "$(git rev-parse --git-common-dir)/super-harness/lanes/$1.json" "$2" <<'PY'
import json, sys
p, code = sys.argv[1], sys.argv[2]
d = json.load(open(p)); exec(code); json.dump(d, open(p, "w"))
PY
}
jget() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1"; }

echo "== P: readiness"
$SH start-run >/dev/null
TICK="$($SH tick)"
LAUNCH="$(echo "$TICK" | jget 'd["launch"]')"
[ "$LAUNCH" = "['1-1-alpha', '1-2-beta']" ] && ok "P1 two independent stories ready, capped by slots" || bad "P1 launch=$LAUNCH"
PLAN="$($SH plan --json)"
echo "$PLAN" | jget '[s for s in d["stories"] if s["key"]=="1-3-gamma"][0]["reasons"]' | grep -q '等待依赖 1-1-alpha' \
    && ok "P2 explicit depends_on waits" || bad "P2 gamma reasons"
echo "$PLAN" | jget '[s for s in d["stories"] if s["key"]=="1-4-delta"][0]["reasons"]' | grep -q '串行' \
    && ok "P3 missing depends_on falls back to serial" || bad "P3 delta reasons"
echo "$PLAN" | jget '[s for s in d["stories"] if s["key"]=="2-1-epsilon"][0]["reasons"]' | grep -q 'epic 1' \
    && ok "P4 epic barrier" || bad "P4 epsilon reasons"
[ "$(echo "$TICK" | jget 'd["epic_start"]')" = "[1]" ] && ok "P5 epic_start flags first epic" || bad "P5 epic_start"

echo "== L: prepare + launch"
for k in 1-1-alpha 1-2-beta; do
    OUT="$($SH prepare $k)"; echo "$OUT" | grep -q '^STATUS=ok' && ok "L1 prepare $k" || { bad "L1 prepare $k"; echo "$OUT"; }
done
check "L2 copied untracked .claude/harness into worktree" test -f "$TMP/wt/1-1-alpha/.claude/harness/scripts/harness-commit.py"
[ -z "$(git -C "$TMP/wt/1-1-alpha" status --porcelain -uall)" ] && ok "L3 lane worktree clean" || bad "L3 lane worktree dirty"
[ "$(echo "$($SH tick)" | jget 'd["slots"]["free"]')" = "0" ] && ok "L4 prepared lanes hold slots" || bad "L4 slots"
$SH launch 1-1-alpha > "$TMP/l1.out" &
$SH launch 1-2-beta > "$TMP/l2.out" &
wait
grep -q '^STAGE=ready' "$TMP/l1.out" && ok "L5 lane alpha ready" || { bad "L5 alpha"; cat "$TMP/l1.out"; cat "$PROJ/.bv-1-1-alpha.log"; }
grep -q '^STAGE=ready' "$TMP/l2.out" && ok "L6 lane beta ready" || { bad "L6 beta"; cat "$TMP/l2.out"; }
grep -q '^SESSION=sess-1-1-alpha' "$TMP/l1.out" && ok "L7 session id captured from stream" || bad "L7 session"
grep -q '^STATUS=ok' "$PROJ/.bv-1-1-alpha.log" && ok "L8 build-verify passes inside lane worktree" || { bad "L8"; cat "$PROJ/.bv-1-1-alpha.log"; }
TICK="$($SH tick)"
[ "$(echo "$TICK" | jget 'd["next_action"]')" = "integrate" ] && ok "L9 next_action=integrate" || bad "L9 $(echo "$TICK" | jget 'd["next_action"]')"

echo "== I: integrate"
OLD_BUILT_BETA="$(git rev-parse harness/1-2-beta/built)"
# verify gate: passes only once beta's lane carries the "fixed" commit (see V*)
cat >> .claude/harness/parallel.yaml <<'EOF2'
verify_command: 'grep -q fixed "$SUPERH_WORKTREE/src/1-2-beta.txt"'
EOF2
OUT="$($SH integrate 1-1-alpha)"; RC=$?
[ $RC -eq 0 ] && ok "I1 alpha integrates (ff)" || { bad "I1 rc=$RC"; echo "$OUT"; }
echo "$OUT" | grep -qx 'VERIFY=skipped-not-rebased' && ok "V1 lane not rebased → verify skipped" || { bad "V1"; echo "$OUT"; }
[ "$(git rev-parse HEAD)" = "$(git rev-parse story/1-1-alpha)" ] && ok "I2 sprint branch fast-forwarded" || bad "I2"
# R: the dispatcher died after the ff but before recording `merged` (no-rebase path).
# Worst case: nothing about the merge was persisted. A re-run must not move start.
START_ALPHA="$(git rev-parse harness/1-1-alpha/start)"
lane_edit 1-1-alpha 'd["phase"]="launched"; [d.pop(k, None) for k in ("merged_head","merged_at","onto","rebased")]'
echo "$($SH tick)" | jget 'd["integrate"]' | grep -q '1-1-alpha' && ok "R1 un-recorded ff lane is routed to integrate" || bad "R1"
OUT="$($SH integrate 1-1-alpha)"; RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -q '^RECOVERED=already-merged' && ok "R2 integrate recognises the completed ff" || { bad "R2 rc=$RC"; echo "$OUT"; }
[ "$(git rev-parse harness/1-1-alpha/start)" = "$START_ALPHA" ] && [ "$START_ALPHA" != "$(git rev-parse HEAD)" ] \
    && ok "R3 start tag untouched (audit range not collapsed)" || bad "R3 start moved to $(git rev-parse harness/1-1-alpha/start)"
echo "$OUT" | sed -n '/BUILD_VERIFY<</,/>>/p' | grep -q 'STATUS=ok' && ok "R4 build-verify still sees the story's commits" || { bad "R4"; echo "$OUT"; }
[ "$(echo "$($SH tick)" | jget 'd["next_action"]')" = "post-merge" ] && ok "I3 merged lane → post-merge first" || bad "I3"
# close-out (run.md §4), driven by postmerge; interrupted between commit and tag
[ "$(PM 1-1-alpha)" = "sync" ] && ok "M1 postmerge: fresh merge → sync" || bad "M1 $($SH postmerge 1-1-alpha)"
python3 .claude/harness/scripts/harness-commit.py build-sync 1-1-alpha > "$TMP/bs.out" 2>&1; BS=$?
if [ $BS -eq 0 ]; then git commit -qm "story(1-1-alpha): sync sprint status & deferred ledger"; fi
[ "$(PM 1-1-alpha)" = "tag" ] && ok "M2 committed but untagged → tag (no second build-sync)" || bad "M2 $($SH postmerge 1-1-alpha)"
git tag harness/1-1-alpha/done
[ "$(PM 1-1-alpha)" = "finish" ] && ok "M3 tagged → finish (no test step)" || bad "M3 $($SH postmerge 1-1-alpha)"
[ "$($SH mark 1-1-alpha --phase done | head -1)" = "STATUS=ok" ] && ok "I4 mark done after done tag" || bad "I4"
grep -A1 '1-1-alpha:' "$ART/sprint-status.yaml" | grep -q 'status: done' && ok "I5 build-sync set alpha done" || { bad "I5"; cat "$TMP/bs.out"; }

SPRINT_BEFORE="$(git rev-parse HEAD)"
OUT="$($SH integrate 1-2-beta)"; RC=$?
[ $RC -eq 1 ] && echo "$OUT" | grep -qx 'VERIFY=failed' && echo "$OUT" | grep -q '^REASON=合流后验证不通过' \
    && ok "V2 rebased lane fails verify_command → halt" || { bad "V2 rc=$RC"; echo "$OUT"; }
[ "$(git rev-parse HEAD)" = "$SPRINT_BEFORE" ] && ok "V3 sprint branch untouched on verify failure" || bad "V3"
[ "$($SH board --json | jget '[x["stage"] for x in d if x["key"]=="1-2-beta"][0]')" = "held" ] \
    && ok "V4 lane held" || bad "V4"
$SH tick | jget 'd["attention"]' | grep -q 'superh.py integrate 1-2-beta' \
    && ok "V5 takeover hint says fix, commit, re-run integrate" || { bad "V5"; $SH tick; }
WT_BETA="$TMP/wt/1-2-beta"
echo fixed >> "$WT_BETA/src/1-2-beta.txt" && git -C "$WT_BETA" commit -qam "fix(1-2-beta): make verify pass"
OUT="$($SH integrate 1-2-beta)"; RC=$?
[ $RC -eq 0 ] && ok "I6 beta integrates after rebase + fix" || { bad "I6 rc=$RC"; echo "$OUT"; }
echo "$OUT" | grep -qx 'VERIFY=passed' && ok "V6 verify passes after the fix" || { bad "V6"; echo "$OUT"; }
echo "$OUT" | grep -q 'NOTE=auto-resolved: .*sprint-status.yaml' && ok "I7 sprint-status conflict auto-resolved" || { bad "I7"; echo "$OUT"; }
echo "$OUT" | grep -q 'NOTE=auto-resolved: .*deferred-work.md (union' && ok "I8 deferred-work union-merged" || bad "I8"
grep -q 'FU-1-1-alpha.A1' "$ART/deferred-work.md" && grep -q 'FU-1-2-beta.A1' "$ART/deferred-work.md" \
    && ok "I9 both ledger entries kept" || bad "I9"
NEW_BUILT_BETA="$(git rev-parse harness/1-2-beta/built)"
[ "$NEW_BUILT_BETA" != "$OLD_BUILT_BETA" ] && git merge-base --is-ancestor "$NEW_BUILT_BETA" HEAD \
    && ok "I10 built tag carried onto rebased commit" || bad "I10"
[ "$(git rev-parse harness/1-2-beta/start)" = "$(git rev-parse 'story/1-2-beta~2')" ] \
    && ok "I11 start tag moved to rebase base" || bad "I11"
[ -z "$(git branch --list 'super-harness-tmp/*')" ] && ok "I12 temp branches removed" || bad "I12"
grep -A1 '1-1-alpha:' "$ART/sprint-status.yaml" | grep -q 'status: done' && ok "I13 sprint branch ledger kept alpha=done" || bad "I13"
echo "$OUT" | grep -q '^STATUS=ok' && echo "$OUT" | sed -n '/BUILD_VERIFY<</,/>>/p' | grep -q 'STATUS=ok' \
    && ok "I14 post-rebase build-verify ok" || bad "I14"
# R: same interruption on the rebase path (onto was persisted before the rebase).
START_BETA="$(git rev-parse harness/1-2-beta/start)"
lane_edit 1-2-beta 'd["phase"]="integrating"; d.pop("merged_head", None)'
OUT="$($SH integrate 1-2-beta)"; RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -q '^RECOVERED=' && [ "$(git rev-parse harness/1-2-beta/start)" = "$START_BETA" ] \
    && ok "R5 rebased lane recovered without moving start" || { bad "R5 rc=$RC"; echo "$OUT"; }
result_edit 1-2-beta 'd["codex_skip_reason"] = "quota_exhausted"'
OUT="$($SH postmerge 1-2-beta)"
echo "$OUT" | grep -qx 'NEXT=sync' && echo "$OUT" | grep -qx 'MARKER=write' && ok "M5 codex skipped → marker to write" || { bad "M5"; echo "$OUT"; }
MK="$ART/1-2-beta.codex-skipped.json"
printf '{"key":"1-2-beta","reason":"quota_exhausted","skipped_at":"2026-11-02T00:00:00Z"}\n' > "$MK"
OUT="$($SH postmerge 1-2-beta)"
echo "$OUT" | grep -qx 'MARKER=present' && ok "M6 existing marker → present (never rewritten)" || { bad "M6"; echo "$OUT"; }
# W: the session dies inside the sync step — restart must resume, not halt on a dirty tree
OUT="$($SH start-run)"
echo "$OUT" | grep -qx 'MAIN_CLEAN=resumable' && echo "$OUT" | grep -qx 'RESUMABLE_LANES=1-2-beta' \
    && ok "W1 marker written, not committed → resumable" || { bad "W1"; echo "$OUT"; }
python3 .claude/harness/scripts/harness-commit.py build-sync 1-2-beta >/dev/null 2>&1   # staged, then "crash"
OUT="$($SH start-run)"
echo "$OUT" | grep -qx 'MAIN_CLEAN=resumable' && [ "$(PM 1-2-beta)" = "sync" ] \
    && ok "W2 build-sync staged, not committed → resumable, postmerge says sync" || { bad "W2"; echo "$OUT"; }
echo junk > src/unrelated.txt
OUT="$($SH start-run)"
echo "$OUT" | grep -qx 'MAIN_CLEAN=false' && ok "W3 any unrelated dirty file still halts" || { bad "W3"; echo "$OUT"; }
rm -f src/unrelated.txt
python3 .claude/harness/scripts/harness-commit.py build-sync 1-2-beta > "$TMP/bs2.out" 2>&1 && git commit -qm "story(1-2-beta): sync"
grep -q '^STATUS=ok' "$TMP/bs2.out" && [ -z "$(git status --porcelain)" ] \
    && ok "W4 re-running build-sync absorbs the leftovers and commits" || { bad "W4"; cat "$TMP/bs2.out"; }
git ls-files --error-unmatch "$MK" >/dev/null 2>&1 && ok "M7 build-sync commits the marker" || bad "M7"
git tag harness/1-2-beta/done
[ "$(PM 1-2-beta)" = "finish" ] && ok "M8 marker + tag done → finish" || bad "M8"
$SH mark 1-2-beta --phase done >/dev/null

echo "== C: code conflict"
TICK="$($SH tick)"
echo "$TICK" | jget 'd["launch"]' | grep -q '1-3-gamma' && ok "C0 gamma ready once alpha is done" || bad "C0 $(echo "$TICK" | jget 'd["launch"]')"
echo conflict > .fake-mode-1-3-gamma
$SH prepare 1-3-gamma >/dev/null
printf 'sprint edit\n' > src/shared.txt && git commit -qam "hotfix on sprint"
$SH launch 1-3-gamma >/dev/null
OUT="$($SH integrate 1-3-gamma)"; RC=$?
[ $RC -eq 3 ] && echo "$OUT" | grep -q 'CONFLICT_FILE=src/shared.txt' && ok "C1 code conflict → exit 3" || { bad "C1 rc=$RC"; echo "$OUT"; }
[ "$(echo "$($SH tick)" | jget 'd["attention"][0]["stage"]')" = "conflict" ] && ok "C2 board shows conflict" || bad "C2"
WT="$TMP/wt/1-3-gamma"
printf 'sprint edit\nshared line from 1-3-gamma\n' > "$WT/src/shared.txt"
git -C "$WT" add src/shared.txt   # resolved by hand; `rebase --continue` deliberately left to the dispatcher
TICK="$($SH tick)"
[ "$(echo "$TICK" | jget 'd["integrate"]')" = "['1-3-gamma']" ] && [ "$(echo "$TICK" | jget 'len(d["attention"])')" = "0" ] \
    && ok "C3 tick alone routes a hand-resolved conflict back to integrate" || { bad "C3"; echo "$TICK"; }
OUT="$($SH integrate 1-3-gamma)"; RC=$?
[ $RC -eq 0 ] && grep -q 'shared line from 1-3-gamma' src/shared.txt && grep -q 'sprint edit' src/shared.txt \
    && ok "C3b integrate finishes the rebase and merges" || { bad "C3b rc=$RC"; echo "$OUT"; }
START_GAMMA="$(git rev-parse harness/1-3-gamma/start)"

python3 - "$(git rev-parse --git-common-dir)/super-harness/lanes/1-3-gamma.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["phase"] = "integrating"; json.dump(d, open(p, "w"))
PY
[ "$($SH tick | jget 'd["integrate"]')" = "['1-3-gamma']" ] && ok "C4 lane stuck in integrating is routed back" || bad "C4"
OUT="$($SH integrate 1-3-gamma)"; RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -q '^STATUS=ok' && [ "$(git rev-parse harness/1-3-gamma/start)" = "$START_GAMMA" ] \
    && ok "C5 re-running integrate on a merged-but-integrating lane is idempotent" || { bad "C5 rc=$RC"; echo "$OUT"; }

result_edit 1-3-gamma 'd["codex_skip_reason"] = "not_installed"'
git rm -q _bmad/custom/bmad-build-auto.toml && git commit -qm "project without a codex build layer"
OUT="$($SH postmerge 1-3-gamma)"
echo "$OUT" | grep -qx 'NEXT=sync' && echo "$OUT" | grep -qx 'HARNESS_STATE=codex' \
    && ok "M10 no codex layer + marker pending: harness-state 'codex' still routes to sync" || { bad "M10"; echo "$OUT"; }

echo "== X: lifecycle"
OUT="$($SH cleanup 1-3-gamma)"; echo "$OUT" | grep -q 'STATUS=halt' && ok "X1 cleanup refuses non-done lane" || bad "X1"
$SH cleanup 1-1-alpha >/dev/null
[ ! -d "$TMP/wt/1-1-alpha" ] && ! git rev-parse --verify --quiet story/1-1-alpha >/dev/null && ok "X2 cleanup removes worktree + branch" || bad "X2"
echo blocked > .fake-mode-1-4-delta
# delta is serial-gated behind gamma (not done yet); prepare manually to test the blocked path
$SH prepare 1-4-delta >/dev/null && $SH launch 1-4-delta >/dev/null
[ "$($SH board --json | jget '[x["stage"] for x in d if x["key"]=="1-4-delta"][0]')" = "blocked" ] && ok "X3 blocked report surfaces" || bad "X3"
$SH retry 1-4-delta >/dev/null && echo silent > .fake-mode-1-4-delta
git tag -d harness/1-4-delta/start >/dev/null
$SH launch 1-4-delta >/dev/null
[ "$($SH board --json | jget '[x["stage"] for x in d if x["key"]=="1-4-delta"][0]')" = "failed" ] && ok "X4 exit without report → failed" || bad "X4"
OUT="$($SH abandon 1-4-delta)"; echo "$OUT" | grep -q 'STATUS=halt' && ok "X5 abandon needs --yes" || bad "X5"
$SH abandon 1-4-delta --yes >/dev/null
! git rev-parse --verify --quiet harness/1-4-delta/start >/dev/null && [ ! -d "$TMP/wt/1-4-delta" ] \
    && ok "X6 abandon drops worktree + tags" || bad "X6"
$SH board >/dev/null && ok "X7 board renders" || bad "X7"

echo "== Q: interrupted prepare / launch"
$SH prepare 9-3-prep >/dev/null
lane_edit 9-3-prep 'd["phase"] = "preparing"'
echo "$($SH tick)" | jget 'd["launch"]' | grep -q '9-3-prep' && ok "Q1 interrupted prepare is routed back to prepare" || bad "Q1"
OUT="$($SH prepare 9-3-prep)"
echo "$OUT" | grep -q '^ROLLED_BACK=' && echo "$OUT" | grep -q '^STATUS=ok' && [ -d "$TMP/wt/9-3-prep" ] \
    && ok "Q2 prepare rolls back and redoes it" || { bad "Q2"; echo "$OUT"; }
$SH abandon 9-3-prep --yes >/dev/null
$SH prepare 9-4-prep >/dev/null
echo stray > "$TMP/wt/9-4-prep/src/stray.txt" && git -C "$TMP/wt/9-4-prep" add -A && git -C "$TMP/wt/9-4-prep" commit -qm stray
lane_edit 9-4-prep 'd["phase"] = "preparing"'
OUT="$($SH prepare 9-4-prep)"
echo "$OUT" | grep -q '^STATUS=halt' && [ -d "$TMP/wt/9-4-prep" ] \
    && [ "$($SH board --json | jget '[x["stage"] for x in d if x["key"]=="9-4-prep"][0]')" = "held" ] \
    && ok "Q3 rollback refuses when the branch has commits (held, nothing deleted)" || { bad "Q3"; echo "$OUT"; }
$SH abandon 9-4-prep --yes >/dev/null
$SH prepare 9-5-prep >/dev/null
lane_edit 9-5-prep 'd["phase"] = "launched"; d["attempts"] = 1'   # died between the two writes in launch
[ "$($SH board --json | jget '[x["stage"] for x in d if x["key"]=="9-5-prep"][0]')" = "queued" ] && ok "Q4 launched-without-proc shows queued" || bad "Q4"
OUT="$($SH launch 9-5-prep)"
echo "$OUT" | grep -q '^NOTE=上次 launch' && echo "$OUT" | grep -q '^EXIT_CODE=0' && ok "Q5 launch restarts a never-started worker" || { bad "Q5"; echo "$OUT"; }
$SH abandon 9-5-prep --yes >/dev/null

echo "== S: slots / overrides / deploy"
$SH start-run --slots 1 >/dev/null
[ "$($SH tick | jget 'd["slots"]["max"]')" = "1" ] && ok "S1 --slots overrides config for the run" || bad "S1"
$SH start-run --reset-slots >/dev/null
[ "$($SH tick | jget 'd["slots"]["max"]')" = "2" ] && ok "S2 --reset-slots restores config" || bad "S2"
cat >> .claude/harness/parallel.yaml <<'EOF'
deps_overrides:
  1-4-delta: []
  2-1-epsilon:
    - 1-4-delta
EOF
PLAN="$($SH plan --json)"
echo "$PLAN" | jget '[s for s in d["stories"] if s["key"]=="1-4-delta"][0]["deps"]' | grep -qx '\[\]' \
    && ok "S3 deps_overrides replaces missing depends_on" || bad "S3 $(echo "$PLAN" | jget '[s for s in d["stories"] if s["key"]=="1-4-delta"][0]')"
echo "$PLAN" | jget '[s for s in d["stories"] if s["key"]=="2-1-epsilon"][0]["reasons"]' | grep -q '等待依赖 1-4-delta' \
    && ok "S4 deps_overrides block list parsed" || bad "S4"
DEP="$TMP/deploy-target"; mkdir -p "$DEP"
OUT="$(DEPLOY_QUIET=1 bash "$PLUGIN_DIR/scripts/deploy_assets.sh" "$PLUGIN_DIR" "$DEP" 2>/dev/null)"
[ -f "$DEP/.claude/harness/parallel.yaml" ] && [ -f "$DEP/.claude/harness/prompts/worker.md" ] \
    && [ -f "$DEP/.claude/harness/scripts/superh.py" ] && [ -f "$DEP/.claude/harness/pipeline.md" ] \
    && [ ! -d "$DEP/.claude/commands" ] \
    && echo "$OUT" | grep -q 'installed=' && ok "S5 deploy installs assets + parallel.yaml template, no .claude/commands" || bad "S5 $OUT"
! grep -qx '.claude/harness/parallel.yaml' "$DEP/.claude/harness/.deploy-manifest.txt" \
    && ok "S5b parallel.yaml is not manifest-owned (never purged)" || bad "S5b"
echo "max_slots: 5" > "$DEP/.claude/harness/parallel.yaml"
DEPLOY_PURGE=1 DEPLOY_QUIET=1 bash "$PLUGIN_DIR/scripts/deploy_assets.sh" "$PLUGIN_DIR" "$DEP" >/dev/null 2>&1
grep -qx 'max_slots: 5' "$DEP/.claude/harness/parallel.yaml" && ok "S6 redeploy (with purge) keeps user parallel.yaml" || bad "S6"
# upgrade from super-harness 0.1.0 (config at .claude/super-harness/config.yaml)
DEP2="$TMP/deploy-legacy"; mkdir -p "$DEP2/.claude/super-harness"
git -C "$DEP2" init -q .
printf 'max_slots: 3\nno_deps_policy: epic-parallel\ndeps_overrides:\n  1-2-beta: [1-1-alpha]\n' > "$DEP2/.claude/super-harness/config.yaml"
OUT="$(cd "$DEP2" && python3 "$PLUGIN_DIR/scripts/superh.py" env 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && echo "$OUT" | grep -q '0.1.0 的并行配置' \
    && ok "S7 superh refuses to fall back to defaults when only the 0.1.0 config exists" || bad "S7 rc=$RC $OUT"
ERR="$(DEPLOY_QUIET=1 bash "$PLUGIN_DIR/scripts/deploy_assets.sh" "$PLUGIN_DIR" "$DEP2" 2>&1 >/dev/null)"
cmp -s "$DEP2/.claude/super-harness/config.yaml" "$DEP2/.claude/harness/parallel.yaml" \
    && echo "$ERR" | grep -q '^migrated: .claude/harness/parallel.yaml' \
    && ok "S8 deploy carries the 0.1.0 config over verbatim (reported even when quiet)" || bad "S8 $ERR"
OUT="$(cd "$DEP2" && python3 .claude/harness/scripts/superh.py env 2>&1)"
echo "$OUT" | grep -q '"no_deps_policy": "epic-parallel"' && echo "$OUT" | grep -q '"1-2-beta"' \
    && ok "S9 migrated deps_overrides / no_deps_policy are in effect" || bad "S9 $OUT"
(cd "$DEP2" && python3 .claude/harness/scripts/superh.py doctor) | grep -q '^WARN=.claude/super-harness/' \
    && ok "S10 doctor flags the leftover 0.1.0 directory" || bad "S10"

echo "== D: lane cleanliness never edits the shared info/exclude"
EXCL="$(git rev-parse --git-common-dir)/info/exclude"
EXCL_BEFORE="$(cat "$EXCL" 2>/dev/null || true)"
mkdir -p tools nm && echo 'local' > tools/local.cfg && echo 'dep' > nm/index.js
printf 'nm/\n' >> .gitignore && git commit -qam "ignore nm/ (dir-style rule)"
cat >> .claude/harness/parallel.yaml <<'EOF2'
copy_paths:
  - .claude/harness
  - tools
link_paths:
  - nm
EOF2
OUT="$($SH doctor)"
echo "$OUT" | grep -q '^PROBLEM=tools' && echo "$OUT" | grep -q '^PROBLEM=nm' && echo "$OUT" | grep -q '^STATUS=attention' \
    && ok "D1 doctor flags untracked copy path + dir-style rule for a symlink" || { bad "D1"; echo "$OUT"; }
OUT="$($SH prepare 9-1-doc)"
echo "$OUT" | grep -q '^STATUS=halt' && echo "$OUT" | grep -q '^GITIGNORE=/tools' && echo "$OUT" | grep -q '^GITIGNORE=/nm' \
    && ok "D2 prepare fails with explicit .gitignore lines" || { bad "D2"; echo "$OUT"; }
[ "$(cat "$EXCL" 2>/dev/null || true)" = "$EXCL_BEFORE" ] && ok "D3 shared info/exclude untouched" || bad "D3"
git status --porcelain -uall | grep -q '^?? tools/local.cfg' && ok "D4 user's untracked file still visible in main worktree" || bad "D4"
[ "$($SH board --json | jget '[x["stage"] for x in d if x["key"]=="9-1-doc"][0]')" = "held" ] && ok "D5 failed prepare shows as held" || bad "D5"
$SH abandon 9-1-doc --yes >/dev/null
printf '/tools\n/nm\n' >> .gitignore && git commit -qam "ignore tools + nm for lanes"
echo "$($SH doctor)" | grep -q '^STATUS=ok' && ok "D6 doctor ok after .gitignore fix" || bad "D6"
OUT="$($SH prepare 9-2-doc)"
echo "$OUT" | grep -q '^STATUS=ok' && [ -L "$TMP/wt/9-2-doc/nm" ] && [ -f "$TMP/wt/9-2-doc/tools/local.cfg" ] \
    && [ -z "$(git -C "$TMP/wt/9-2-doc" status --porcelain -uall)" ] && ok "D7 lane clean with copied dir + symlink" || { bad "D7"; echo "$OUT"; }
$SH abandon 9-2-doc --yes >/dev/null

echo
echo "superh_test: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

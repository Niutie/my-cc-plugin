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
echo '{"type":"system","subtype":"init","model":"fake-model","session_id":"sess-'"$SUPERH_KEY"'"}'
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
  bgexit)   # issue #16: Agent went to the background, worker ended its turn
    printf 'half-built\n' > src/half.txt
    printf 'base, edited by a half-run build\n' > src/shared.txt
    echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu1","name":"Agent","input":{}}]}}'
    echo '{"type":"user","parent_tool_use_id":null,"message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":[{"type":"text","text":"Async agent launched successfully. agentId: a1"}]}]}}'
    echo '{"type":"result","result":"waiting for the build agent to finish","is_error":false,"num_turns":8}'
    exit 0 ;;
  nestedbg) # a nested sub-agent backgrounding a command is not the worker's own turn
    echo '{"type":"user","parent_tool_use_id":"tu9","message":{"content":[{"type":"tool_result","tool_use_id":"tu10","content":"Command running in background with ID: b1"}]}}'
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
# issue #21: the worker's own dispatch, with the prompt the test put in .fake-agent-<KEY>
if [ -f "$SUPERH_MAIN_ROOT/.fake-agent-$KEY" ]; then
python3 - "$SUPERH_MAIN_ROOT/.fake-agent-$KEY" <<'PY2'
import json, sys
print(json.dumps({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "tuA", "name": "Agent",
      "input": {"description": "Follow-up review X", "prompt": open(sys.argv[1], encoding="utf-8").read()}}]}}))
PY2
fi
printf 'epic context compiled while building %s\n' "$KEY" > "$ART/epic-${KEY%%-*}-context.md"
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
[ -f "$SUPERH_MAIN_ROOT/.fake-spec-extra-$KEY" ] && cat "$SUPERH_MAIN_ROOT/.fake-spec-extra-$KEY" >> "$ART/spec-$KEY.md"
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
printf '.claude/\n.fake-mode-*\n.fake-agent-*\n.fake-spec-extra-*\n.bv-*\n' > .gitignore
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
mkdir -p .claude/harness/.backup/20260101-000000 .claude/harness/scripts/__pycache__
touch .claude/harness/.backup/20260101-000000/old.md .claude/harness/scripts/__pycache__/x.pyc
for k in 1-1-alpha 1-2-beta; do
    OUT="$($SH prepare $k)"; echo "$OUT" | grep -q '^STATUS=ok' && ok "L1 prepare $k" || { bad "L1 prepare $k"; echo "$OUT"; }
done
check "L2 copied untracked .claude/harness into worktree" test -f "$TMP/wt/1-1-alpha/.claude/harness/scripts/harness-commit.py"
[ ! -e "$TMP/wt/1-1-alpha/.claude/harness/.backup" ] && [ ! -e "$TMP/wt/1-1-alpha/.claude/harness/scripts/__pycache__" ] \
    && ok "L3b deploy backups and __pycache__ not copied into lane" || bad "L3b lane got .backup or __pycache__"
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
# implement + fix + the rebase hash-map record (issue #25) on top of the new base
[ "$(git rev-parse harness/1-2-beta/start)" = "$(git rev-parse 'story/1-2-beta~3')" ] \
    && ok "I11 start tag moved to rebase base" || bad "I11"
echo "$OUT" | grep -q "^REWRITTEN=${OLD_BUILT_BETA:0:12} → ${NEW_BUILT_BETA:0:12} feat(1-2-beta): implement" \
    && grep -q "| ${OLD_BUILT_BETA:0:12} | ${NEW_BUILT_BETA:0:12} | feat(1-2-beta): implement |" "$ART/spec-1-2-beta.md" \
    && [ "$(git log --format=%s 'story/1-2-beta~3..story/1-2-beta' | grep -c '^docs(1-2-beta): record commit hashes rewritten')" = "1" ] \
    && ok "I11b rebase: old → new hash map printed, appended to the spec, committed (issue #25)" || { bad "I11b"; echo "$OUT"; tail -8 "$ART/spec-1-2-beta.md"; }
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

# ---------------------------------------------------------------- hardening
SCRIPTS="$PROJ/.claude/harness/scripts"
LANES="$(git rev-parse --git-common-dir)/super-harness/lanes"
cfg_set() {  # cfg_set <key> <raw yaml value> — replace a top-level scalar in parallel.yaml
python3 - .claude/harness/parallel.yaml "$1" "$2" <<'PY'
import sys
p, k, v = sys.argv[1:4]
lines = [l for l in open(p, encoding="utf-8").read().splitlines() if not l.startswith(k + ":")]
lines.append(f"{k}: {v}")
open(p, "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY
}
lane_get() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$LANES/$1.json" "$2" 2>/dev/null; }
pstart() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import superh; print(superh.proc_start_time(int(sys.argv[2])))' "$SCRIPTS" "$1"; }
wait_for() {  # wait_for <seconds> <command...>
    local n=$(( $1 * 10 )); shift
    while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done
    return 1
}
op_pgid_is() {  # op_pgid_is <KEY> [<pgid>] — the lane's in-progress marker has a child group (that one)
    local g; g="$(lane_get "$1" 'd.get("op", {}).get("pgid") or ""')"
    if [ $# -ge 2 ]; then [ "$g" = "$2" ]; else [ -n "$g" ]; fi
}
group_gone() { ! kill -0 -- "-$1" 2>/dev/null; }
lines_ge() { [ -f "$1" ] && [ "$(wc -l < "$1")" -ge "$2" ]; }
stage_of() { $SH board --json | jget "[x['stage'] for x in d if x['key']=='$1'][0]"; }
ready_lane() {  # prepare + run the fake worker to `ready`
    $SH prepare "$1" >/dev/null && $SH launch "$1" >/dev/null && [ "$(stage_of "$1")" = "ready" ]
}
# park the merged gamma lane so tick only reflects the lanes below
lane_edit 1-3-gamma 'd["phase"] = "done"'

echo "== M1: config scalars"
python3 - "$SCRIPTS" > "$TMP/m1.out" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import superh
y = r"""
verify_command: 'pnpm test'   # full suite
worktree_root: ''  # default
q1: 'it''s # not a comment'   # real comment
q2: "say \"hi\" # x"  # real
q3: "a\\b\tc\x41"
q4: plain value # comment
q5: url#frag
q6: ['a, b', "c#d", e]  # list
q7: 'unterminated # comment
q8: "x" trailing
"""
d = superh.parse_simple_yaml(y)
want = {"verify_command": "pnpm test", "worktree_root": "", "q1": "it's # not a comment",
        "q2": 'say "hi" # x', "q3": "a\\b\tcA", "q4": "plain value", "q5": "url#frag",
        "q6": ["a, b", "c#d", "e"], "q7": "'unterminated", "q8": '"x" trailing'}
for k, v in want.items():
    print(("OK" if d.get(k) == v else "BAD"), k, repr(d.get(k)))
PY
while read -r st k rest; do
    [ "$st" = OK ] && ok "M1 quoted scalar $k" || bad "M1 $k got $rest"
done < "$TMP/m1.out"
printf "worktree_root: ''   # default\n" >> "$DEP2/.claude/harness/parallel.yaml"
[ "$(cd "$DEP2" && python3 .claude/harness/scripts/superh.py env | jget 'd["worktree_root"]')" = "$TMP/deploy-legacy.worktrees" ] \
    && ok "M1b worktree_root: '' with a comment means the default location" || bad "M1b"

echo "== M2: timeouts kill the whole process group"
cfg_set prepare_timeout_sec 1
cfg_set prepare_command "'echo \$\$ > $TMP/m2.pgid; sleep 30 & echo \$! > $TMP/m2.bg; echo m2-to-stderr >&2; sleep 30'"
T0=$(date +%s)
OUT="$($SH prepare 9-8-m2)"; RC=$?
T1=$(date +%s)
[ $RC -eq 1 ] && echo "$OUT" | grep -q '^REASON=prepare 失败：prepare_command 超时' && echo "$OUT" | grep -qx 'HOLD_KIND=prepare' \
    && [ $((T1 - T0)) -lt 15 ] && ok "M2a prepare_command timeout → held quickly" || { bad "M2a rc=$RC $((T1 - T0))s"; echo "$OUT"; }
echo "$OUT" | grep -q 'm2-to-stderr' && ok "M2b stderr kept on timeout" || bad "M2b"
BG="$(cat "$TMP/m2.bg" 2>/dev/null)"; PG="$(cat "$TMP/m2.pgid" 2>/dev/null)"
[ -n "$BG" ] && ! kill -0 "$BG" 2>/dev/null && group_gone "$PG" \
    && ok "M2c no surviving sleep (background child and group gone)" || bad "M2c bg=$BG pg=$PG"
$SH abandon 9-8-m2 --yes >/dev/null
cfg_set prepare_timeout_sec 600

echo "== M3: dispatcher lock, live prepare"
sleep 300 & OTHER=$!
OUT="$(CLAUDE_PID=$OTHER $SH start-run --take-over)"
echo "$OUT" | grep -q '^STATUS=ok' && echo "$OUT" | grep -q '^LOCK_RECLAIMED=taken-over' \
    && ok "M3a --take-over hands the lock to another live session" || { bad "M3a"; echo "$OUT"; }
OUT="$($SH prepare 9-9-lock)"; RC=$?
[ $RC -eq 4 ] && echo "$OUT" | grep -q '^STATUS=locked' && [ ! -f "$LANES/9-9-lock.json" ] \
    && ok "M3b mutating command refused while another live session holds the lock" || { bad "M3b rc=$RC"; echo "$OUT"; }
OUT="$($SH start-run)"; RC=$?
[ $RC -eq 4 ] && echo "$OUT" | grep -q "^LOCK_PID=$OTHER" && ok "M3c second start-run refused, names the holder" || { bad "M3c rc=$RC"; echo "$OUT"; }
$SH tick >/dev/null && ok "M3d read-only tick still works" || bad "M3d"
kill "$OTHER"; wait "$OTHER" 2>/dev/null
OUT="$($SH start-run)"
echo "$OUT" | grep -q '^STATUS=ok' && echo "$OUT" | grep -q '^LOCK_RECLAIMED=stale' \
    && ok "M3e stale lock (holder gone) is reclaimed" || { bad "M3e"; echo "$OUT"; }
rm -f "$TMP/go"
cfg_set prepare_command "'while [ ! -f $TMP/go ]; do sleep 0.2; done'"
$SH prepare 9-10-live > "$TMP/live.out" 2>&1 &
PP=$!
wait_for 30 op_pgid_is 9-10-live || bad "M3 prepare never started"
TICK="$($SH tick)"
[ "$(echo "$TICK" | jget 'd["preparing"]')" = "['9-10-live']" ] && ! echo "$TICK" | jget 'd["launch"]' | grep -q 9-10-live \
    && ok "M3f live prepare is not routed back to prepare" || { bad "M3f"; echo "$TICK"; }
[ "$(stage_of 9-10-live)" = "preparing" ] && ok "M3g board shows it preparing" || bad "M3g $(stage_of 9-10-live)"
OUT="$($SH prepare 9-10-live)"; RC=$?
[ $RC -eq 4 ] && echo "$OUT" | grep -q '^STATUS=busy' && [ -d "$TMP/wt/9-10-live" ] \
    && ok "M3h second prepare refuses, worktree untouched" || { bad "M3h rc=$RC"; echo "$OUT"; }
touch "$TMP/go"; wait "$PP"
grep -q '^STATUS=ok' "$TMP/live.out" && [ "$(lane_get 9-10-live 'd.get("op")')" = "None" ] \
    && ok "M3i the original prepare finishes, marker cleared" || { bad "M3i"; cat "$TMP/live.out"; }
$SH abandon 9-10-live --yes >/dev/null

echo "== H1: killed prepare / integrate don't loop"
rm -f "$TMP/go" "$TMP/pk.pgids"
cfg_set prepare_command "'echo \$\$ >> $TMP/pk.pgids; while [ ! -f $TMP/go ]; do sleep 0.2; done'"
OLDPG=""
for i in 1 2 3; do
    $SH prepare 9-11-pk > "$TMP/pk$i.out" 2>&1 &
    BGP=$!
    wait_for 30 lines_ge "$TMP/pk.pgids" "$i" || bad "H1 prepare $i never started"
    [ $i -gt 1 ] && { grep -q '^ROLLED_BACK=' "$TMP/pk$i.out" && group_gone "$OLDPG" \
        && ok "H1a prepare #$i rolled back the killed one and ended its leftover group" || { bad "H1a #$i"; cat "$TMP/pk$i.out"; }; }
    OLDPG="$(tail -1 "$TMP/pk.pgids")"
    wait_for 10 op_pgid_is 9-11-pk "$OLDPG"
    kill -9 "$(lane_get 9-11-pk 'd["op"]["pid"]')"; wait "$BGP" 2>/dev/null
done
echo "$($SH tick)" | jget 'd["launch"]' | grep -q 9-11-pk && ok "H1b killed prepare routed back while under the limit" || bad "H1b"
OUT="$($SH prepare 9-11-pk)"; RC=$?
[ $RC -eq 1 ] && echo "$OUT" | grep -qx 'HOLD_KIND=prepare' && echo "$OUT" | grep -q '连续 3 次' && [ -d "$TMP/wt/9-11-pk" ] \
    && group_gone "$OLDPG" && ok "H1c third kill → held (kind=prepare), leftover group ended" || { bad "H1c rc=$RC"; echo "$OUT"; }
! echo "$($SH tick)" | jget 'd["launch"]' | grep -q 9-11-pk && ok "H1d held prepare leaves the launch list" || bad "H1d"
$SH abandon 9-11-pk --yes >/dev/null
cfg_set prepare_command "''"

ready_lane 9-12-ik && ok "H1e lane 9-12-ik ready" || bad "H1e"
echo h1 > src/h1.txt && git add src/h1.txt && git commit -qm "sprint moves: 9-12-ik must rebase"
rm -f "$TMP/ik.pgids"
cfg_set verify_command "'echo \$\$ >> $TMP/ik.pgids; sleep 30'"
OLDPG=""
for i in 1 2 3; do
    $SH integrate 9-12-ik > "$TMP/ik$i.out" 2>&1 &
    BGP=$!
    wait_for 60 lines_ge "$TMP/ik.pgids" "$i" || bad "H1 integrate $i never reached verify"
    [ $i -gt 1 ] && { grep -q '^NOTE=上次 integrate 在运行中被打断' "$TMP/ik$i.out" && group_gone "$OLDPG" \
        && ok "H1f integrate #$i resumes after a kill, leftover verify group ended" || { bad "H1f #$i"; cat "$TMP/ik$i.out"; }; }
    OLDPG="$(tail -1 "$TMP/ik.pgids")"
    [ "$(echo "$($SH tick)" | jget 'd["next_action"]')" != "integrate" ] && ok "H1g no second integrate handed out while one is live (#$i)" || bad "H1g #$i"
    if [ $i -eq 2 ]; then
        kill -TERM "$(lane_get 9-12-ik 'd["op"]["pid"]')"; wait "$BGP"; RC=$?
        [ $RC -eq 143 ] && group_gone "$OLDPG" && ok "H1h SIGTERM ends the verify group before exiting" || { bad "H1h rc=$RC"; cat "$TMP/ik$i.out"; }
    else
        kill -9 "$(lane_get 9-12-ik 'd["op"]["pid"]')"; wait "$BGP" 2>/dev/null
    fi
    if [ $i -lt 3 ]; then
        echo "$($SH tick)" | jget 'd["integrate"]' | grep -q 9-12-ik && ok "H1i killed integrate routed back (#$i)" || bad "H1i #$i"
    fi
done
OUT="$($SH integrate 9-12-ik)"; RC=$?
[ $RC -eq 1 ] && echo "$OUT" | grep -qx 'HOLD_KIND=interrupted' && group_gone "$OLDPG" \
    && ok "H1j third kill → held (kind=interrupted), leftover group ended" || { bad "H1j rc=$RC"; echo "$OUT"; }
TICK="$($SH tick)"
[ "$(echo "$TICK" | jget 'd["next_action"]')" != "integrate" ] && echo "$TICK" | jget 'd["attention"]' | grep -q 'superh.py integrate 9-12-ik' \
    && ok "H1k held lane leaves the integrate loop, takeover says re-run integrate" || { bad "H1k"; echo "$TICK"; }
cfg_set verify_timeout_sec 1
cfg_set verify_command "'echo verify-out; echo verify-err >&2; sleep 30'"
T0=$(date +%s)
OUT="$($SH integrate 9-12-ik)"; RC=$?
T1=$(date +%s)
[ $RC -eq 1 ] && echo "$OUT" | grep -qx 'HOLD_KIND=verify' && echo "$OUT" | grep -q '超时' && [ $((T1 - T0)) -lt 15 ] \
    && ok "M2d manual re-run accepted; verify timeout → held verify, quickly" || { bad "M2d rc=$RC $((T1 - T0))s"; echo "$OUT"; }
echo "$OUT" | sed -n '/VERIFY_OUTPUT<</,/>>/p' | grep -q verify-err && ok "M2e verify timeout keeps stderr" || { bad "M2e"; echo "$OUT"; }
echo "$OUT" | grep -q '^SELF_HEAL=verify-timeout-retry' && echo "$OUT" | grep -q '跑了 2 次' \
    && ok "M2f a verify timeout is re-run once before the lane is held" || { bad "M2f"; echo "$OUT"; }
cfg_set verify_command "''"
cfg_set verify_timeout_sec 1800
OUT="$($SH integrate 9-12-ik)"; RC=$?
[ $RC -eq 0 ] && [ "$(lane_get 9-12-ik 'd["phase"]')" = "merged" ] && ok "H1l after the fix integrate merges" || { bad "H1l rc=$RC"; echo "$OUT"; }
lane_edit 9-12-ik 'd["phase"] = "done"'

echo "== H2: integrate failures hold the lane"
ready_lane 9-13-dirty && ok "H2a lane 9-13-dirty ready" || bad "H2a"
echo 'coverage' > "$TMP/wt/9-13-dirty/coverage.out"
OUT="$($SH integrate 9-13-dirty)"; RC=$?
[ $RC -eq 1 ] && echo "$OUT" | grep -qx 'HOLD_KIND=lane-dirty' && echo "$OUT" | grep -q 'DIRTY=?? coverage.out' \
    && ok "H2b untracked coverage file → held lane-dirty" || { bad "H2b rc=$RC"; echo "$OUT"; }
TICK="$($SH tick)"
! echo "$TICK" | jget 'd["integrate"]' | grep -q 9-13-dirty && [ "$(echo "$TICK" | jget 'd["next_action"]')" != "integrate" ] \
    && echo "$TICK" | jget '[a["takeover"] for a in d["attention"] if a["key"]=="9-13-dirty"][0]' | grep -q 'git status' \
    && ok "H2c tick routes it to attention, not back to integrate" || { bad "H2c"; echo "$TICK"; }
rm -f "$TMP/wt/9-13-dirty/coverage.out"
OUT="$($SH integrate 9-13-dirty)"; RC=$?
[ $RC -eq 0 ] && ok "H2d integrate accepts it again once cleaned" || { bad "H2d rc=$RC"; echo "$OUT"; }
lane_edit 9-13-dirty 'd["phase"] = "done"'
ready_lane 9-14-gone && ok "H2e lane 9-14-gone ready" || bad "H2e"
git worktree remove --force "$TMP/wt/9-14-gone" && git branch -qD story/9-14-gone
OUT="$($SH integrate 9-14-gone)"; RC=$?
[ $RC -eq 1 ] && echo "$OUT" | grep -qx 'HOLD_KIND=branch-missing' && ! echo "$($SH tick)" | jget 'd["integrate"]' | grep -q 9-14-gone \
    && ok "H2f missing lane branch → held, not an endless loop" || { bad "H2f rc=$RC"; echo "$OUT"; }
$SH abandon 9-14-gone --yes >/dev/null
git branch story/9-15-left
OUT="$($SH prepare 9-15-left)"; RC=$?
[ $RC -eq 1 ] && echo "$OUT" | grep -qx 'HOLD_KIND=foreign' && ! echo "$($SH tick)" | jget 'd["launch"]' | grep -q 9-15-left \
    && ok "H2g leftover branch → held foreign (no prepare loop)" || { bad "H2g rc=$RC"; echo "$OUT"; }
$SH abandon 9-15-left --yes >/dev/null
git rev-parse --verify --quiet story/9-15-left >/dev/null && ok "H2h abandon leaves a foreign branch alone" || bad "H2h"
git branch -qD story/9-15-left

echo "== L1: quota hold stops queued lanes too"
echo blocked > .fake-mode-9-16-q
$SH prepare 9-16-q >/dev/null && $SH launch 9-16-q >/dev/null
result_edit 9-16-q 'd["status"] = "quota"'
$SH prepare 9-17-q2 >/dev/null
TICK="$($SH tick)"
[ "$(echo "$TICK" | jget 'd["quota_hold"]')" = "True" ] && [ "$(echo "$TICK" | jget 'd["queued"]')" = "[]" ] \
    && [ "$(echo "$TICK" | jget 'd["next_action"]')" != "launch" ] \
    && ok "L1 quota_hold: queued lane is not launched" || { bad "L1"; echo "$TICK"; }
$SH abandon 9-16-q --yes >/dev/null; $SH abandon 9-17-q2 --yes >/dev/null

echo "== L2: liveness checks launcher and claude child, with identity"
$SH prepare 9-18-orph >/dev/null
lane_edit 9-18-orph 'd["phase"] = "launched"; d["attempts"] = 1'
DEAD="$(sh -c 'echo $$')"
sleep 300 & CH=$!
write_proc() {  # write_proc <child_pid> <child_start>
python3 - "$LANES/9-18-orph.proc.json" "$DEAD" "$1" "$2" <<'PY'
import json, sys
p, dead, ch, cs = sys.argv[1:5]
json.dump({"key": "9-18-orph", "attempt": 1, "pid": int(dead), "pid_start": "gone", "child_pid": int(ch),
           "child_start": cs, "exit_code": None, "session_id": None}, open(p, "w"))
PY
}
write_proc "$CH" "$(pstart "$CH")"
TICK="$($SH tick)"
[ "$(stage_of 9-18-orph)" = "working" ] && echo "$TICK" | jget 'd["orphaned"]' | grep -q 9-18-orph \
    && ok "L2a launcher dead, claude child alive → working (orphaned), not crashed" || { bad "L2a $(stage_of 9-18-orph)"; echo "$TICK"; }
$SH watch 9-18-orph --interval 0.2 > "$TMP/watch.out" &
WP=$!
wait_for 20 test -f "$LANES/9-18-orph.watch.json"
[ "$(echo "$($SH tick)" | jget 'd["orphaned"]')" = "[]" ] && ok "L2b a live watcher takes it off the orphaned list" || bad "L2b"
kill "$CH"; wait "$CH" 2>/dev/null
wait_for 20 grep -q '^STAGE=' "$TMP/watch.out"; wait "$WP"
grep -qx 'STAGE=crashed' "$TMP/watch.out" && ok "L2c watch returns when the child exits; no report → crashed" || { bad "L2c"; cat "$TMP/watch.out"; }
sleep 300 & CH=$!
write_proc "$CH" "linux:1"
[ "$(stage_of 9-18-orph)" = "crashed" ] && ok "L2d live pid with a different start time is not our worker" || bad "L2d $(stage_of 9-18-orph)"
kill "$CH"; wait "$CH" 2>/dev/null
$SH report 9-18-orph --status ready --summary "reported, then the launcher died" >/dev/null
[ "$(stage_of 9-18-orph)" = "ready" ] && ok "L2e worker reported before dying → its report stands" || bad "L2e $(stage_of 9-18-orph)"
$SH abandon 9-18-orph --yes >/dev/null

echo "== B16: worker exits with a background agent still running (issue #16)"
echo bgexit > .fake-mode-9-19-bg
$SH prepare 9-19-bg >/dev/null && $SH launch 9-19-bg > "$TMP/bg.out"
grep -q '^STAGE=failed' "$TMP/bg.out" && grep -q '^DETAIL=worker 启动了后台子 agent，' "$TMP/bg.out" \
    && ok "B16a launch names the background exit" || { bad "B16a"; cat "$TMP/bg.out"; }
OUT="$($SH retry 9-19-bg)"; RC=$?
[ $RC -eq 1 ] && echo "$OUT" | grep -q 'retry 9-19-bg --reset' && echo "$OUT" | grep -q '^DIRTY=.*src/half.txt' \
    && [ "$(stage_of 9-19-bg)" = "failed" ] \
    && ok "B16b retry refuses a half-built lane and points at --reset" || { bad "B16b rc=$RC"; echo "$OUT"; }
OUT="$($SH retry 9-19-bg --reset)"; RC=$?
WT="$TMP/wt/9-19-bg"
[ $RC -eq 0 ] && echo "$OUT" | grep -q '^RESET=' && [ -z "$(git -C "$WT" status --porcelain)" ] \
    && [ "$(git -C "$WT" rev-parse HEAD)" = "$(git rev-parse 'harness/9-19-bg/start^{commit}')" ] \
    && [ "$(stage_of 9-19-bg)" = "queued" ] \
    && ok "B16c retry --reset restores the start point and requeues" || { bad "B16c rc=$RC"; echo "$OUT"; }
$SH abandon 9-19-bg --yes >/dev/null
echo nestedbg > .fake-mode-9-20-nb
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'DK'
#!/usr/bin/env bash
case "$1" in
  ps) printf 'aaaaaaaaaaaaaaaa\nbbbbbbbbbbbbbbbb\n' ;;
  inspect) cat "$FAKE_DOCKER_JSON" ;;
esac
DK
chmod +x "$TMP/bin/docker"
cat > "$TMP/docker.json" <<DJ
[{"Id": "aaaaaaaaaaaaaaaa", "Name": "/xbuild", "Mounts": [{"Source": "$TMP/wt/9-20-nb"}]},
 {"Id": "bbbbbbbbbbbbbbbb", "Name": "/other", "Mounts": [{"Source": "$TMP/wt/9-20-nb-other"}]}]
DJ
$SH prepare 9-20-nb >/dev/null && PATH="$TMP/bin:$PATH" FAKE_DOCKER_JSON="$TMP/docker.json" $SH launch 9-20-nb > "$TMP/nb.out"
grep -qx 'ORPHAN_CONTAINER=aaaaaaaaaaaa xbuild' "$TMP/nb.out" && [ "$(grep -c '^ORPHAN_CONTAINER=' "$TMP/nb.out")" = 1 ] \
    && grep -q '^WARN=还有 1 个容器' "$TMP/nb.out" \
    && ok "B16f launch reports containers still mounting the lane worktree" || { bad "B16f"; cat "$TMP/nb.out"; }
OUT="$(PATH="$TMP/bin:$PATH" FAKE_DOCKER_JSON="$TMP/docker.json" $SH retry 9-20-nb)"
echo "$OUT" | grep -qx 'ORPHAN_CONTAINER=aaaaaaaaaaaa xbuild' && echo "$OUT" | grep -q '^STATUS=ok' \
    && ok "B16g retry reports them too, without blocking" || { bad "B16g"; echo "$OUT"; }
lane_edit 9-20-nb 'd["phase"] = "launched"'   # back to failed for B16e
grep -q '^DETAIL=worker 退出' "$TMP/nb.out" && ! grep -q '启动了后台' "$TMP/nb.out" \
    && ok "B16d background calls inside nested sub-agents are not blamed" || { bad "B16d"; cat "$TMP/nb.out"; }
OUT="$($SH retry 9-20-nb --reset)"
echo "$OUT" | grep -q '^NOTE=worktree 是干净的' && echo "$OUT" | grep -q '^STATUS=ok' \
    && ok "B16e --reset on a clean lane is a no-op" || { bad "B16e"; echo "$OUT"; }
$SH abandon 9-20-nb --yes >/dev/null

echo "== D17: decision inbox, reopen / resume / override, self-heal (issue #17)"
blocked_spec() {  # blocked_spec <worktree> <key>
cat > "$1/$ART/spec-$2.md" <<SPEC
---
title: 'fixture'
status: 'blocked' # draft | ready-for-dev | in-progress | in-review | done | blocked
---

<intent-contract>

## Intent

**Problem:** list order unspecified

</intent-contract>

## Code Map

- src/

## Auto Run Result

Status: blocked
Blocking condition: intent gap
- Q1: 列表按什么排序？候选：按时间 / 按名称
SPEC
}
fake_exit() {  # fake_exit <KEY> <status> — the worker ran (attempt 1) and reported
python3 - "$LANES/$1.proc.json" "$1" <<'PY'
import json, sys
json.dump({"key": sys.argv[2], "attempt": 1, "pid": 1, "pid_start": "gone", "exit_code": 0}, open(sys.argv[1], "w"))
PY
lane_edit "$1" 'd["phase"] = "launched"; d["attempts"] = 1'
SUPERH_ATTEMPT=1 $SH report "$1" --status "$2" --summary "fixture" >/dev/null
}
hs_code() { (cd "$1" && python3 .claude/harness/scripts/harness-state.py "$2" --json | jget 'd["next_action_code"]'); }

K=9-30-gap; WT="$TMP/wt/$K"
$SH prepare $K >/dev/null
lane_edit $K 'd["phase"] = "launched"; d["attempts"] = 1'
git -C "$WT" tag "harness/$K/start"
blocked_spec "$WT" $K
cat > "$TMP/dec.json" <<'J'
[{"question": "列表按什么排序？", "options": ["按时间", "按名称"], "chosen": "按时间", "why": "和上一条 story 的列表一致"}]
J
OUT="$($SH reopen $K --why "intent gap" --decisions-file "$TMP/dec.json")"; RC=$?
[ $RC -eq 1 ] && echo "$OUT" | grep -q '要在这一路的 worktree' && ok "D1 reopen refuses to run outside the lane worktree" || { bad "D1 rc=$RC"; echo "$OUT"; }
printf 'diff --git a/src/x b/src/x\n' > "$WT/$ART/spec-$K-intent-gap-attempt.patch"   # step-04 intent-gap leftover
OUT="$(cd "$WT" && $SH reopen $K --why "intent gap" --decisions-file "$TMP/dec.json")"; RC=$?
SPEC="$WT/$ART/spec-$K.md"
echo "$OUT" | grep -q "^MOVED_PATCH=.*patches/$K/spec-$K-intent-gap-attempt.patch" \
    && ok "D2b the saved attempt patch is moved out of the worktree, not deleted" || { bad "D2b"; echo "$OUT"; }
[ $RC -eq 0 ] && echo "$OUT" | grep -qx 'DECISION_IDS=D1' && echo "$OUT" | grep -qx 'SPEC_STATUS=draft' \
    && grep -q "^status: 'draft'" "$SPEC" && [ -z "$(git -C "$WT" status --porcelain)" ] \
    && ok "D2 reopen: spec back to draft, committed, worktree clean" || { bad "D2 rc=$RC"; echo "$OUT"; }
python3 - "$SPEC" <<'PY' && ok "D3 the answer sits inside <intent-contract>, tagged with its decision id" || bad "D3"
import sys
t = open(sys.argv[1], encoding="utf-8").read()
i, j = t.find("### Clarifications"), t.find("</intent-contract>")
assert 0 <= i < j and "A: 按时间（D1，按推荐项代答，待确认）" in t[i:j], t
PY
[ "$(git -C "$WT" log -2 --format=%s | tail -1)" = "docs($K): record bmad-build-auto halt" ] \
    && git -C "$WT" log -1 --format=%s | grep -q 'D1' \
    && ok "D4 the halted spec is its own commit (override resets to it), then the answer" || { bad "D4"; git -C "$WT" log -3 --format=%s; }
[ "$(hs_code "$WT" $K)" = "build" ] && ok "D5 harness-state routes the reopened spec back to B1" || bad "D5 $(hs_code "$WT" $K)"
[ "$($SH tick | jget 'd["decisions_pending"]')" = "['D1']" ] && $SH board | grep -q '待你确认（已按推荐项继续，1 条）' \
    && $SH board | grep -q 'D1 \[9-30-gap B1\]' && ok "D6 tick and board list the pending decision" || { bad "D6"; $SH board; }
cfg_set decision_mode ask
OUT="$(cd "$WT" && $SH reopen $K --why x --decisions-file "$TMP/dec.json")"; RC=$?
[ $RC -eq 1 ] && echo "$OUT" | grep -q 'decision_mode 是 ask' && ok "D7 decision_mode=ask: no auto-answer" || { bad "D7 rc=$RC"; echo "$OUT"; }
cfg_set decision_mode proceed
blocked_spec "$WT" $K
OUT="$(cd "$WT" && $SH reopen $K --why "intent gap again" --decisions-file "$TMP/dec.json")"
echo "$OUT" | grep -qx 'DECISION_IDS=D2' && echo "$OUT" | grep -qx 'REOPEN_LEFT=0' && ok "D8 second reopen allowed" || { bad "D8"; echo "$OUT"; }
blocked_spec "$WT" $K
OUT="$(cd "$WT" && $SH reopen $K --why x --decisions-file "$TMP/dec.json")"; RC=$?
[ $RC -eq 1 ] && echo "$OUT" | grep -q '到上限了' && ok "D9 third reopen refused (limit 2)" || { bad "D9 rc=$RC"; echo "$OUT"; }
git -C "$WT" checkout -q -- "$ART/spec-$K.md"
OUT="$($SH confirm D1)"
echo "$OUT" | grep -qx 'CONFIRMED=D1' && [ "$($SH tick | jget 'd["decisions_pending"]')" = "['D2']" ] \
    && ok "D10 confirm moves D1 out of the inbox" || { bad "D10"; echo "$OUT"; }
fake_exit $K blocked
BASE2="$($SH decisions --json | jget '[r for r in d if r["id"]=="D2"][0]["base"]')"
OUT="$($SH override D2 --answer "按名称")"; RC=$?
[ $RC -eq 1 ] && echo "$OUT" | grep -qx 'STATUS=confirm' && [ "$(git -C "$WT" rev-parse HEAD)" != "$BASE2" ] \
    && ok "D11 override without --yes only explains what it would reset" || { bad "D11 rc=$RC"; echo "$OUT"; }
OUT="$($SH override D2 --answer "按名称" --yes)"; RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -qx "RESET=$BASE2" && grep -q 'A: 按名称（D2，用户改判）' "$SPEC" \
    && ! grep -q 'D2，按推荐项代答' "$SPEC" && [ "$(git -C "$WT" rev-parse HEAD~1)" = "$BASE2" ] \
    && [ "$(stage_of $K)" = "queued" ] \
    && ok "D12 override --yes resets to the halt commit, writes the new answer, requeues" || { bad "D12 rc=$RC"; echo "$OUT"; }
[ "$($SH decisions --all --json | jget '[r["status"] for r in d if r["id"]=="D2"][0]')" = "overridden" ] \
    && ok "D13 D2 recorded as overridden" || bad "D13"
OUT="$($SH decide - --question "要不要 push 到远端？" --chosen "先不 push" --why "answer-policy：对外发布要人确认")"
DID="$(echo "$OUT" | sed -n 's/^DECISION_ID=//p')"
OUT="$($SH override "$DID" --answer "push")"
echo "$OUT" | grep -qx 'NEXT=dispatcher' && ok "D14 dispatcher decisions are recorded and overridable without touching a lane" || { bad "D14"; echo "$OUT"; }
$SH abandon $K --yes >/dev/null

K=9-31-b3; WT="$TMP/wt/$K"; SPEC="$WT/$ART/spec-$K.md"
$SH prepare $K >/dev/null
git -C "$WT" tag "harness/$K/start"
echo b3 > "$WT/src/$K.txt"; blocked_spec "$WT" $K
printf '{"key":"%s","reason":"quota_exhausted"}\n' "$K" > "$WT/$ART/$K.codex-skipped.json"   # B2 skipped
sed -i "s/^status: 'blocked'/status: 'done'/" "$SPEC"
git -C "$WT" add -A && git -C "$WT" commit -qm "feat($K): implement" && git -C "$WT" tag "harness/$K/built" && git -C "$WT" tag "harness/$K/followup-start"
sed -i "s/^status: 'done'/status: 'blocked'/" "$SPEC"
fake_exit $K blocked
[ "$(hs_code "$WT" $K)" = "blocked" ] && ok "D15 harness-state: spec blocked during B3 → blocked, not another B3 dispatch" || bad "D15 $(hs_code "$WT" $K)"
OUT="$($SH resume $K --note "按方案 A：只在列表页加排序")"; RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -qx 'SPEC_STATUS=in-review' && echo "$OUT" | grep -qx "MOVED_TAG=harness/$K/followup-start" \
    && [ "$(git rev-parse "harness/$K/followup-start^{commit}")" = "$(git -C "$WT" rev-parse HEAD)" ] \
    && grep -q '按方案 A' "$SPEC" && [ "$(stage_of $K)" = "queued" ] && [ -z "$(git -C "$WT" status --porcelain)" ] \
    && ok "D16 resume: answer in spec, status in-review, followup-start on the new commit, requeued" || { bad "D16 rc=$RC"; echo "$OUT"; }
[ "$(hs_code "$WT" $K)" = "followup" ] && ok "D17 harness-state resumes B3 (not followup-verify)" || bad "D17 $(hs_code "$WT" $K)"
OUT="$($SH resume $K --note again)"; RC=$?
[ $RC -eq 1 ] && ok "D18 resume refuses a lane that is not stopped" || { bad "D18 rc=$RC"; echo "$OUT"; }
$SH abandon $K --yes >/dev/null

K=9-32-ns; WT="$TMP/wt/$K"
$SH prepare $K >/dev/null
git -C "$WT" tag "harness/$K/start"
printf -- '---\nstatus: blocked\n---\n\n# BMad Build Auto Result\n\nStatus: blocked\nBlocking condition: unclear intent\n' \
    > "$WT/$ART/bmad-build-auto-result-x.md"
fake_exit $K blocked
OUT="$($SH resume $K --note "数据库用 PostgreSQL")"; RC=$?
PROMPT="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import superh; c = superh.Ctx(); print(superh.render_worker_prompt(c, c.lane(sys.argv[2]), 2))' "$SCRIPTS" $K)"
[ $RC -eq 0 ] && [ ! -e "$WT/$ART/bmad-build-auto-result-x.md" ] && echo "$OUT" | grep -q '数据库用 PostgreSQL' \
    && echo "$PROMPT" | grep -q -- '- 数据库用 PostgreSQL' && ! echo "$PROMPT" | grep -q '{{' \
    && ok "D19 no spec yet: result file removed, the answer goes into the next worker prompt" || { bad "D19 rc=$RC"; echo "$OUT"; }
$SH abandon $K --yes >/dev/null

K=9-33-split; WT="$TMP/wt/$K"
$SH prepare $K >/dev/null
git -C "$WT" tag "harness/$K/start"
printf -- '---\nstatus: done\n---\n<intent-contract>\n</intent-contract>\n\n## Auto Run Result\n\nStatus: done\n' > "$WT/$ART/spec-$K.md"
echo v1 > "$WT/src/$K.txt"; git -C "$WT" add -A; git -C "$WT" commit -qm "feat($K): implement"
printf -- '---\nstory: %s\nfindings: 1\n---\n- [high] something\n' "$K" > "$WT/$ART/$K.codex-review.md"
echo v2 > "$WT/src/$K.txt"
printf '\n### Codex Review Handling (Stage 3)\n\n- [F-1 high] x — fixed: src\n' >> "$WT/$ART/spec-$K.md"
OUT="$(cd "$WT" && python3 .claude/harness/scripts/harness-commit.py 3 $K)"; RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -qx "AUTO_SPLIT=left-for-stage-4 src/$K.txt" \
    && [ "$(git -C "$WT" diff --cached --name-only)" = "$ART/$K.codex-review.md" ] \
    && ok "D20 stage 3 with B2.3 edits in the tree: commits the report alone" || { bad "D20 rc=$RC"; echo "$OUT"; }
git -C "$WT" commit -qm "story($K): codex adversarial review report"
OUT="$(cd "$WT" && python3 .claude/harness/scripts/harness-commit.py 4 $K)"; RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -qx "STAGED=src/$K.txt" && ok "D21 stage 4 then takes the fixes" || { bad "D21 rc=$RC"; echo "$OUT"; }
git -C "$WT" commit -qm "story($K): apply codex review fixes"
git -C "$WT" rm -q --cached "$ART/$K.codex-review.md" >/dev/null; git -C "$WT" commit -qm "drop report for D22"
echo v3 > "$WT/src/$K.txt"; printf 'x\n' > "$WT/$ART/9-99-other.md"
OUT="$(cd "$WT" && python3 .claude/harness/scripts/harness-commit.py 3 $K)"; RC=$?
[ $RC -eq 1 ] && ! echo "$OUT" | grep -q '^AUTO_SPLIT=' && ok "D22 no split when an extra path is one stage 4 would refuse" || { bad "D22 rc=$RC"; echo "$OUT"; }
rm -f "${WT:?}/${ART:?}/9-99-other.md" "${WT:?}/${ART:?}/$K.codex-review.md"; git -C "$WT" checkout -q -- src
sed -i 's/^## Auto Run Result/### Auto Run Result/' "$WT/$ART/spec-$K.md"; git -C "$WT" commit -qam "h3 result heading"
OUT="$(cd "$WT" && python3 .claude/harness/scripts/harness-commit.py build-verify $K)"; RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -q '^AUTO_FIXED=auto-run-result-heading level=h3' && ! echo "$OUT" | grep -q AUTO_RUN_RESULT_MISSING \
    && ok "D23 build-verify accepts an Auto Run Result written at the wrong heading level" || { bad "D23 rc=$RC"; echo "$OUT"; }
$SH abandon $K --yes >/dev/null

cfg_set env_check_command "'test -f $TMP/env.up'"
cfg_set env_up_command "'touch $TMP/env.up'"
K=9-34-env
$SH prepare $K >/dev/null
OUT="$($SH launch $K)"
echo "$OUT" | grep -q '^SELF_HEAL=env-up' && [ -f "$TMP/env.up" ] && echo "$OUT" | grep -q '^STAGE=ready' \
    && ok "D24 environment not up → env_up_command, then the worker starts" || { bad "D24"; echo "$OUT"; }
echo "$OUT" | grep -q '^WORKER_MODEL=fake-model' && ok "D25 launch reports the model the worker really used" || { bad "D25"; echo "$OUT"; }
$SH abandon $K --yes >/dev/null
rm -f "${TMP:?}/env.up"; cfg_set env_up_command "'exit 3'"
K=9-35-noenv
$SH prepare $K >/dev/null
OUT="$($SH launch $K)"; RC=$?
[ $RC -eq 1 ] && echo "$OUT" | grep -qx 'HOLD_KIND=env' && [ "$(stage_of $K)" = "held" ] && [ ! -f "$LANES/$K.proc.json" ] \
    && $SH tick | jget 'd["attention"]' | grep -q "retry $K" \
    && ok "D26 environment can't be brought up → lane held before any worker starts" || { bad "D26 rc=$RC"; echo "$OUT"; }
cfg_set env_up_command "'touch $TMP/env.up'"
OUT="$($SH retry $K)"
echo "$OUT" | grep -q '^STATUS=ok' && [ "$(stage_of $K)" = "queued" ] && ok "D27 retry after fixing the environment" || { bad "D27"; echo "$OUT"; }
$SH abandon $K --yes >/dev/null
cfg_set env_check_command "''"; cfg_set env_up_command "''"

cp "$ART/sprint-status.yaml" "$TMP/sprint-status.bak"
cat > "$ART/sprint-status.yaml" <<'EOF'
development_status:
  epic-8: in-progress
  8-1-a: backlog
  8-2-b: backlog
  8-3-c: backlog
  epic-8-retrospective: optional
story_dependencies:
  8-3-c: [8-1-a]
EOF
$SH prepare 8-1-a >/dev/null; fake_exit 8-1-a blocked
reasons() { $SH plan --json | jget "[s for s in d['stories'] if s['key']=='$1'][0]['reasons']"; }
reasons 8-2-b | grep -q '按串行等待 8-1-a' && ok "D28 blocked_policy=wait: a blocked lane holds the serial order" || bad "D28 $(reasons 8-2-b)"
cfg_set blocked_policy continue
TICK="$($SH tick)"
[ "$(reasons 8-2-b)" = "[]" ] && reasons 8-3-c | grep -q '等待依赖 8-1-a' && echo "$TICK" | jget 'd["stuck_released"]' | grep -q 8-1-a \
    && echo "$TICK" | jget 'd["launch"]' | grep -q 8-2-b \
    && ok "D29 blocked_policy=continue: serial order released, explicit deps still wait" || { bad "D29"; $SH plan; }
cfg_set blocked_policy wait
$SH abandon 8-1-a --yes >/dev/null
cp "$TMP/sprint-status.bak" "$ART/sprint-status.yaml"

echo "== D17b: review follow-ups"
K=9-36-batch; WT="$TMP/wt/$K"; SPEC="$WT/$ART/spec-$K.md"
$SH prepare $K >/dev/null
lane_edit $K 'd["phase"] = "launched"; d["attempts"] = 1'
git -C "$WT" tag "harness/$K/start"
blocked_spec "$WT" $K
cat > "$TMP/dec2.json" <<'J'
[{"question": "排序？", "chosen": "按时间"}, {"question": "分页？", "chosen": "每页 20 条"}]
J
OUT="$(cd "$WT" && $SH reopen $K --why "intent gap" --decisions-file "$TMP/dec2.json")"
IDS="$(echo "$OUT" | sed -n 's/^DECISION_IDS=//p')"; X="${IDS%,*}"; Y="${IDS#*,}"
fake_exit $K blocked
$SH override "$X" --answer "按名称" --yes >/dev/null
fake_exit $K blocked
OUT="$($SH override "$Y" --answer "每页 50 条" --yes)"; RC=$?
[ $RC -eq 0 ] && grep -q "A: 按名称（${X}，用户改判）" "$SPEC" && grep -q "A: 每页 50 条（${Y}，用户改判）" "$SPEC" \
    && ok "D32 a second override in the same batch keeps the first one's answer" || { bad "D32 rc=$RC"; echo "$OUT"; cat "$SPEC"; }
$SH abandon $K --yes >/dev/null

K=9-37-nsov; WT="$TMP/wt/$K"
$SH prepare $K >/dev/null
lane_edit $K 'd["phase"] = "launched"; d["attempts"] = 1'
git -C "$WT" tag "harness/$K/start"
printf -- '---\nstatus: blocked\n---\n\nStatus: blocked\nBlocking condition: unclear intent\n' > "$WT/$ART/bmad-build-auto-result-y.md"
cat > "$TMP/dec3.json" <<'J'
[{"question": "用哪个数据库？", "chosen": "PostgreSQL"}]
J
OUT="$(cd "$WT" && $SH reopen $K --why "unclear intent" --decisions-file "$TMP/dec3.json")"
DID="$(echo "$OUT" | sed -n 's/^DECISION_IDS=//p')"; BASE="$(git -C "$WT" rev-parse HEAD)"
echo built > "$WT/src/$K.txt"; git -C "$WT" add -A; git -C "$WT" commit -qm "feat($K): built on the old answer"; git -C "$WT" tag "harness/$K/built"
fake_exit $K blocked
OUT="$($SH override "$DID" --answer "MySQL" --yes)"; RC=$?
[ $RC -eq 0 ] && [ "$(git -C "$WT" rev-parse HEAD)" = "$BASE" ] && ! git rev-parse -q --verify "refs/tags/harness/$K/built" >/dev/null \
    && grep -q 'MySQL' "$LANES/$K.notes.json" && ! grep -q 'PostgreSQL' "$LANES/$K.notes.json" \
    && [ "$($SH decisions --all --json | jget "[r['status'] for r in d if r['id']=='$DID'][0]")" = "overridden" ] \
    && [ "$(stage_of $K)" = "queued" ] \
    && ok "D33 override of a no-spec decision: reset, built dropped, notes carry the new answer" || { bad "D33 rc=$RC"; echo "$OUT"; }
$SH abandon $K --yes >/dev/null

K=9-38-done; WT="$TMP/wt/$K"; SPEC="$WT/$ART/spec-$K.md"
$SH prepare $K >/dev/null
git -C "$WT" tag "harness/$K/start"
blocked_spec "$WT" $K; sed -i "s/^status: 'blocked'/status: 'done'\nfollowup_review_recommended: true/" "$SPEC"
printf '{"key":"%s","reason":"quota_exhausted"}\n' "$K" > "$WT/$ART/$K.codex-skipped.json"
echo v1 > "$WT/src/$K.txt"; git -C "$WT" add -A; git -C "$WT" commit -qm "feat($K)"
git -C "$WT" tag "harness/$K/built"; git -C "$WT" tag "harness/$K/followup-start"
echo v2 > "$WT/src/$K.txt"; git -C "$WT" commit -qam "review($K): follow-up pass"
FS="$(git rev-parse "harness/$K/followup-start^{commit}")"
fake_exit $K failed
OUT="$($SH resume $K --note "看过了，没问题")"; RC=$?
[ $RC -eq 0 ] && ! echo "$OUT" | grep -q '^MOVED_TAG=' && [ "$(git rev-parse "harness/$K/followup-start^{commit}")" = "$FS" ] \
    && [ "$(hs_code "$WT" $K)" = "followup-verify" ] \
    && ok "D34 resume after B3 already ran (spec done) leaves followup-start alone" || { bad "D34 rc=$RC $(hs_code "$WT" $K)"; echo "$OUT"; }
$SH abandon $K --yes >/dev/null

python3 - "$SCRIPTS" <<'PY' && ok "D35 status rewrite keeps a single key on CRLF specs" || bad "D35"
import sys
sys.path.insert(0, sys.argv[1])
import superh
t = "---\r\ntitle: x\r\nstatus: 'blocked' # note\r\n---\r\nbody\r\n"
out = superh._with_status(t, "draft")
assert out.count("status:") == 1 and "status: 'draft' # note\r\n" in out, repr(out)
PY

K=9-39-busy
$SH prepare $K >/dev/null
sleep 300 & SP=$!
lane_edit $K "d['op'] = {'name': 'launch', 'pid': $SP, 'pid_start': '$(pstart $SP)', 'started_at': 'now'}"
OUT="$($SH launch $K)"; RC=$?
[ $RC -eq 4 ] && echo "$OUT" | grep -qx 'STATUS=busy' && [ "$(stage_of $K)" = "preparing" ] \
    && ! $SH tick | jget 'd["launch"] + d["queued"]' | grep -q $K \
    && ok "D36 a launch still checking the environment is not handed out or started twice" || { bad "D36 rc=$RC"; echo "$OUT"; }
kill $SP; wait $SP 2>/dev/null
$SH abandon $K --yes >/dev/null

OUT="$($SH start-run)"
echo "$OUT" | grep -q '^WARN=parallel.yaml 的 worker_model 留空' && echo "$OUT" | grep -qx 'DECISION_MODE=proceed' \
    && ok "D30 start-run warns about an empty worker_model" || { bad "D30"; echo "$OUT"; }
cfg_set env_down_command "'touch $TMP/env.down'"
OUT="$($SH end-run --finished)"
echo "$OUT" | grep -qx 'ENV_DOWN=ok' && [ -f "$TMP/env.down" ] && ok "D31 end-run --finished runs env_down_command" || { bad "D31"; echo "$OUT"; }
cfg_set env_down_command "''"
$SH start-run >/dev/null

OUT="$($SH end-run)"
echo "$OUT" | grep -q '^STATUS=ok' && [ ! -f "$(git rev-parse --git-common-dir)/super-harness/dispatcher.lock" ] \
    && ok "E1 end-run releases the lock" || { bad "E1"; echo "$OUT"; }

echo "== D18: 0.5.0 — suffix audit, spec decisions, resources, hooks, handling rows (issues #18-#26)"
# --- #21: a worker dispatch without the harness suffix → PROMPT_SUFFIX_MISSING + inbox
K=9-50-nosuffix
printf '## Build intent\n\nfollow-up review of spec X via bmad-build-auto\n\n---\n\nBUILD_SUFFIX_PLACEHOLDER\n' > ".fake-agent-$K"
$SH prepare $K >/dev/null
OUT="$($SH launch $K)"
echo "$OUT" | grep -q '^PROMPT_SUFFIX_MISSING=B3 Follow-up review X（prompt .* 字，结尾：.*BUILD_SUFFIX_PLACEHOLDER）' \
    && echo "$OUT" | grep -q '^DECISION_IDS=D' \
    && $SH decisions --json | jget "[r['kind'] for r in d if r['key']=='$K']" | grep -qx "\['audit'\]" \
    && [ "$(stage_of $K)" = "ready" ] \
    && ok "S1 dispatch without the suffix: reported, sent to the inbox, the lane still goes on (issue #21)" || { bad "S1"; echo "$OUT"; }
AID="$($SH decisions --json | jget "[r['id'] for r in d if r['key']=='$K'][0]")"
OUT="$($SH override $AID --answer "补跑 B3")"; RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -qx 'NEXT=manual' && ok "S2 overriding an audit entry is record-only (NEXT=manual)" || { bad "S2 rc=$RC"; echo "$OUT"; }
$SH abandon $K --yes >/dev/null
K=9-51-suffix
REF="$(cd "$TMP/wt/1-1-alpha" 2>/dev/null || cd "$PROJ"; python3 "$SCRIPTS/harness-prompt-suffix.py" build --file 2>/dev/null)"
printf '## Build intent\n\nrun bmad-build-auto on spec X\n\n---\n\n%s\n' "$REF" > ".fake-agent-$K"
F="$(echo "$REF" | sed -n 's/.*在 `\(.*\)`。.*/\1/p')"
echo "$REF" | tail -1 | grep -Eq '^\[harness-suffix build [0-9a-f]{8}\]$' && [ -f "$F" ] && grep -q '代答政策' "$F" \
    && [ "$(dirname "$F")" = "$(git rev-parse --path-format=absolute --git-common-dir)/super-harness/suffix" ] \
    && ok "S3 harness-prompt-suffix --file: suffix in the common git dir, two-line reference with marker" || { bad "S3"; echo "$REF"; }
$SH prepare $K >/dev/null
OUT="$($SH launch $K)"
! echo "$OUT" | grep -q '^PROMPT_SUFFIX_MISSING=' && ok "S4 a dispatch carrying the reference passes the audit" || { bad "S4"; echo "$OUT"; }
$SH abandon $K --yes >/dev/null
rm -f .fake-agent-9-5*

# --- #18: worker_model set, the worker runs on another model
cfg_set worker_model opus
K=9-52-model
$SH prepare $K >/dev/null
OUT="$($SH launch $K)"
echo "$OUT" | grep -q '^WARN=worker 实际用的模型 fake-model 和 parallel.yaml 的 worker_model opus 对不上' \
    && ok "S5 configured worker_model vs the init event's model: WARN on mismatch (issue #18)" || { bad "S5"; echo "$OUT"; }
cfg_set worker_model "''"
$SH abandon $K --yes >/dev/null
python3 - "$SCRIPTS" <<'PY2' && ok "S6 model check: alias match, full id match, mismatch" || bad "S6"
import sys
sys.path.insert(0, sys.argv[1])
import superh
m = superh._model_mismatch
assert not m("opus", "claude-opus-5-5") and not m("opus[1m]", "claude-opus-5-5")
assert m("opus", "claude-haiku-5-5") and not m("claude-sonnet-5-5", "claude-sonnet-5-5") and not m("", "x")
PY2

# --- #24: spec items listed for the user to confirm → inbox, idempotent
K=9-53-confirm
cat > ".fake-spec-extra-$K" <<'SPEC'

**残余风险和待用户确认的事**

1. fixture 的 id 没和控制面的实际输出交叉核对
2. 组合挂载时标记落在 route 上

### 待用户确认

- [C-1] 停用 service 怎么标 — 采用：标 disabled — 备选：标 removed / 不标（理由：和控制面一致（见 PRD §3））
- [C-2] 两个残余差异 — 采用：记录不修（并入 C-1）
- [C-3] 超长的一条：LONGQ_0123456789_0123456789_0123456789_0123456789_0123456789_0123456789_0123456789_END — 采用：照做 — 备选：LONGALT_0123456789_0123456789_0123456789_0123456789_0123456789_0123456789_END / 不做（理由：LONGWHY）
SPEC
$SH prepare $K >/dev/null
OUT="$($SH launch $K)"
IDS="$(echo "$OUT" | sed -n 's/^SPEC_DECISIONS_IMPORTED=//p')"
J="$($SH decisions --json)"
[ "$(echo "$IDS" | tr ',' '\n' | grep -c .)" = "5" ] && echo "$OUT" | grep -qx 'SPEC_DECISIONS=5' \
    && echo "$J" | jget "[r['chosen'] for r in d if r['key']=='$K' and r.get('spec_ref')=='C-1'][0]" | grep -qx '标 disabled' \
    && echo "$J" | jget "[r['why'] for r in d if r['key']=='$K' and r.get('spec_ref')=='C-1'][0]" | grep -qx '和控制面一致（见 PRD §3）' \
    && echo "$J" | jget "[r['why'] for r in d if r['key']=='$K' and r.get('spec_ref')=='C-2'][0]" | grep -qx '' \
    && C1="$(echo "$J" | jget "[r['id'] for r in d if r['key']=='$K' and r.get('spec_ref')=='C-1'][0]")" \
    && echo "$J" | jget "[r.get('merged_into') for r in d if r['key']=='$K' and r.get('spec_ref')=='C-2'][0]" | grep -qx "$C1" \
    && ok "S7 launch imports the spec's 待确认 items (both formats), C-2 merged into C-1's id (issue #24)" || { bad "S7"; echo "$OUT"; echo "$J"; }
OUT="$(cd "$TMP/wt/$K" && $SH spec-decisions $K)"
echo "$OUT" | grep -qx 'IMPORTED=' && echo "$OUT" | grep -qx 'SPEC_ITEMS=5' && echo "$OUT" | grep -qx 'INBOX_ITEMS=5' \
    && ok "S8 spec-decisions is idempotent and the counts match" || { bad "S8"; echo "$OUT"; }
# issue #27: 备选 → options; board shows them, --full shows everything uncut
J="$($SH decisions --json)"
[ "$(echo "$J" | jget "' | '.join([r['options'] for r in d if r['key']=='$K' and r.get('spec_ref')=='C-1'][0])")" = "标 removed | 不标" ] \
    && [ "$(echo "$J" | jget "len([r['options'] for r in d if r['key']=='$K' and r.get('spec_ref')=='C-2'][0])")" = "0" ] \
    && ok "S8a a row's 备选 is imported as the record's options (issue #27)" || { bad "S8a"; echo "$J"; }
OUT="$($SH board)"
echo "$OUT" | grep -qx '      备选：标 removed / 不标' && echo "$OUT" | grep -q '      备选：LONGALT_.*…$' \
    && ! echo "$OUT" | grep -q 'LONGQ_.*_END' && ! echo "$OUT" | grep -q 'LONGWHY' \
    && ok "S8b board prints a 备选 line for rows that have options, cut at 80 chars" || { bad "S8b"; echo "$OUT"; }
OUT="$($SH board --full)"
echo "$OUT" | grep -q 'LONGQ_.*_END$' && echo "$OUT" | grep -qx '      备选：LONGALT_0123456789_0123456789_0123456789_0123456789_0123456789_0123456789_END / 不做' \
    && echo "$OUT" | grep -qx '      理由：LONGWHY' && echo "$OUT" | grep -qx '      理由：和控制面一致（见 PRD §3）' \
    && ok "S8c board --full prints question, chosen, 备选 and 理由 uncut" || { bad "S8c"; echo "$OUT"; }
OUT="$($SH decisions)"
echo "$OUT" | grep -qx '    备选：标 removed / 不标' && ! echo "$OUT" | grep -q '    选项：标 removed' \
    && ok "S8d decisions labels a spec row's options 备选" || { bad "S8d"; echo "$OUT"; }
SPECF="$(ls "$TMP/wt/$K/$ART"/spec-$K.md)"
sed -i 's/^- \[C-2\] 两个残余差异 — 采用：记录不修（并入 C-1）$/- [C-2] 两个残余差异 — 采用：记录不修 — 备选：现在修（并入 C-1）/' "$SPECF"
OUT="$(cd "$TMP/wt/$K" && $SH spec-decisions $K)"
J="$($SH decisions --json)"
echo "$OUT" | grep -qx 'IMPORTED=' && echo "$OUT" | grep -qx 'INBOX_ITEMS=5' \
    && [ "$(echo "$J" | jget "' | '.join([r['options'] for r in d if r['key']=='$K' and r.get('spec_ref')=='C-2'][0])")" = "现在修" ] \
    && ok "S8e re-import fills in 备选 on a row imported without them, adds no row" || { bad "S8e"; echo "$OUT"; echo "$J"; }
git -C "$TMP/wt/$K" checkout -q -- "$SPECF" 2>/dev/null || true
OUT="$($SH override "$C1" --answer "标 removed")"; RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -qx 'NEXT=manual' && echo "$OUT" | grep -q "^SPEC=.*spec-$K.md" \
    && ok "S9 overriding a spec item: no reset point, NEXT=manual with the spec path" || { bad "S9 rc=$RC"; echo "$OUT"; }
$SH abandon $K --yes >/dev/null
rm -f ".fake-spec-extra-$K"
python3 - "$SCRIPTS" <<'PY2' && ok "S10 Clarifications blocks (already in the inbox) are not re-imported" || bad "S10"
import sys, tempfile, os
sys.path.insert(0, sys.argv[1])
import harness_spec
p = os.path.join(tempfile.mkdtemp(), "s.md")
open(p, "w", encoding="utf-8").write("<intent-contract>\n### Clarifications（2026-11-07，按推荐项代答，待确认）\n\n- Q: a\n  A: b（D1）\n</intent-contract>\n")
assert harness_spec.spec_confirm_items(p) == []
PY2

# --- #19: codex handling rows in another format
K=9-54-rows; WT="$TMP/wt/$K"
$SH prepare $K >/dev/null
git -C "$WT" tag "harness/$K/start"
printf -- '---\nstatus: done\n---\n\n## Auto Run Result\n\nStatus: done\n' > "$WT/$ART/spec-$K.md"
echo v1 > "$WT/src/$K.txt"; git -C "$WT" add -A; git -C "$WT" commit -qm "feat($K): implement"
printf -- '---\nstory: %s\nfindings: 2\n---\n- [high] a\n- [medium] b\n' "$K" > "$WT/$ART/$K.codex-review.md"
git -C "$WT" add -A; git -C "$WT" commit -qm "story($K): codex adversarial review report"
echo v2 > "$WT/src/$K.txt"
printf '\n### Codex Review Handling (Stage 3)\n\n- [F-1 high] a — fixed: src\n- **F-2 medium** b — `fixed`\n' >> "$WT/$ART/spec-$K.md"
OUT="$(cd "$WT" && python3 .claude/harness/scripts/harness-commit.py 4 $K)"; RC=$?
ST="$(cd "$WT" && python3 .claude/harness/scripts/harness-state.py $K --json)"
[ $RC -eq 1 ] && echo "$OUT" | grep -q 'HANDLING_ROW_MALFORMED=.*\*\*F-2 medium\*\*' && echo "$OUT" | grep -qx 'HANDLING_ROWS=1/2 (well-formed rows / codex findings)' \
    && [ "$(echo "$ST" | jget 'd["codex_handling_rows"]')" = "1" ] && [ "$(echo "$ST" | jget 'd["codex_handling_malformed"]')" = "1" ] \
    && ok "S11 stage 4 stops on a malformed handling row; harness-state counts it apart (issue #19)" || { bad "S11 rc=$RC"; echo "$OUT"; }
sed -i 's/^- \*\*F-2 medium\*\* b — `fixed`$/- [F-2 medium] b — fixed: src/' "$WT/$ART/spec-$K.md"
OUT="$(cd "$WT" && python3 .claude/harness/scripts/harness-commit.py 4 $K)"; RC=$?
[ $RC -eq 0 ] && ok "S12 rewritten rows pass" || { bad "S12 rc=$RC"; echo "$OUT"; }
git -C "$WT" reset -q --hard HEAD
# a code commit before baseline_revision is outside the reviewed diff
echo pre > "$WT/src/$K.pre"; git -C "$WT" add -A; git -C "$WT" commit -qm "feat($K): sneaked in"
BL="$(git -C "$WT" rev-parse HEAD)"
printf -- '---\nstatus: done\nbaseline_revision: %s\n---\n\n## Auto Run Result\n\nStatus: done\n' "$BL" > "$WT/$ART/spec-$K.md"
echo v3 > "$WT/src/$K.txt"; git -C "$WT" commit -qam "feat($K): reviewed part"
OUT="$(cd "$WT" && python3 .claude/harness/scripts/harness-commit.py build-verify $K)"; RC=$?
[ $RC -eq 0 ] && echo "$OUT" | grep -qx 'COMMITS=4' && echo "$OUT" | grep -q "^PRE_BASELINE_COMMIT=.* feat($K): sneaked in" \
    && ! echo "$OUT" | grep -q "^PRE_BASELINE_COMMIT=.*reviewed part" && echo "$OUT" | grep -q '^WARN=有 2 个改了项目代码的提交早于' \
    && ok "S13 build-verify lists the range's commits and warns on code commits before baseline_revision" || { bad "S13 rc=$RC"; echo "$OUT"; }
$SH abandon $K --yes >/dev/null

# --- #22: resources — never two lanes on one resource; acquire before launch, release when nobody needs it
python3 - "$ART/sprint-status.yaml" <<'PY2'
import sys, re
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
t = t.replace("development_status:\n", "development_status:\n  9-60-res-a: backlog\n  9-61-res-b: backlog\n  9-62-res-c: backlog\n", 1)
t += "\nstory_dependencies:\n  9-60-res-a: []\n  9-61-res-b: []\n  9-62-res-c: []\n"
open(p, "w", encoding="utf-8").write(t)
PY2
git add -A >/dev/null; git commit -qm "fixture: resource stories"
cfg_set epic_barrier false
cfg_set max_slots 3
cat >> .claude/harness/parallel.yaml <<EOF2
resources:
  9-60-*: [itenv]
  '9-61-*': [itenv, cores]
resource_acquire:
  itenv: 'echo up >> $TMP/itenv.log'
resource_release:
  itenv: 'echo down >> $TMP/itenv.log'
EOF2
L="$($SH tick | jget 'd["launch"]')"
echo "$L" | grep -q '9-60-res-a' && ! echo "$L" | grep -q '9-61-res-b' && echo "$L" | grep -q '9-62-res-c' \
    && ok "S14 two ready stories on one resource: only the first is handed out (issue #22)" || bad "S14 launch=$L"
$SH prepare 9-60-res-a >/dev/null
$SH plan --json | jget '[s for s in d["stories"] if s["key"]=="9-61-res-b"][0]["reasons"]' | grep -q '等待资源 itenv（9-60-res-a 正在用）' \
    && ok "S15 plan says which lane holds the resource" || { bad "S15"; $SH plan; }
OUT="$($SH launch 9-60-res-a)"
echo "$OUT" | grep -qx 'RESOURCE_ACQUIRED=itenv' && [ "$(cat "$TMP/itenv.log")" = "up" ] \
    && ok "S16 resource_acquire runs before the first worker that needs it" || { bad "S16"; echo "$OUT"; }
lane_edit 9-60-res-a 'd["phase"] = "merged"'
$SH tick | jget 'd["launch"]' | grep -q '9-61-res-b' && ok "S17 a merged lane frees its resources" || bad "S17"
lane_edit 9-60-res-a 'd["phase"] = "abandoned"'
# the story-done path (mark done / abandon) releases only what no unfinished story needs
OUT="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import superh; superh._release_resources(superh.Ctx())' "$SCRIPTS")"
[ -z "$OUT" ] && [ "$(cat "$TMP/itenv.log")" = "up" ] && ok "S18 not released while an unfinished story (9-61) still needs it" || bad "S18 $OUT"
OUT="$($SH end-run --finished)"
echo "$OUT" | grep -qx 'RESOURCE_RELEASED=itenv' && [ "$(tail -1 "$TMP/itenv.log")" = "down" ] \
    && ok "S19 end-run --finished releases what is still acquired" || { bad "S19"; echo "$OUT"; }

# --- #26: lane cleanup hook and post-epic
cfg_set lane_cleanup_command "'echo \"\$SUPERH_KEY \$SUPERH_WORKTREE\" >> $TMP/cleanup.log'"
K=9-63-hook
$SH prepare $K >/dev/null
OUT="$($SH abandon $K --yes)"
echo "$OUT" | grep -qx 'HOOK=lane_cleanup_command ok' && grep -qx "$K $TMP/wt/$K" "$TMP/cleanup.log" \
    && ok "S20 lane_cleanup_command runs before the worktree is removed, with key and path (issue #26)" || { bad "S20"; echo "$OUT"; }
cfg_set post_epic_command "'echo \"\$SUPERH_EPIC\" >> $TMP/post.log'"
K=9-64-busy
$SH prepare $K >/dev/null
sleep 300 & SP=$!
python3 - "$LANES/$K.proc.json" "$SP" "$(pstart $SP)" <<'PY2'
import json, sys
json.dump({"key": "9-64-busy", "attempt": 1, "pid": int(sys.argv[2]), "pid_start": sys.argv[3], "exit_code": None}, open(sys.argv[1], "w"))
PY2
lane_edit $K 'd["phase"] = "launched"; d["attempts"] = 1'
OUT="$($SH post-epic 7)"
T="$($SH tick)"
echo "$OUT" | grep -qx 'STATUS=deferred' && [ ! -f "$TMP/post.log" ] && [ "$(echo "$T" | jget 'd["launch"]')" = "[]" ] \
    && [ "$(echo "$T" | jget 'd["post_epic"]')" = "['7']" ] && [ "$(echo "$T" | jget 'd["next_action"]')" = "wait" ] \
    && ok "S21 post-epic waits for running lanes; no new workers meanwhile" || { bad "S21"; echo "$OUT"; echo "$T" | head -5; }
kill $SP; wait $SP 2>/dev/null
lane_edit $K 'd["phase"] = "abandoned"'
[ "$($SH tick | jget 'd["next_action"]')" = "post-epic" ] && OUT="$($SH post-epic 7)" \
    && echo "$OUT" | grep -qx 'POST_EPIC=ok' && [ "$(cat "$TMP/post.log")" = "7" ] \
    && [ "$($SH tick | jget 'd["post_epic"]')" = "[]" ] && echo "$($SH post-epic 7)" | grep -qx 'STATUS=skip' \
    && ok "S22 then tick says post-epic, it runs once, launches resume" || { bad "S22"; echo "$OUT"; }
cfg_set lane_cleanup_command "''"; cfg_set post_epic_command "''"

echo
echo "superh_test: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

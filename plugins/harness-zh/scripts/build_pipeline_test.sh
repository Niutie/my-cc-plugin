#!/bin/bash
# Self-test for the v0.2.0 build pipeline (BMad 6.11+ bmad-build-auto):
#
#   V1 — build-verify ok: spec done + Auto Run Result + project code, spec and
#        epic-<N>-context.md committed in start..HEAD; info lines emitted
#   V2 — build-verify halts on a blocked spec and surfaces Auto Run Result
#   V3 — build-verify halts on a dirty worktree
#   V4 — build-verify halts on another story's spec in the range (CROSS_STORY)
#   V5 — build-verify halts on a credential file in the range (BLACKLIST)
#   V6 — build-verify: planning-artifacts writeback halts unless the spec
#        declares it in `planning_artifacts:`
#   V7 — build-verify reports CODEX_LAYER_SKIPPED=true from the latest review pass
#   S1 — build-sync: story → done, epic backlog → in-progress, spec
#        `deferred:` imported as schema v1 FU bullets, done tag suggested
#   S2 — build-sync re-run is idempotent: nothing new → STATUS=skip + SUGGEST_TAG
#   H1 — harness-state next_action_code walks not-started → build →
#        build-verify → sync / codex / followup → tag-only, plus --story-md
#        and --in-flight
#   A1 — sprint-status.py action-status get/set on native action_items;
#        epic-all-done treats wont-do as terminal
#   P1 — harness-prompt-suffix.py build / implement / chore emit their blocks
#   R1 — check_bmad_runtime.sh: missing skill + no uv → STATUS=fail with
#        REMEDIATION lines; installed layout + fake uv → STATUS=ok
#   G1 — pre-commit gate ① trigger regex covers spec-<N>-<M>-*.md for any epic
#        and skips sidecars
#
# Scripts are deployed into each tmp repo's .claude/harness/scripts/ (the
# init layout — sprint-status.py resolves the yaml relative to its own
# location) and committed in the seed, so they never show up in the audited
# range or the worktree.
# 整脚本退出码 = 失败 fixture 数（0 = 全过）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HC=".claude/harness/scripts/harness-commit.py"
HS=".claude/harness/scripts/harness-state.py"
SS=".claude/harness/scripts/sprint-status.py"
SUF="$SCRIPT_DIR/harness-prompt-suffix.py"
RT="$SCRIPT_DIR/check_bmad_runtime.sh"
ART="_bmad-output/implementation-artifacts"

failed=0
pass() { echo "PASS [$1]"; }
fail() { echo "FAIL [$1]: $2" >&2; failed=$((failed+1)); }

seed_repo() {
    local dir
    dir="$(mktemp -d -t build_pipe.XXXXXX)"
    (
        cd "$dir"
        git init -q
        git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
        mkdir -p "$ART" _bmad-output/planning-artifacts src .claude/harness/scripts
        cp "$SCRIPT_DIR"/harness-commit.py "$SCRIPT_DIR"/harness-state.py "$SCRIPT_DIR"/sprint-status.py \
           "$SCRIPT_DIR"/harness_config.py "$SCRIPT_DIR"/harness_spec.py .claude/harness/scripts/
        printf 'artifacts_root: "_bmad-output/implementation-artifacts"\n' > .claude/harness/harness-project-config.yaml
        printf '# epics\n' > _bmad-output/planning-artifacts/epics.md
        cat > "$ART/sprint-status.yaml" <<'EOF'
last_updated: 2026-10-01
development_status:
  epic-9: backlog
  9-1-foo: backlog
  9-2-bar: backlog
  epic-9-retrospective: optional

action_items:
  - id: "epic-8-retro-H1"
    epic: 8
    action: "do the thing"
    owner: "solo-dev"
    status: open
    ref: "x.md"
EOF
        printf '# Deferred Work\n\n---\n\n## Deferred from: seed (2026-01-01)\n\n- **FU-1.1.A** `[status:pending]` `[bucket:other]` `[target:Epic 1]` `[source:dev-of-1.1]` — seed\n' > "$ART/deferred-work.md"
        echo 'print(1)' > src/a.py
        git add -A; git commit -q -m seed
        git tag harness/9-1-foo/start
    )
    echo "$dir"
}

# write a bmad-build-auto style spec; $1=dir $2=status $3=extra frontmatter $4=extra body
write_spec() {
    local base
    base="$(cd "$1" && git rev-parse HEAD)"
    cat > "$1/$ART/spec-9-1-foo.md" <<EOF
---
title: 'foo'
type: 'feature'
status: '$2' # draft | ready-for-dev | in-progress | in-review | done | blocked
baseline_revision: '$base'
followup_review_recommended: false
context: []
$3
---

<intent-contract>

## Intent

**Problem:** x

</intent-contract>

## Review Triage Log

### 2026-10-27 — Review pass
- verdicts: 0 findings
$4

## Auto Run Result

Status: $2
EOF
}

# ============================================================================
# V1 — build-verify ok
# ============================================================================
dir="$(seed_repo)"
(
    cd "$dir"
    echo 'print(2)' > src/a.py
    printf '# Epic 9 Context: x\n' > "$ART/epic-9-context.md"
    write_spec "$dir" done 'deferred: []' ''
    git add -A; git commit -q -m "feat: foo"
)
ex=0; out="$(cd "$dir" && python3 "$HC" build-verify 9-1-foo 2>&1)" || ex=$?
rm -rf "$dir"
if [ "$ex" = 0 ] && printf '%s' "$out" | grep -qx "STATUS=ok" \
   && printf '%s' "$out" | grep -qx "SPEC_FILE=$ART/spec-9-1-foo.md" \
   && printf '%s' "$out" | grep -qx "FOLLOWUP_RECOMMENDED=false" \
   && printf '%s' "$out" | grep -qx "CODEX_LAYER_SKIPPED=false" \
   && printf '%s' "$out" | grep -q "^BASELINE_REVISION="; then
    pass "V1 build-verify ok"
else
    fail "V1" "exit=$ex out=$out"
fi

# ============================================================================
# V2 — blocked spec
# ============================================================================
dir="$(seed_repo)"
(
    cd "$dir"
    write_spec "$dir" blocked '' ''
    printf 'Blocking condition: intent gap\n' >> "$ART/spec-9-1-foo.md"
    git add -A; git commit -q -m "wip"
)
ex=0; out="$(cd "$dir" && python3 "$HC" build-verify 9-1-foo 2>&1)" || ex=$?
rm -rf "$dir"
if [ "$ex" = 1 ] && printf '%s' "$out" | grep -qx "SPEC_STATUS_NOT_DONE=blocked" \
   && printf '%s' "$out" | grep -q "^AUTO_RUN_RESULT=Blocking condition: intent gap"; then
    pass "V2 blocked spec halts with Auto Run Result"
else
    fail "V2" "exit=$ex out=$out"
fi

# ============================================================================
# V3 — dirty worktree
# ============================================================================
dir="$(seed_repo)"
(
    cd "$dir"
    write_spec "$dir" done '' ''
    git add -A; git commit -q -m "feat"
    echo 'stray' > src/stray.py
)
ex=0; out="$(cd "$dir" && python3 "$HC" build-verify 9-1-foo 2>&1)" || ex=$?
rm -rf "$dir"
if [ "$ex" = 1 ] && printf '%s' "$out" | grep -qx "DIRTY_WORKTREE=src/stray.py"; then
    pass "V3 dirty worktree halts"
else
    fail "V3" "exit=$ex out=$out"
fi

# ============================================================================
# V4 — another story's spec in range
# ============================================================================
dir="$(seed_repo)"
(
    cd "$dir"
    write_spec "$dir" done '' ''
    printf -- '---\nstatus: done\n---\n' > "$ART/spec-9-2-bar.md"
    echo 'x' >> src/a.py
    git add -A; git commit -q -m "feat"
)
ex=0; out="$(cd "$dir" && python3 "$HC" build-verify 9-1-foo 2>&1)" || ex=$?
rm -rf "$dir"
if [ "$ex" = 1 ] && printf '%s' "$out" | grep -qx "CROSS_STORY=$ART/spec-9-2-bar.md" \
   && ! printf '%s' "$out" | grep -q "CROSS_STORY=$ART/spec-9-1-foo.md"; then
    pass "V4 cross-story spec halts, own spec allowed"
else
    fail "V4" "exit=$ex out=$out"
fi

# ============================================================================
# V5 — credential file in range
# ============================================================================
dir="$(seed_repo)"
(
    cd "$dir"
    write_spec "$dir" done '' ''
    echo 'SECRET=1' > .env
    git add -A; git commit -q -m "feat"
)
ex=0; out="$(cd "$dir" && python3 "$HC" build-verify 9-1-foo 2>&1)" || ex=$?
rm -rf "$dir"
if [ "$ex" = 1 ] && printf '%s' "$out" | grep -q "^BLACKLIST=.env "; then
    pass "V5 blacklist halts"
else
    fail "V5" "exit=$ex out=$out"
fi

# ============================================================================
# V6 — planning-artifacts writeback: undeclared halts, declared passes
# ============================================================================
dir="$(seed_repo)"
(
    cd "$dir"
    write_spec "$dir" done '' ''
    echo '## amended' >> _bmad-output/planning-artifacts/epics.md
    git add -A; git commit -q -m "feat"
)
ex=0; out="$(cd "$dir" && python3 "$HC" build-verify 9-1-foo 2>&1)" || ex=$?
rm -rf "$dir"
dir="$(seed_repo)"
(
    cd "$dir"
    write_spec "$dir" done $'planning_artifacts:\n  - _bmad-output/planning-artifacts/epics.md' ''
    echo '## amended' >> _bmad-output/planning-artifacts/epics.md
    git add -A; git commit -q -m "feat"
)
ex2=0; out2="$(cd "$dir" && python3 "$HC" build-verify 9-1-foo 2>&1)" || ex2=$?
rm -rf "$dir"
if [ "$ex" = 1 ] && printf '%s' "$out" | grep -qx "OUT_OF_SCOPE_BMAD=_bmad-output/planning-artifacts/epics.md" \
   && [ "$ex2" = 0 ]; then
    pass "V6 planning writeback needs declaration"
else
    fail "V6" "undeclared exit=$ex out=$out | declared exit=$ex2 out=$out2"
fi

# ============================================================================
# V7 — codex layer skipped in latest review pass
# ============================================================================
dir="$(seed_repo)"
(
    cd "$dir"
    write_spec "$dir" done '' '- codex-cross-model: SKIPPED — timed out after 580s'
    echo 'x' >> src/a.py
    git add -A; git commit -q -m "feat"
)
out="$(cd "$dir" && python3 "$HC" build-verify 9-1-foo 2>&1)"
rm -rf "$dir"
if printf '%s' "$out" | grep -qx "CODEX_LAYER_SKIPPED=true"; then
    pass "V7 codex layer skip detected"
else
    fail "V7" "out=$out"
fi

# ============================================================================
# S1 / S2 — build-sync
# ============================================================================
dir="$(seed_repo)"
(
    cd "$dir"
    write_spec "$dir" done $'deferred:\n  - summary: >-\n      cache key collides\n      on reload\n    evidence: |-\n      seen in logs\n    location: >-\n      src/a.py:1\n    severity: medium\n  - summary: second item' ''
    echo 'x' >> src/a.py
    git add -A; git commit -q -m "feat"
)
ex=0; out="$(cd "$dir" && python3 "$HC" build-sync 9-1-foo 2>&1)" || ex=$?
ss_story="$(cd "$dir" && python3 "$SS" status 9-1-foo 2>/dev/null)"
ss_epic="$(cd "$dir" && python3 "$SS" status epic-9 2>/dev/null)"
dw="$(cat "$dir/$ART/deferred-work.md")"
if [ "$ex" = 0 ] && printf '%s' "$out" | grep -qx "STATUS=ok" \
   && printf '%s' "$out" | grep -qx "SUGGEST_TAG=harness/9-1-foo/done" \
   && printf '%s' "$out" | grep -qx "SUGGEST_COMMIT_MSG=story(9-1-foo): sync sprint status & deferred ledger" \
   && [ "$ss_story" = done ] && [ "$ss_epic" = in-progress ] \
   && printf '%s' "$dw" | grep -qF -- '- **FU-9.1.B1** `[status:pending]` `[bucket:other]` `[target:Epic 9]` `[source:build-auto-of-9.1]` — cache key collides on reload' \
   && printf '%s' "$dw" | grep -qF -- '  - **关联**：spec-9-1-foo.md / src/a.py:1 / severity:medium' \
   && printf '%s' "$dw" | grep -qF '**FU-9.1.B2**' \
   && printf '%s' "$dw" | grep -q '^## Deferred from: build-auto of 9-1-foo ('; then
    pass "S1 build-sync syncs status + imports deferred"
else
    fail "S1" "exit=$ex story=$ss_story epic=$ss_epic out=$out dw=$dw"
fi
# deferred-work.md must still satisfy the schema lint on the imported block
if bash "$SCRIPT_DIR/lint_deferred_work.sh" "$dir/$ART/deferred-work.md" >/dev/null 2>&1; then
    pass "S1b imported FU bullets pass lint_deferred_work.sh"
else
    fail "S1b" "$(bash "$SCRIPT_DIR/lint_deferred_work.sh" "$dir/$ART/deferred-work.md" 2>&1 | tail -5)"
fi
(cd "$dir" && git add -A && git commit -q -m sync)
ex=0; out="$(cd "$dir" && python3 "$HC" build-sync 9-1-foo 2>&1)" || ex=$?
n_b1="$(grep -c 'FU-9.1.B1' "$dir/$ART/deferred-work.md")"
rm -rf "$dir"
if [ "$ex" = 2 ] && printf '%s' "$out" | grep -qx "STATUS=skip" \
   && printf '%s' "$out" | grep -qx "SUGGEST_TAG=harness/9-1-foo/done" && [ "$n_b1" = 1 ]; then
    pass "S2 build-sync idempotent"
else
    fail "S2" "exit=$ex n_b1=$n_b1 out=$out"
fi

# ============================================================================
# H1 — harness-state state machine
# ============================================================================
code_of() { (cd "$1" && python3 "$HS" "$2" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["next_action_code"])'); }
dir="$(seed_repo)"
h_ok=1; h_log=""
c="$(code_of "$dir" 9-2-bar)"; [ "$c" = not-started ] || { h_ok=0; h_log+=" not-started:$c"; }
c="$(code_of "$dir" 9-1-foo)"; [ "$c" = build ] || { h_ok=0; h_log+=" build:$c"; }
(cd "$dir" && write_spec "$dir" in-progress '' '')
c="$(code_of "$dir" 9-1-foo)"; [ "$c" = build ] || { h_ok=0; h_log+=" build-resume:$c"; }
(cd "$dir" && write_spec "$dir" done '' '' && echo y >> src/a.py && git add -A && git commit -q -m feat)
c="$(code_of "$dir" 9-1-foo)"; [ "$c" = build-verify ] || { h_ok=0; h_log+=" build-verify:$c"; }
(cd "$dir" && git tag harness/9-1-foo/built)
c="$(code_of "$dir" 9-1-foo)"; [ "$c" = codex ] || { h_ok=0; h_log+=" codex:$c"; }
mkdir -p "$dir/_bmad/custom"
printf '[[workflow.review_layers]]\nid = "codex-cross-model"\nname = "Codex"\ninstruction = "run codex"\n' > "$dir/_bmad/custom/bmad-build-auto.toml"
c="$(code_of "$dir" 9-1-foo)"; [ "$c" = sync ] || { h_ok=0; h_log+=" sync:$c"; }
sed -i 's/^followup_review_recommended: false/followup_review_recommended: true/' "$dir/$ART/spec-9-1-foo.md"
(cd "$dir" && git add -A && git commit -q -m flag)
c="$(code_of "$dir" 9-1-foo)"; [ "$c" = followup ] || { h_ok=0; h_log+=" followup:$c"; }
(cd "$dir" && git tag harness/9-1-foo/followup)
c="$(code_of "$dir" 9-1-foo)"; [ "$c" = sync ] || { h_ok=0; h_log+=" sync2:$c"; }
(cd "$dir" && git commit -q --allow-empty -m "story(9-1-foo): sync sprint status & deferred ledger")
c="$(code_of "$dir" 9-1-foo)"; [ "$c" = tag-only ] || { h_ok=0; h_log+=" tag-only:$c"; }
md="$(cd "$dir" && python3 "$HS" 9-1-foo --story-md 2>/dev/null)"
[ "$md" = "$ART/spec-9-1-foo.md" ] || { h_ok=0; h_log+=" story-md:$md"; }
inflight="$(cd "$dir" && python3 "$HS" --in-flight 2>/dev/null)"
[ "$inflight" = 9-1-foo ] || { h_ok=0; h_log+=" in-flight:$inflight"; }
(cd "$dir" && git tag harness/9-1-foo/done)
inflight="$(cd "$dir" && python3 "$HS" --in-flight 2>/dev/null)"
[ -z "$inflight" ] || { h_ok=0; h_log+=" in-flight-after-done:$inflight"; }
rm -rf "$dir"
if [ "$h_ok" = 1 ]; then pass "H1 harness-state build pipeline codes"; else fail "H1" "$h_log"; fi

# ============================================================================
# A1 — action-status + wont-do terminal
# ============================================================================
dir="$(seed_repo)"
a_ok=1; a_log=""
v="$(cd "$dir" && python3 "$SS" action-status epic-8-retro-H1 2>/dev/null)"; [ "$v" = open ] || { a_ok=0; a_log+=" get:$v"; }
(cd "$dir" && python3 "$SS" action-status epic-8-retro-H1 done >/dev/null 2>&1)
v="$(cd "$dir" && python3 "$SS" action-status epic-8-retro-H1 2>/dev/null)"; [ "$v" = done ] || { a_ok=0; a_log+=" set:$v"; }
(cd "$dir" && python3 "$SS" action-status nope >/dev/null 2>&1) && { a_ok=0; a_log+=" missing-id-rc0"; }
(cd "$dir" && python3 "$SS" set 9-1-foo done >/dev/null 2>&1 && python3 "$SS" set 9-2-bar wont-do >/dev/null 2>&1)
(cd "$dir" && python3 "$SS" epic-all-done 9 >/dev/null 2>&1) || { a_ok=0; a_log+=" wont-do-not-terminal"; }
rm -rf "$dir"
if [ "$a_ok" = 1 ]; then pass "A1 action-status + wont-do terminal"; else fail "A1" "$a_log"; fi

# ============================================================================
# P1 — prompt suffix stages
# ============================================================================
b="$(python3 "$SUF" build 2>/dev/null)"; i="$(python3 "$SUF" implement 2>/dev/null)"; ch="$(python3 "$SUF" chore 2>/dev/null)"
if printf '%s' "$b" | grep -q "bmad-build-auto-suffix.md" && printf '%s' "$b" | grep -q "harness/<KEY>/start..HEAD" \
   && printf '%s' "$b" | grep -q "代答政策" \
   && printf '%s' "$i" | grep -q "Q6" && ! printf '%s' "$i" | grep -q "dev-result.json" \
   && printf '%s' "$ch" | grep -q "git status --porcelain" && ! printf '%s' "$ch" | grep -q "dev-result.json"; then
    pass "P1 build / implement / chore suffix blocks"
else
    fail "P1" "build/implement/chore output missing expected markers"
fi

# ============================================================================
# R1 — check_bmad_runtime.sh
# ============================================================================
root="$(mktemp -d -t rt.XXXXXX)"
nouv="$(mktemp -d -t nouv.XXXXXX)"
for t in bash python3 awk tr sed dirname cat; do ln -s "$(command -v $t)" "$nouv/$t"; done
ex=0; out="$(PATH="$nouv" HOME="$root" bash "$RT" --project-root "$root" 2>&1)" || ex=$?
mkdir -p "$root/.claude/skills/bmad-build-auto" "$root/_bmad/scripts" "$root/_bmad/_config" "$root/fakebin"
touch "$root/.claude/skills/bmad-build-auto/SKILL.md" "$root/_bmad/scripts/render_skill.py"
printf 'installation:\n  version: 6.12.4\n' > "$root/_bmad/_config/manifest.yaml"
printf '#!/bin/sh\nexit 0\n' > "$root/fakebin/uv"; chmod +x "$root/fakebin/uv"
ex2=0; out2="$(PATH="$root/fakebin:$nouv" HOME="$root" bash "$RT" --project-root "$root" 2>&1)" || ex2=$?
rm -rf "$root" "$nouv"
if [ "$ex" = 1 ] && printf '%s' "$out" | grep -qx "UV=missing" && printf '%s' "$out" | grep -qx "BUILD_AUTO_SKILL=missing" \
   && printf '%s' "$out" | grep -q "^REMEDIATION=" \
   && [ "$ex2" = 0 ] && printf '%s' "$out2" | grep -qx "STATUS=ok" && printf '%s' "$out2" | grep -qx "BMAD_VERSION=6.12.4"; then
    pass "R1 runtime probe"
else
    fail "R1" "missing: exit=$ex out=$out | ok: exit=$ex2 out=$out2"
fi

# ============================================================================
# G1 — pre-commit gate ① trigger regex
# ============================================================================
TRIG="$(sed -n "s/^RETRO_TRIGGER='\(.*\)'$/\1/p" "$SCRIPT_DIR/../git-hooks/pre-commit")"
g_ok=1
for p in "$ART/spec-130-7-mcp.md" "$ART/5-1-foo.md" "$ART/12-3-中文.md"; do
    echo "$p" | grep -qE "$TRIG" || { g_ok=0; echo "  should hit: $p" >&2; }
done
for p in "$ART/5-1-foo.codex-review.md" "$ART/spec-gl-1267-x.md" "$ART/spec-1012-guard.md" "$ART/epic-5-retro-2026.md"; do
    echo "$p" | grep -qE "$TRIG" && { g_ok=0; echo "  should miss: $p" >&2; }
done
if [ "$g_ok" = 1 ]; then pass "G1 gate ① trigger regex"; else fail "G1" "regex=$TRIG"; fi

# ============================================================================
# Review regressions (2026-10-27 independent review)
# ============================================================================
SPEC_PY="$SCRIPT_DIR/harness_spec.py"

# N1 — CJK key, build-auto picked an English slug → still resolved; -n wins
d="$(mktemp -d -t nres.XXXXXX)"
printf -- '---\nstatus: done\n---\n' > "$d/spec-124-1-test-env-baseline.md"
printf -- '---\nstatus: done\n---\n' > "$d/spec-124-10-other.md"
printf -- '---\nstatus: done\n---\n' > "$d/spec-7-2-foo.md"
printf -- '---\nstatus: in-review\n---\n' > "$d/spec-7-2-foo-2.md"
r1="$(python3 -c "import sys; sys.path.insert(0,'$SCRIPT_DIR'); import harness_spec as h; print(h.resolve_story_md('124-1-测试环境基线', '$d/'))")"
r2="$(python3 -c "import sys; sys.path.insert(0,'$SCRIPT_DIR'); import harness_spec as h; print(h.resolve_story_md('7-2-foo', '$d/'))")"
r3="$(python3 -c "import sys; sys.path.insert(0,'$SCRIPT_DIR'); import harness_spec as h; print(h.is_story_spec_name('spec-124-10-other.md','124-1-x'), h.short_id('124-4b-x'))")"
rm -rf "$d"
if [ "$r1" = spec-124-1-test-env-baseline.md ] && [ "$r2" = spec-7-2-foo-2.md ] && [ "$r3" = "False 124.4b" ]; then
    pass "N1 spec resolution by epic/story prefix"
else
    fail "N1" "r1=$r1 r2=$r2 r3=$r3"
fi

# N2 — codex skip detection ignores negations
d="$(mktemp -d -t nskip.XXXXXX)"
mk() { printf -- '---\nstatus: done\n---\n\n## Review Triage Log\n\n### 2026-10-27 — Review pass\n%s\n\n## Auto Run Result\n' "$2" > "$d/$1"; }
mk a.md '- codex-cross-model: SKIPPED — timeout'
mk b.md '- codex-cross-model：**SKIPPED** — quota'
mk c.md '- codex-cross-model 四路全部执行，无 SKIPPED'
mk e.md '- codex-cross-model: RAN, 3 findings (not skipped)'
res="$(python3 -c "import sys; sys.path.insert(0,'$SCRIPT_DIR'); import harness_spec as h; print([h.codex_layer_skipped('$d/'+f) for f in ('a.md','b.md','c.md','e.md')])")"
rm -rf "$d"
if [ "$res" = "[True, True, False, False]" ]; then pass "N2 codex skip detection"; else fail "N2" "$res"; fi

# N3 — build-verify: NO_CODE_CHANGE + BUILD_AUTO_RESULT
dir="$(seed_repo)"
(cd "$dir" && write_spec "$dir" done '' '' && git add -A && git commit -q -m "spec only")
ex=0; out="$(cd "$dir" && python3 "$HC" build-verify 9-1-foo 2>&1)" || ex=$?
rm -rf "$dir"
dir="$(seed_repo)"
printf -- '---\nstatus: blocked\n---\n\n# BMad Build Auto Result\n\nStatus: blocked\nBlocking condition: version-control metadata not writable\n' > "$dir/$ART/bmad-build-auto-result-9-1.md"
ex2=0; out2="$(cd "$dir" && python3 "$HC" build-verify 9-1-foo 2>&1)" || ex2=$?
c2="$(code_of "$dir" 9-1-foo)"
rm -rf "$dir"
if [ "$ex" = 1 ] && printf '%s' "$out" | grep -q "^NO_CODE_CHANGE=" \
   && [ "$ex2" = 1 ] && printf '%s' "$out2" | grep -q "^BUILD_AUTO_RESULT=$ART/bmad-build-auto-result-9-1.md" \
   && printf '%s' "$out2" | grep -q "^AUTO_RUN_RESULT=Blocking condition: version-control" \
   && ! printf '%s' "$out2" | grep -q "^DIRTY_WORKTREE=" && [ "$c2" = blocked ]; then
    pass "N3 NO_CODE_CHANGE + pre-spec HALT surfaced"
else
    fail "N3" "ex=$ex out=$out | ex2=$ex2 code=$c2 out2=$out2"
fi

# N4 — follow-up resume: followup-start + moved HEAD → followup-verify (no second pass)
dir="$(seed_repo)"
mkdir -p "$dir/_bmad/custom"
printf '[[workflow.review_layers]]\nid = "codex-x"\ninstruction = "x"\n' > "$dir/_bmad/custom/bmad-build-auto.toml"
(cd "$dir" && write_spec "$dir" done '' '' && sed -i 's/^followup_review_recommended: false/followup_review_recommended: true/' "$ART/spec-9-1-foo.md" \
   && echo y >> src/a.py && git add -A && git commit -q -m feat && git tag harness/9-1-foo/built && git tag harness/9-1-foo/followup-start)   # git add -A also tracks the _bmad/custom toml
c_a="$(code_of "$dir" 9-1-foo)"
(cd "$dir" && echo z >> src/a.py && git add -A && git commit -q -m "review pass")
c_b="$(code_of "$dir" 9-1-foo)"
rm -rf "$dir"
if [ "$c_a" = followup ] && [ "$c_b" = followup-verify ]; then pass "N4 follow-up resume"; else fail "N4" "before=$c_a after=$c_b"; fi

# N5 — in-flight excludes stories already done in sprint-status; EPIC_WONT_DO emitted
dir="$(seed_repo)"
(cd "$dir" && git tag harness/9-2-bar/start && python3 "$SS" set 9-1-foo done >/dev/null 2>&1 && python3 "$SS" set 9-2-bar wont-do >/dev/null 2>&1 \
   && git add -A && git commit -q -m "closed outside harness")
inf="$(cd "$dir" && python3 "$HS" --in-flight 2>/dev/null)"
printf -- '---\nepic: 9\nverdict: rejected\n---\n# retro\n' > "$dir/$ART/epic-9-retro-2026-10-27.md"
(cd "$dir" && git add -A && git commit -q -m retro)
out="$(cd "$dir" && python3 "$HC" 6-done 9-1-foo --epic 9 2>&1)"
rm -rf "$dir"
if [ -z "$inf" ] && printf '%s' "$out" | grep -qx "RETRO_VERDICT=rejected" && printf '%s' "$out" | grep -qx "EPIC_WONT_DO=9-2-bar"; then
    pass "N5 in-flight filter + verdict/wont-do on 6-done skip"
else
    fail "N5" "inflight=$inf out=$out"
fi

# N7 — `cancelled` is terminal (issue #13): epic-all-done passes, --in-flight
#      skips it, EPIC_WONT_DO lists it
dir="$(seed_repo)"
(cd "$dir" && git tag harness/9-2-bar/start && python3 "$SS" set 9-1-foo done >/dev/null 2>&1 && python3 "$SS" set 9-2-bar cancelled >/dev/null 2>&1 \
   && git add -A && git commit -q -m "voided at planning")
(cd "$dir" && python3 "$SS" epic-all-done 9 >/dev/null 2>&1); n7_rc=$?
inf="$(cd "$dir" && python3 "$HS" --in-flight 2>/dev/null)"
printf -- '---\nepic: 9\nverdict: rejected\n---\n# retro\n' > "$dir/$ART/epic-9-retro-2026-10-31.md"
(cd "$dir" && git add -A && git commit -q -m retro)
out="$(cd "$dir" && python3 "$HC" 6-done 9-1-foo --epic 9 2>&1)"
rm -rf "$dir"
if [ "$n7_rc" = 0 ] && [ -z "$inf" ] && printf '%s' "$out" | grep -qx "EPIC_WONT_DO=9-2-bar"; then
    pass "N7 cancelled terminal + EPIC_WONT_DO"
else
    fail "N7" "epic-all-done rc=$n7_rc inflight=$inf out=$out"
fi

# N8 — epic-all-done splits pending into active= / unrecognized=; hint only
#      when nothing is active
dir="$(seed_repo)"
(cd "$dir" && python3 "$SS" set 9-1-foo done >/dev/null 2>&1 && python3 "$SS" set 9-2-bar superseded >/dev/null 2>&1)
err_u="$(cd "$dir" && python3 "$SS" epic-all-done 9 2>&1 >/dev/null)"; rc_u=$?
(cd "$dir" && python3 "$SS" set 9-2-bar in-progress >/dev/null 2>&1)
err_a="$(cd "$dir" && python3 "$SS" epic-all-done 9 2>&1 >/dev/null)"; rc_a=$?
rm -rf "$dir"
if [ "$rc_u" = 1 ] && printf '%s' "$err_u" | grep -qx "active=none" \
   && printf '%s' "$err_u" | grep -qx "unrecognized=9-2-bar(superseded)" && printf '%s' "$err_u" | grep -q "^hint:" \
   && [ "$rc_a" = 1 ] && printf '%s' "$err_a" | grep -qx "active=9-2-bar(in-progress)" \
   && printf '%s' "$err_a" | grep -qx "unrecognized=none" && ! printf '%s' "$err_a" | grep -q "^hint:"; then
    pass "N8 epic-all-done active/unrecognized split"
else
    fail "N8" "rc_u=$rc_u err_u=$err_u | rc_a=$rc_a err_a=$err_a"
fi

# N6 — gate ① regex covers letter-suffixed story numbers
echo "$ART/spec-124-4b-foo.md" | grep -qE "$TRIG" && pass "N6 gate ① letter suffix" || fail "N6" "regex=$TRIG"

# ============================================================================
# Codex adversarial review regressions (2026-10-27)
# ============================================================================

# C1 — retro_action_items: legacy scalar shape is invalid YAML; migrate → valid,
#      readers agree on both shapes, chore_spec fill writes after status
d="$(mktemp -d -t rai.XXXXXX)"
mkdir -p "$d/.claude/harness/scripts" "$d/$ART"
for f in sprint-status.py harness_config.py harness_spec.py grep_pending_dev_retro_items.sh \
         read_harness_config.sh deferred_work_schema_lib.sh harness-commit.py; do cp "$SCRIPT_DIR/$f" "$d/.claude/harness/scripts/"; done
printf '%s\n' 'development_status:' '  8-1-a: done' 'retro_action_items:' '  epic-8-retro:' \
    '    H1: pending      # legacy scalar' '      category: dev' \
    '    H2: pending' '      category: harness' \
    '    H3:' '      status: pending  # already nested' '      category: dev' > "$d/$ART/sprint-status.yaml"
legacy_ok="$(python3 -c "import yaml; yaml.safe_load(open('$d/$ART/sprint-status.yaml')); print('valid')" 2>/dev/null || echo invalid)"
before="$(cd "$d" && bash .claude/harness/scripts/grep_pending_dev_retro_items.sh 2>/dev/null | grep '^_PENDING_DEV_')"
chk="$(cd "$d" && python3 .claude/harness/scripts/sprint-status.py migrate-retro-items --check; echo "rc=$?")"
(cd "$d" && python3 .claude/harness/scripts/sprint-status.py migrate-retro-items >/dev/null)
after_ok="$(python3 -c "import yaml; d=yaml.safe_load(open('$d/$ART/sprint-status.yaml')); print(d['retro_action_items']['epic-8-retro']['H1'])" 2>&1)"
after="$(cd "$d" && bash .claude/harness/scripts/grep_pending_dev_retro_items.sh 2>/dev/null | grep '^_PENDING_DEV_')"
chk2="$(cd "$d" && python3 .claude/harness/scripts/sprint-status.py migrate-retro-items --check; echo "rc=$?")"
touch "$d/$ART/chore-retro-c8-H1-fix-thing.md"
(cd "$d" && python3 -c "
import importlib.util, sys
sys.path.insert(0, '.claude/harness/scripts')
spec = importlib.util.spec_from_file_location('hc', '.claude/harness/scripts/harness-commit.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m._fill_chore_spec_field('8', '$ART/sprint-status.yaml', '$ART')
" 2>/dev/null)
first_child="$(awk '/^    H1:/{getline; sub(/^ +/, ""); split($0, a, ":"); print a[1]; exit}' "$d/$ART/sprint-status.yaml")"
fill_ok="$(python3 -c "import yaml; d=yaml.safe_load(open('$d/$ART/sprint-status.yaml')); print(d['retro_action_items']['epic-8-retro']['H1'].get('chore_spec'))" 2>&1)"
rm -rf "$d"
if [ "$legacy_ok" = invalid ] && [ "$chk" = $'2\nrc=3' ] && [ "$chk2" = $'0\nrc=0' ] \
   && [ "$after_ok" = "{'status': 'pending', 'category': 'dev'}" ] \
   && [ "$before" = "_PENDING_DEV_:2" ] && [ "$after" = "_PENDING_DEV_:2" ] \
   && [ "$fill_ok" = chore-retro-c8-H1-fix-thing.md ] && [ "$first_child" = status ]; then
    pass "C1 retro_action_items migration + dual-shape readers + nested writers"
else
    fail "C1" "legacy=$legacy_ok chk=$chk chk2=$chk2 after=$after_ok before=$before after=$after fill=$fill_ok first=$first_child"
fi

# C2 — build-verify: nested artifacts are ownership-checked
dir="$(seed_repo)"
(
    cd "$dir" || exit 1
    write_spec "$dir" done '' ''
    mkdir -p "$ART/test_artifacts" "$ART/notes"
    echo '{}' > "$ART/test_artifacts/9-2-bar-test-result.json"
    echo x > "$ART/notes/spec-9-2-bar.md"
    echo '{}' > "$ART/test_artifacts/9-1-foo-test-result.json"
    echo y >> src/a.py
    git add -A; git commit -q -m feat
)
ex=0; out="$(cd "$dir" && python3 "$HC" build-verify 9-1-foo 2>&1)" || ex=$?
rm -rf "$dir"
if [ "$ex" = 1 ] && printf '%s' "$out" | grep -qx "CROSS_STORY=$ART/test_artifacts/9-2-bar-test-result.json" \
   && printf '%s' "$out" | grep -qx "UNEXPECTED_ARTIFACT=$ART/notes/spec-9-2-bar.md" \
   && ! printf '%s' "$out" | grep -q "test_artifacts/9-1-foo-test-result.json"; then
    pass "C2 nested artifact isolation in build-verify"
else
    fail "C2" "exit=$ex out=$out"
fi

# C3 — build-sync: failed deferred import leaves sprint-status untouched; an
#      uncommitted done / committed-but-untagged sync stays in flight
dir="$(seed_repo)"
(cd "$dir" || exit 1; write_spec "$dir" done $'deferred:\n  - summary: x' ''; echo y >> src/a.py; git rm -q "$ART/deferred-work.md"; git add -A; git commit -q -m feat)
ex=0; out="$(cd "$dir" && python3 "$HC" build-sync 9-1-foo 2>&1)" || ex=$?
st="$(cd "$dir" && python3 "$SS" status 9-1-foo 2>/dev/null)"
inf1="$(cd "$dir" && python3 "$HS" --in-flight 2>/dev/null)"
(cd "$dir" && python3 "$SS" set 9-1-foo done >/dev/null 2>&1)
inf2="$(cd "$dir" && python3 "$HS" --in-flight 2>/dev/null)"
(cd "$dir" && git add -A && git commit -q -m "story(9-1-foo): sync sprint status & deferred ledger")
inf3="$(cd "$dir" && python3 "$HS" --in-flight 2>/dev/null)"
c3="$(code_of "$dir" 9-1-foo)"
rm -rf "$dir"
if [ "$ex" = 1 ] && printf '%s' "$out" | grep -q "REASON=deferred import failed" && [ "$st" = backlog ] \
   && [ "$inf1" = 9-1-foo ] && [ "$inf2" = 9-1-foo ] && [ "$inf3" = 9-1-foo ] && [ "$c3" = tag-only ]; then
    pass "C3 build-sync interruption stays discoverable"
else
    fail "C3" "exit=$ex status=$st inf=[$inf1|$inf2|$inf3] code=$c3 out=$out"
fi

# C4 — pre-commit gate ①: retro_gate warn (default) lets the commit through, block rejects
gate_case() {  # $1 = retro_gate value ('' = unset); echoes hook rc
    local g; g="$(mktemp -d -t gate.XXXXXX)"
    (
        cd "$g" || exit 1
        git init -q; git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
        mkdir -p .claude/harness/scripts "$ART"
        for f in check_retro_action_items.sh read_harness_config.sh deferred_work_schema_lib.sh harness_config.py; do cp "$SCRIPT_DIR/$f" .claude/harness/scripts/; done
        [ -n "$1" ] && printf "retro_gate: '%s'\n" "$1" > .claude/harness/harness-project-config.yaml
        printf '%s\n' 'development_status:' '  9-1-foo: backlog' 'retro_action_items:' '  epic-8-retro:' \
            '    H1:' '      status: pending' '      category: dev' > "$ART/sprint-status.yaml"
        git add -A; git commit -q -m seed
        echo x > "$ART/spec-9-1-foo.md"; git add -A
        rc=0; bash "$SCRIPT_DIR/../git-hooks/pre-commit" >/dev/null 2>&1 || rc=$?
        echo "$rc"
    )
    rm -rf "$g"
}
r_unset="$(gate_case '')"; r_warn="$(gate_case warn)"; r_block="$(gate_case block)"
if [ "$r_unset" = 0 ] && [ "$r_warn" = 0 ] && [ "$r_block" = 1 ]; then
    pass "C4 retro_gate warn/block"
else
    fail "C4" "unset=$r_unset warn=$r_warn block=$r_block"
fi

echo ""
echo "build_pipeline_test: failed=$failed"
exit "$failed"

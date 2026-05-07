#!/usr/bin/env bash
# chore-harness-epic-4-orchestration-observations — self-test
#
# 17 fixtures across 4 task groups (T1=5 / T2=3 / T3=4 / T4=5):
#
#   T1 — sprint-status auto-sync + retro_action_items seed + chore_spec fill
#     T1.f1  stage 2 sync sets KEY=review (mock sprint-status.yaml)
#     T1.f2  stage 5 sync sets KEY=done (mock)
#     T1.f3  stage 6 seed with 5 D items (idempotent re-run = no change)
#     T1.f4  stage 6 seed when block exists with 2 D items, retro md has 5 → seeds D3..D5 only
#     T1.f5  stage 6-5 fill chore_spec for matching files
#     T1.f6  P0 fail-loud: section found + 0 items (no H3/table/bold) → RuntimeError
#     T1.f7  P1 Form 2 fallback: markdown table `| AI-N.M |` → code `<letter>-N-M` + WARN
#     T1.f8  P1 Form 3 fallback: bold inline `**A1**` / `**A1/A2/A3**` shared title + WARN
#     T1.f9  graceful skip: epic > 26 (letter=None) → WARN + return [] (v0.1.21 codex fix)
#
#   T2 — stage 5.5 commit message suffix unification
#     T2.f1  T4 STAGES commit_msg含 "(run-sprint stage 5.5)"
#     T2.f2  5-5 STAGES commit_msg含 "(run-sprint stage 5.5)"
#     T2.f3  run-test-sprint.md T4 commit message line含 "(run-sprint stage 5.5)"
#
#   T3 — harness-state.py --resume-prompt --stage 2 增强字段
#     T3.f1  worktree landing summary helper exposes "worktree 落地清单"
#     T3.f2  git diff --stat helper exposes "git diff --stat 摘要"
#     T3.f3  dev-result.json helper "**未写**" path
#     T3.f4  dev-result.json helper field overview path
#
#   T4 — halt-recovery-check 三态
#     T4.f1  stage 5 work-done-but-msg-lost (READY_TO_COMMIT)
#     T4.f2  stage 5 work-not-done (NEED_RESUME)
#     T4.f3  stage 5 partial齐 (INCONSISTENT)
#     T4.f4  unknown stage exit 1
#     T4.f5  stage 2 READY (md Status=review + dev-result.json)
#
# Mock-based: each fixture builds a tempdir + sprint-status.yaml stand-in,
# invokes the helper directly via Python or harness-state.py with a custom
# CWD where applicable. No real git runtime / network / sandbox required —
# matches D3 / C-codex-fixes / C-bootstrap fixture pattern.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
HARNESS_COMMIT="${SCRIPT_DIR}/harness-commit.py"
HARNESS_STATE="${SCRIPT_DIR}/harness-state.py"

GREEN=$'\033[32m'
RED=$'\033[31m'
RESET=$'\033[0m'

PASS=0
FAIL=0

pass() { echo "${GREEN}PASS${RESET}: $1"; PASS=$((PASS + 1)); }
fail() { echo "${RED}FAIL${RESET}: $1"; FAIL=$((FAIL + 1)); }

# ============================================================================
# T1 — sprint-status auto-sync + retro_action_items seed + chore_spec fill
# ============================================================================

echo ""
echo "=== T1 group (5 fixtures) — sprint-status auto-sync helpers ==="

# ----------------------------------------------------------------------------
# T1.f1 — _sync_sprint_status_for_stage stage 2 → review
# ----------------------------------------------------------------------------
TMP="$(mktemp -d)"
mkdir -p "${TMP}/_bmad-output/implementation-artifacts" "${TMP}/.claude/harness/scripts"
cp "${SCRIPT_DIR}/harness-commit.py" "${TMP}/.claude/harness/scripts/"
cp "${SCRIPT_DIR}/harness-state.py" "${TMP}/.claude/harness/scripts/"
cp "${SCRIPT_DIR}/sprint-status.py" "${TMP}/.claude/harness/scripts/"
cp "${SCRIPT_DIR}/harness_config.py" "${TMP}/.claude/harness/scripts/"
cp "${REPO_ROOT}/.claude/harness/harness-project-config.yaml" "${TMP}/.claude/harness/"
cat > "${TMP}/_bmad-output/implementation-artifacts/sprint-status.yaml" <<'YAML'
last_updated: 2026-05-04

development_status:
  4-1-foo: backlog
  4-2-foo: backlog

retro_action_items:
  epic-1-retro:
    A1: done

test_status: {}
YAML

OUT=$(cd "${TMP}" && python3 -c "
import sys
sys.path.insert(0, '.claude/harness/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('hc', '.claude/harness/scripts/harness-commit.py')
hc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hc)
applied = hc._sync_sprint_status_for_stage('2', '4-1-foo', None)
print('APPLIED', applied)
")
RC=$?
if [[ $RC -eq 0 ]] && grep -q "APPLIED \[('4-1-foo', 'review')\]" <<< "$OUT" && \
   grep -q "4-1-foo: review" "${TMP}/_bmad-output/implementation-artifacts/sprint-status.yaml"; then
    pass "T1.f1 — stage 2 sync set 4-1-foo=review"
else
    fail "T1.f1 — stage 2 sync (rc=$RC out=$OUT)"
fi
rm -rf "${TMP}"

# ----------------------------------------------------------------------------
# T1.f2 — _sync_sprint_status_for_stage stage 5 → done
# ----------------------------------------------------------------------------
TMP="$(mktemp -d)"
mkdir -p "${TMP}/_bmad-output/implementation-artifacts" "${TMP}/.claude/harness/scripts"
cp "${SCRIPT_DIR}/harness-commit.py" "${TMP}/.claude/harness/scripts/"
cp "${SCRIPT_DIR}/harness-state.py" "${TMP}/.claude/harness/scripts/"
cp "${SCRIPT_DIR}/sprint-status.py" "${TMP}/.claude/harness/scripts/"
cp "${SCRIPT_DIR}/harness_config.py" "${TMP}/.claude/harness/scripts/"
cp "${REPO_ROOT}/.claude/harness/harness-project-config.yaml" "${TMP}/.claude/harness/"
cat > "${TMP}/_bmad-output/implementation-artifacts/sprint-status.yaml" <<'YAML'
last_updated: 2026-05-04

development_status:
  4-1-foo: review

test_status: {}
YAML

OUT=$(cd "${TMP}" && python3 -c "
import sys
sys.path.insert(0, '.claude/harness/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('hc', '.claude/harness/scripts/harness-commit.py')
hc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hc)
applied = hc._sync_sprint_status_for_stage('5', '4-1-foo', None)
print('APPLIED', applied)
")
RC=$?
if [[ $RC -eq 0 ]] && grep -q "APPLIED \[('4-1-foo', 'done')\]" <<< "$OUT" && \
   grep -q "4-1-foo: done" "${TMP}/_bmad-output/implementation-artifacts/sprint-status.yaml"; then
    pass "T1.f2 — stage 5 sync set 4-1-foo=done"
else
    fail "T1.f2 — stage 5 sync (rc=$RC out=$OUT)"
fi
rm -rf "${TMP}"

# ----------------------------------------------------------------------------
# T1.f3 — _seed_retro_action_items: 5 D items, retro_action_items block 不存在 → create
#         然后 idempotent re-run no change
# ----------------------------------------------------------------------------
TMP="$(mktemp -d)"
mkdir -p "${TMP}/_bmad-output/implementation-artifacts" "${TMP}/.claude/harness/scripts"
cp "${SCRIPT_DIR}/harness-commit.py" "${TMP}/.claude/harness/scripts/"
cp "${SCRIPT_DIR}/sprint-status.py" "${TMP}/.claude/harness/scripts/"
cp "${SCRIPT_DIR}/harness_config.py" "${TMP}/.claude/harness/scripts/"
cp "${REPO_ROOT}/.claude/harness/harness-project-config.yaml" "${TMP}/.claude/harness/"
cat > "${TMP}/_bmad-output/implementation-artifacts/sprint-status.yaml" <<'YAML'
last_updated: 2026-05-04

development_status:
  4-1-foo: done

retro_action_items:
  epic-1-retro:
    A1: done

test_status: {}
YAML
cat > "${TMP}/_bmad-output/implementation-artifacts/epic-4-retro-2026-05-04.md" <<'MD'
# Epic 4 Retrospective

## 6. Action Items

### D1 — first thing
Action: foo
### D2 — second thing
Action: bar
### D3 — third thing
### D4 — fourth thing
### D5 — fifth thing
MD

OUT=$(cd "${TMP}" && python3 -c "
import sys
sys.path.insert(0, '.claude/harness/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('hc', '.claude/harness/scripts/harness-commit.py')
hc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hc)
seeded1 = hc._seed_retro_action_items('4', '_bmad-output/implementation-artifacts/epic-4-retro-2026-05-04.md', '_bmad-output/implementation-artifacts/sprint-status.yaml')
print('SEEDED1', len(seeded1), seeded1)
seeded2 = hc._seed_retro_action_items('4', '_bmad-output/implementation-artifacts/epic-4-retro-2026-05-04.md', '_bmad-output/implementation-artifacts/sprint-status.yaml')
print('SEEDED2', len(seeded2))
")
RC=$?
COUNT=$(grep -cE "^    D[0-9]+:" "${TMP}/_bmad-output/implementation-artifacts/sprint-status.yaml" || true)
if [[ $RC -eq 0 ]] && grep -q "SEEDED1 5" <<< "$OUT" && \
   grep -q "SEEDED2 0" <<< "$OUT" && \
   [[ "$COUNT" -eq 5 ]]; then
    pass "T1.f3 — stage 6 seed 5 D items + idempotent rerun = 0"
else
    fail "T1.f3 — seed creation+idempotent (rc=$RC count=$COUNT out=$OUT)"
fi
rm -rf "${TMP}"

# ----------------------------------------------------------------------------
# T1.f4 — _seed_retro_action_items: block exists with D1/D2, retro md has D1..D5 → 仅 seed D3..D5
# ----------------------------------------------------------------------------
TMP="$(mktemp -d)"
mkdir -p "${TMP}/_bmad-output/implementation-artifacts" "${TMP}/.claude/harness/scripts"
cp "${SCRIPT_DIR}/harness-commit.py" "${TMP}/.claude/harness/scripts/"
cp "${SCRIPT_DIR}/sprint-status.py" "${TMP}/.claude/harness/scripts/"
cp "${SCRIPT_DIR}/harness_config.py" "${TMP}/.claude/harness/scripts/"
cp "${REPO_ROOT}/.claude/harness/harness-project-config.yaml" "${TMP}/.claude/harness/"
cat > "${TMP}/_bmad-output/implementation-artifacts/sprint-status.yaml" <<'YAML'
last_updated: 2026-05-04

development_status:
  4-1-foo: done

retro_action_items:
  epic-4-retro:
    D1: pending
    D2: done
      chore_spec: 'chore-retro-c4-D2-already-here.md'

test_status: {}
YAML
cat > "${TMP}/_bmad-output/implementation-artifacts/epic-4-retro-2026-05-04.md" <<'MD'
# Epic 4 Retrospective

## 6. Action Items

### D1 — first
### D2 — second (already)
### D3 — third
### D4 — fourth
### D5 — fifth
MD

OUT=$(cd "${TMP}" && python3 -c "
import sys
sys.path.insert(0, '.claude/harness/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('hc', '.claude/harness/scripts/harness-commit.py')
hc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hc)
seeded = hc._seed_retro_action_items('4', '_bmad-output/implementation-artifacts/epic-4-retro-2026-05-04.md', '_bmad-output/implementation-artifacts/sprint-status.yaml')
print('SEEDED', [c for c, t in seeded])
")
RC=$?
# Check: D1 unchanged (pending), D2 unchanged (done + chore_spec preserved), D3/D4/D5 added (pending)
if [[ $RC -eq 0 ]] && \
   grep -q "SEEDED \['D3', 'D4', 'D5'\]" <<< "$OUT" && \
   grep -q "    D1: pending" "${TMP}/_bmad-output/implementation-artifacts/sprint-status.yaml" && \
   grep -q "    D2: done" "${TMP}/_bmad-output/implementation-artifacts/sprint-status.yaml" && \
   grep -q "chore_spec: 'chore-retro-c4-D2-already-here.md'" "${TMP}/_bmad-output/implementation-artifacts/sprint-status.yaml" && \
   grep -q "    D3: pending" "${TMP}/_bmad-output/implementation-artifacts/sprint-status.yaml" && \
   grep -q "    D5: pending" "${TMP}/_bmad-output/implementation-artifacts/sprint-status.yaml"; then
    pass "T1.f4 — partial seed (D1/D2 preserved, D3..D5 added)"
else
    fail "T1.f4 — partial seed (rc=$RC out=$OUT)"
    cat "${TMP}/_bmad-output/implementation-artifacts/sprint-status.yaml"
fi
rm -rf "${TMP}"

# ----------------------------------------------------------------------------
# T1.f5 — _fill_chore_spec_field: 3 chore files → fill 2 missing fields (1 already filled)
# ----------------------------------------------------------------------------
TMP="$(mktemp -d)"
mkdir -p "${TMP}/_bmad-output/implementation-artifacts" "${TMP}/.claude/harness/scripts"
cp "${SCRIPT_DIR}/harness-commit.py" "${TMP}/.claude/harness/scripts/"
cp "${SCRIPT_DIR}/sprint-status.py" "${TMP}/.claude/harness/scripts/"
cp "${SCRIPT_DIR}/harness_config.py" "${TMP}/.claude/harness/scripts/"
cp "${REPO_ROOT}/.claude/harness/harness-project-config.yaml" "${TMP}/.claude/harness/"
cat > "${TMP}/_bmad-output/implementation-artifacts/sprint-status.yaml" <<'YAML'
last_updated: 2026-05-04

development_status:
  4-1-foo: done

retro_action_items:
  epic-4-retro:
    D1: pending
    D2: pending
      chore_spec: 'chore-retro-c4-D2-already-filled.md'
    D3: pending

test_status: {}
YAML
touch "${TMP}/_bmad-output/implementation-artifacts/chore-retro-c4-D1-foo.md"
touch "${TMP}/_bmad-output/implementation-artifacts/chore-retro-c4-D2-already-filled.md"
touch "${TMP}/_bmad-output/implementation-artifacts/chore-retro-c4-D3-bar.md"

OUT=$(cd "${TMP}" && python3 -c "
import sys
sys.path.insert(0, '.claude/harness/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('hc', '.claude/harness/scripts/harness-commit.py')
hc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hc)
filled = hc._fill_chore_spec_field('4', '_bmad-output/implementation-artifacts/sprint-status.yaml', '_bmad-output/implementation-artifacts')
print('FILLED', filled)
")
RC=$?
COUNT=$(grep -cE "chore_spec:" "${TMP}/_bmad-output/implementation-artifacts/sprint-status.yaml" || true)
if [[ $RC -eq 0 ]] && \
   grep -qE "FILLED \[\('D1', '.+'\), \('D3', '.+'\)\]" <<< "$OUT" && \
   [[ "$COUNT" -eq 3 ]]; then
    pass "T1.f5 — fill 2 missing chore_spec (D2 preserved, D1+D3 added)"
else
    fail "T1.f5 — fill (rc=$RC chore_spec_count=$COUNT out=$OUT)"
    cat "${TMP}/_bmad-output/implementation-artifacts/sprint-status.yaml"
fi
rm -rf "${TMP}"

# ----------------------------------------------------------------------------
# T1.f6 — _parse_retro_action_items: section found + 0 H3/table/bold matches
#         → RuntimeError (P0 fail-loud, schema drift detection)
# ----------------------------------------------------------------------------
TMP="$(mktemp -d)"
mkdir -p "${TMP}/_bmad-output/implementation-artifacts" "${TMP}/.claude/harness/scripts"
cp "${SCRIPT_DIR}/harness-commit.py" "${TMP}/.claude/harness/scripts/"
cp "${SCRIPT_DIR}/sprint-status.py" "${TMP}/.claude/harness/scripts/"
cp "${SCRIPT_DIR}/harness_config.py" "${TMP}/.claude/harness/scripts/"
cp "${REPO_ROOT}/.claude/harness/harness-project-config.yaml" "${TMP}/.claude/harness/"
# retro md mimics BMad SKILL §8 default output (`**Process Improvements:**` +
# numbered list) which matches none of the 3 forms — must trigger fail-loud.
cat > "${TMP}/_bmad-output/implementation-artifacts/epic-4-retro-2026-05-04.md" <<'MD'
# Epic 4 Retrospective

## 6. Action Items

**Process Improvements:**

1. action item one
   Owner: solo-dev
2. action item two
   Owner: solo-dev

**Technical Debt:**

1. debt item one
MD

OUT=$(cd "${TMP}" && python3 -c "
import sys
sys.path.insert(0, '.claude/harness/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('hc', '.claude/harness/scripts/harness-commit.py')
hc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hc)
try:
    hc._parse_retro_action_items('_bmad-output/implementation-artifacts/epic-4-retro-2026-05-04.md', 'D')
    print('NO_RAISE')
except RuntimeError as e:
    msg = str(e)
    if 'schema drift' in msg.lower() and 'action items section' in msg.lower():
        print('RAISED_OK')
    else:
        print('RAISED_WRONG_MSG', msg)
" 2>&1)
RC=$?
if [[ $RC -eq 0 ]] && grep -q "RAISED_OK" <<< "$OUT"; then
    pass "T1.f6 — section found + 0 items raises RuntimeError (fail-loud)"
else
    fail "T1.f6 — fail-loud (rc=$RC out=$OUT)"
fi
rm -rf "${TMP}"

# ----------------------------------------------------------------------------
# T1.f7 — _parse_retro_action_items: Form 2 fallback (markdown table row
#         `| AI-N.M | title |`) — codes normalize to `<letter>-N-M`
# ----------------------------------------------------------------------------
TMP="$(mktemp -d)"
mkdir -p "${TMP}/_bmad-output/implementation-artifacts" "${TMP}/.claude/harness/scripts"
cp "${SCRIPT_DIR}/harness-commit.py" "${TMP}/.claude/harness/scripts/"
cp "${SCRIPT_DIR}/sprint-status.py" "${TMP}/.claude/harness/scripts/"
cp "${SCRIPT_DIR}/harness_config.py" "${TMP}/.claude/harness/scripts/"
cp "${REPO_ROOT}/.claude/harness/harness-project-config.yaml" "${TMP}/.claude/harness/"
cat > "${TMP}/_bmad-output/implementation-artifacts/epic-1-retro-2026-05-07.md" <<'MD'
# Epic 1 Retrospective

## 五、Action items（行动项）

### 5.1 流程改进类 action items

| ID | 行动 | Owner | 时机 | 验收 |
| --- | --- | --- | --- | --- |
| AI-1.1 | 流程改进项一 | solo-dev | 立即 | 标准 |
| AI-1.2 | 流程改进项二 | solo-dev | 立即 | 标准 |

### 5.2 技术债类 action items

| ID | 行动 | Owner | 时机 | 验收 |
| --- | --- | --- | --- | --- |
| AI-2.1 | 技术债项一 | solo-dev | epic 2 | 标准 |
MD

OUT=$(cd "${TMP}" && python3 -c "
import sys
sys.path.insert(0, '.claude/harness/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('hc', '.claude/harness/scripts/harness-commit.py')
hc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hc)
items = hc._parse_retro_action_items('_bmad-output/implementation-artifacts/epic-1-retro-2026-05-07.md', 'A')
print('ITEMS', [c for c, t in items])
print('TITLES', [t for c, t in items])
" 2>&1)
RC=$?
# Expect codes A-1-1, A-1-2, A-2-1 with their respective titles, plus stderr WARN
if [[ $RC -eq 0 ]] && \
   grep -q "ITEMS \['A-1-1', 'A-1-2', 'A-2-1'\]" <<< "$OUT" && \
   grep -q "Form 2 (markdown table" <<< "$OUT" && \
   grep -q "流程改进项一" <<< "$OUT"; then
    pass "T1.f7 — Form 2 markdown table fallback (3 items normalized to A-N-M, WARN emitted)"
else
    fail "T1.f7 — table fallback (rc=$RC out=$OUT)"
fi
rm -rf "${TMP}"

# ----------------------------------------------------------------------------
# T1.f8 — _parse_retro_action_items: Form 3 fallback (bold inline
#         `**A1**` / `**A1/A2/A3**` shared title)
# ----------------------------------------------------------------------------
TMP="$(mktemp -d)"
mkdir -p "${TMP}/_bmad-output/implementation-artifacts" "${TMP}/.claude/harness/scripts"
cp "${SCRIPT_DIR}/harness-commit.py" "${TMP}/.claude/harness/scripts/"
cp "${SCRIPT_DIR}/sprint-status.py" "${TMP}/.claude/harness/scripts/"
cp "${SCRIPT_DIR}/harness_config.py" "${TMP}/.claude/harness/scripts/"
cp "${REPO_ROOT}/.claude/harness/harness-project-config.yaml" "${TMP}/.claude/harness/"
cat > "${TMP}/_bmad-output/implementation-artifacts/epic-1-retro-2026-05-07.md" <<'MD'
# Epic 1 Retrospective

## 五、Action items（行动项）

自我约束：

- **A1** 不再混用 docker-compose v1 / v2 命令
- **A2/A3** 必须先跑 lint 再 commit
MD

OUT=$(cd "${TMP}" && python3 -c "
import sys
sys.path.insert(0, '.claude/harness/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('hc', '.claude/harness/scripts/harness-commit.py')
hc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hc)
items = hc._parse_retro_action_items('_bmad-output/implementation-artifacts/epic-1-retro-2026-05-07.md', 'A')
print('ITEMS', [c for c, t in items])
" 2>&1)
RC=$?
# Expect A1 (single bold) + A2 + A3 (split from `**A2/A3**` shared title), WARN emitted
if [[ $RC -eq 0 ]] && \
   grep -q "ITEMS \['A1', 'A2', 'A3'\]" <<< "$OUT" && \
   grep -q "Form 3 (bold inline" <<< "$OUT"; then
    pass "T1.f8 — Form 3 bold inline fallback (single + slash-grouped split, WARN emitted)"
else
    fail "T1.f8 — bold fallback (rc=$RC out=$OUT)"
fi
rm -rf "${TMP}"

# ----------------------------------------------------------------------------
# T1.f9 — _seed_retro_action_items: epic > 26 → letter=None → WARN + return []
#         (v0.1.21 codex review fix #3 — 区分 plugin range 限制 vs schema
#          drift；前者 graceful skip，不再 raise hard-halt stage 6 commit。
#          原 0.1.17 raise 行为已改成 WARN + return []。)
# ----------------------------------------------------------------------------
TMP="$(mktemp -d)"
mkdir -p "${TMP}/_bmad-output/implementation-artifacts" "${TMP}/.claude/harness/scripts"
cp "${SCRIPT_DIR}/harness-commit.py" "${TMP}/.claude/harness/scripts/"
cp "${SCRIPT_DIR}/sprint-status.py" "${TMP}/.claude/harness/scripts/"
cp "${SCRIPT_DIR}/harness_config.py" "${TMP}/.claude/harness/scripts/"
cp "${REPO_ROOT}/.claude/harness/harness-project-config.yaml" "${TMP}/.claude/harness/"
cat > "${TMP}/_bmad-output/implementation-artifacts/sprint-status.yaml" <<'YAML'
last_updated: 2026-05-04

retro_action_items:
  epic-1-retro:
    A1: done

test_status: {}
YAML
# 准备一个 dummy epic-27 retro md 含 Action Items section（验证不会因为
# section-found+0-items 触发 schema-drift raise — 我们要的是 letter=None 路径）
cat > "${TMP}/_bmad-output/implementation-artifacts/epic-27-retro-2026-05-04.md" <<'MD'
# Epic 27 Retrospective
MD

# 抓 stderr 验证 WARN
F9_STDERR="${TMP}/f9-stderr.txt"
OUT=$(cd "${TMP}" && python3 -c "
import sys
sys.path.insert(0, '.claude/harness/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('hc', '.claude/harness/scripts/harness-commit.py')
hc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hc)
try:
    result = hc._seed_retro_action_items('27', '_bmad-output/implementation-artifacts/epic-27-retro-2026-05-04.md', '_bmad-output/implementation-artifacts/sprint-status.yaml')
    if result == []:
        print('OK_RETURNED_EMPTY')
    else:
        print('UNEXPECTED_RESULT', result)
except RuntimeError as e:
    print('UNEXPECTED_RAISE', str(e))
" 2>"$F9_STDERR")
RC=$?
STDERR_CONTENT="$(cat "$F9_STDERR" 2>/dev/null)"
if [[ $RC -eq 0 ]] && grep -q "OK_RETURNED_EMPTY" <<< "$OUT" && \
   grep -q "WARN.*epic.*'27'" <<< "$STDERR_CONTENT" && \
   grep -q "1\\.\\.26" <<< "$STDERR_CONTENT"; then
    pass "T1.f9 — epic > 26 (letter=None) WARN + return [] (codex fix #3)"
else
    fail "T1.f9 — letter=None graceful skip (rc=$RC out=$OUT stderr=$STDERR_CONTENT)"
fi
rm -rf "${TMP}"

# ============================================================================
# T2 — stage 5.5 commit message suffix unification
# ============================================================================

echo ""
echo "=== T2 group (3 fixtures) — stage 5.5 commit message suffix ==="

if grep -q '"commit_msg":\s*"test({key}): atdd + e2e (run-sprint stage 5.5)"' "${SCRIPT_DIR}/harness-commit.py"; then
    : # We'll count both 5-5 and T4 below
fi

# T2.f1 — T4 stage commit_msg has suffix
T4_MATCH=$(awk '/"T4":/,/^    \}/' "${SCRIPT_DIR}/harness-commit.py" | grep -c 'atdd + e2e (run-sprint stage 5.5)' || true)
if [[ "$T4_MATCH" -ge 1 ]]; then
    pass "T2.f1 — T4 STAGES.commit_msg 含 \"(run-sprint stage 5.5)\""
else
    fail "T2.f1 — T4 commit_msg suffix missing"
fi

# T2.f2 — 5-5 stage commit_msg has suffix
F55_MATCH=$(awk '/"5-5":/,/^    \}/' "${SCRIPT_DIR}/harness-commit.py" | grep -c 'atdd + e2e (run-sprint stage 5.5)' || true)
if [[ "$F55_MATCH" -ge 1 ]]; then
    pass "T2.f2 — 5-5 STAGES.commit_msg 含 \"(run-sprint stage 5.5)\""
else
    fail "T2.f2 — 5-5 commit_msg suffix missing"
fi

# T2.f3 — run-test-sprint.md T4 row in expected-output table has suffix
RTS_TABLE_MATCH=$(grep -c "atdd + e2e (run-sprint stage 5.5)" "${REPO_ROOT}/.claude/commands/run-test.md" || true)
if [[ "$RTS_TABLE_MATCH" -ge 1 ]]; then
    pass "T2.f3 — run-test-sprint.md 含 \"(run-sprint stage 5.5)\" 后缀"
else
    fail "T2.f3 — run-test-sprint.md suffix missing"
fi

# ============================================================================
# T3 — harness-state.py --resume-prompt --stage 2 enhanced fields
# ============================================================================

echo ""
echo "=== T3 group (4 fixtures) — resume-prompt stage 2 enhancements ==="

# T3.f1 — _format_worktree_landing_summary helper exposes "worktree 落地清单"
OUT=$(python3 -c "
import sys
sys.path.insert(0, '.claude/harness/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('hs', '.claude/harness/scripts/harness-state.py')
hs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hs)
print(hs._format_worktree_landing_summary())
" 2>&1)
if grep -q "worktree 落地清单" <<< "$OUT"; then
    pass "T3.f1 — _format_worktree_landing_summary 输出含 'worktree 落地清单'"
else
    fail "T3.f1 — worktree landing summary helper missing label (out=$OUT)"
fi

# T3.f2 — _format_git_diff_stat_summary helper exposes "git diff --stat 摘要"
OUT=$(python3 -c "
import sys
sys.path.insert(0, '.claude/harness/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('hs', '.claude/harness/scripts/harness-state.py')
hs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hs)
print(hs._format_git_diff_stat_summary())
" 2>&1)
if grep -q "git diff --stat 摘要" <<< "$OUT"; then
    pass "T3.f2 — _format_git_diff_stat_summary 输出含 'git diff --stat 摘要'"
else
    fail "T3.f2 — git diff stat helper missing label (out=$OUT)"
fi

# T3.f3 — _format_dev_result_summary 处理缺失文件路径输出 "**未写**"
TMP="$(mktemp -d)"
mkdir -p "${TMP}/_bmad-output/implementation-artifacts"
OUT=$(cd "${TMP}" && python3 -c "
import sys
sys.path.insert(0, '${SCRIPT_DIR}')
import importlib.util
spec = importlib.util.spec_from_file_location('hs', '${SCRIPT_DIR}/harness-state.py')
hs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hs)
print(hs._format_dev_result_summary('nonexistent-key'))
" 2>&1)
if grep -q "未写" <<< "$OUT" && grep -q "机器可读完成门必交付" <<< "$OUT"; then
    pass "T3.f3 — dev-result.json 缺失 → '**未写**' 标记"
else
    fail "T3.f3 — dev-result missing-file path (out=$OUT)"
fi
rm -rf "${TMP}"

# T3.f4 — _format_dev_result_summary 字段一览（已写）
TMP="$(mktemp -d)"
mkdir -p "${TMP}/_bmad-output/implementation-artifacts"
cat > "${TMP}/_bmad-output/implementation-artifacts/4-fixture-test.dev-result.json" <<'JSON'
{"story_key": "4-fixture-test", "checks": {"tests": "pass", "lint": "skip"}, "files_changed_count": 18, "final_story_status": "review"}
JSON
OUT=$(cd "${TMP}" && python3 -c "
import sys
sys.path.insert(0, '${SCRIPT_DIR}')
import importlib.util
spec = importlib.util.spec_from_file_location('hs', '${SCRIPT_DIR}/harness-state.py')
hs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hs)
print(hs._format_dev_result_summary('4-fixture-test'))
" 2>&1)
if grep -q "已写，字段一览" <<< "$OUT" && grep -q "files_changed_count: 18" <<< "$OUT" && \
   grep -q "final_story_status:" <<< "$OUT"; then
    pass "T3.f4 — dev-result.json 字段一览（checks / files_changed_count / final_story_status）"
else
    fail "T3.f4 — dev-result field overview (out=$OUT)"
fi
rm -rf "${TMP}"

# ============================================================================
# T4 — halt-recovery-check 三态
# ============================================================================

echo ""
echo "=== T4 group (5 fixtures) — halt-recovery-check 3 verdict ==="

# T4.f1 — stage 5 work-done-but-msg-lost (READY_TO_COMMIT)
TMP="$(mktemp -d)"
mkdir -p "${TMP}/_bmad-output/implementation-artifacts"
cat > "${TMP}/_bmad-output/implementation-artifacts/4-1-fix.md" <<'MD'
# 4-1 fix story

Status: done

## Tasks
- [x] something
MD
echo '{"unresolved": {"critical": 0, "high": 0, "medium": 0, "low": 0}, "final_story_status": "done"}' \
    > "${TMP}/_bmad-output/implementation-artifacts/4-1-fix.review-findings.json"
echo '{"phase": "done", "findings": {}}' \
    > "${TMP}/_bmad-output/implementation-artifacts/4-1-fix.review-progress.json"
OUT=$(cd "${TMP}" && python3 "${HARNESS_STATE}" 4-1-fix --halt-recovery-check --stage 5 2>&1)
RC=$?
FIRST_LINE=$(echo "$OUT" | head -1)
if [[ $RC -eq 0 ]] && [[ "$FIRST_LINE" == "READY_TO_COMMIT" ]]; then
    pass "T4.f1 — stage 5 work-done-but-msg-lost → READY_TO_COMMIT"
else
    fail "T4.f1 — stage 5 READY (rc=$RC first=$FIRST_LINE)"
    echo "--- output ---"; echo "$OUT"
fi
rm -rf "${TMP}"

# T4.f2 — stage 5 work-not-done (NEED_RESUME)
TMP="$(mktemp -d)"
mkdir -p "${TMP}/_bmad-output/implementation-artifacts"
# 没有 review-findings.json，story md Status=review (stage 2 done)
cat > "${TMP}/_bmad-output/implementation-artifacts/4-2-fix.md" <<'MD'
# 4-2 fix story

Status: review

## Tasks
- [ ] not yet done
MD
OUT=$(cd "${TMP}" && python3 "${HARNESS_STATE}" 4-2-fix --halt-recovery-check --stage 5 2>&1)
RC=$?
FIRST_LINE=$(echo "$OUT" | head -1)
if [[ $RC -eq 0 ]] && [[ "$FIRST_LINE" == "NEED_RESUME" ]]; then
    pass "T4.f2 — stage 5 work-not-done → NEED_RESUME"
else
    fail "T4.f2 — stage 5 NEED_RESUME (rc=$RC first=$FIRST_LINE)"
    echo "--- output ---"; echo "$OUT"
fi
rm -rf "${TMP}"

# T4.f3 — stage 5 partial齐 (INCONSISTENT — review-progress 在但 findings 缺)
TMP="$(mktemp -d)"
mkdir -p "${TMP}/_bmad-output/implementation-artifacts"
cat > "${TMP}/_bmad-output/implementation-artifacts/4-3-fix.md" <<'MD'
# 4-3 fix story

Status: review

## Tasks
- [x] partial done
MD
echo '{"phase": "patching", "findings": {"F1": {"status": "patched"}}}' \
    > "${TMP}/_bmad-output/implementation-artifacts/4-3-fix.review-progress.json"
OUT=$(cd "${TMP}" && python3 "${HARNESS_STATE}" 4-3-fix --halt-recovery-check --stage 5 2>&1)
RC=$?
FIRST_LINE=$(echo "$OUT" | head -1)
if [[ $RC -eq 0 ]] && [[ "$FIRST_LINE" == "INCONSISTENT" ]]; then
    pass "T4.f3 — stage 5 partial齐 → INCONSISTENT"
else
    fail "T4.f3 — stage 5 INCONSISTENT (rc=$RC first=$FIRST_LINE)"
    echo "--- output ---"; echo "$OUT"
fi
rm -rf "${TMP}"

# T4.f4 — unknown stage exit 1
OUT=$(python3 "${HARNESS_STATE}" 4-4-fix --halt-recovery-check --stage 6 2>&1)
RC=$?
# stage 6 not in HALT_RECOVERY_SPECS → unknown stage exit 1
if [[ $RC -eq 1 ]] && grep -q "unknown stage" <<< "$OUT"; then
    pass "T4.f4 — unknown stage 6 → exit 1 + 'unknown stage'"
else
    fail "T4.f4 — unknown stage (rc=$RC out=$OUT)"
fi

# T4.f5 — stage 2 READY (md Status=review + dev-result.json)
TMP="$(mktemp -d)"
mkdir -p "${TMP}/_bmad-output/implementation-artifacts"
cat > "${TMP}/_bmad-output/implementation-artifacts/4-5-fix.md" <<'MD'
# 4-5 fix story

Status: review

## Tasks
- [x] done
MD
echo '{"checks": {"tests": "pass"}, "final_story_status": "review"}' \
    > "${TMP}/_bmad-output/implementation-artifacts/4-5-fix.dev-result.json"
OUT=$(cd "${TMP}" && python3 "${HARNESS_STATE}" 4-5-fix --halt-recovery-check --stage 2 2>&1)
RC=$?
FIRST_LINE=$(echo "$OUT" | head -1)
if [[ $RC -eq 0 ]] && [[ "$FIRST_LINE" == "READY_TO_COMMIT" ]]; then
    pass "T4.f5 — stage 2 READY (md Status=review + dev-result.json)"
else
    fail "T4.f5 — stage 2 READY (rc=$RC first=$FIRST_LINE)"
    echo "--- output ---"; echo "$OUT"
fi
rm -rf "${TMP}"

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "=== Summary ==="
echo "PASS: $PASS  FAIL: $FAIL"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0

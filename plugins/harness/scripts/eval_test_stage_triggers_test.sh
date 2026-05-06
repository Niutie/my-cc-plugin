#!/usr/bin/env bash
# Self-test for eval_test_stage_triggers.sh
#
# 9 fixture 覆盖：7 skill 触发条件命中 / yaml 损坏 fail-open / project config 缺失 fallback
# 每条 fixture 写入 mktemp 临时文件，驱动 eval 脚本，断言 JSON 字段满足预期。
# 整脚本退出码 = 失败 fixture 数（0 = 全过）。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_SH="${SCRIPT_DIR}/eval_test_stage_triggers.sh"

if [ ! -f "$EVAL_SH" ]; then
    echo "ERROR: eval_test_stage_triggers.sh not found at $EVAL_SH" >&2
    exit 1
fi

PASS=0
FAIL=0

# ---- helpers ----
assert_field() {
    # $1 = json blob, $2 = field name, $3 = expected value
    local json="$1"
    local field="$2"
    local expected="$3"
    local actual
    actual="$(printf '%s' "$json" | sed -nE "s/.*\"${field}\":[[:space:]]*([a-zA-Z_]+).*/\1/p" | head -1 | tr -d ',')"
    if [ "$actual" = "$expected" ]; then
        return 0
    else
        echo "  FAIL: field $field expected=$expected actual=$actual" >&2
        echo "    json: $json" >&2
        return 1
    fi
}

run_fixture() {
    local label="$1"; shift
    local result="$1"  # "PASS" or "FAIL" describes test outcome
    if [ "$result" = "PASS" ]; then
        echo "  ✓ $label"
        PASS=$((PASS+1))
    else
        echo "  ✗ $label"
        FAIL=$((FAIL+1))
    fi
}

# ---- 临时工作区（含 yaml + spec fixture） ----
WORKDIR="$(mktemp -d -t eval_triggers_test.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

# 写 minimal valid trigger yaml + project config（共用 fixture base）
cat > "$WORKDIR/triggers-base.yaml" <<'YAML'
defaults:
  fallback_skills:
    test-design: true
    framework: false
    atdd: true
    automate: true
    nfr: false
    trace: false
    ci: false
    test-review: false
    teach: false

skills:

  test-design:
    stage: T1
    trigger: once_per_project
    conditions:
      target_artifact: '${artifacts_root}/test_artifacts/epic-${EPIC}-test-design.md'

  framework:
    stage: T2
    trigger: once_per_project
    conditions:
      target_artifact: '${frontend_dir}/node_modules/@playwright/test'

  atdd:
    stage: T3
    trigger: per_story
    conditions:
      target_artifact: '${artifacts_root}/test_artifacts/${KEY}.atdd-checklist.md'

  automate:
    stage: T4
    trigger: per_story
    conditions:
      target_artifact: '${artifacts_root}/test_artifacts/${KEY}-test-result.json'

  nfr:
    stage: T5
    trigger: keyword_match
    conditions:
      keywords:
        - performance
        - load
        - security
        - NFR
        - benchmark

  trace:
    stage: T6
    trigger: keyword_match
    conditions:
      keywords:
        - compliance
        - audit
        - regulatory

  ci:
    stage: T-ci
    trigger: any_match
    conditions:
      first_e2e_spec_pattern: '${frontend_dir}/${e2e_test_subdir}/*.spec.ts'

  test-review:
    stage: T-review
    trigger: threshold
    conditions:
      e2e_spec_count_threshold: 50

  teach:
    stage: T-teach
    trigger: manual_only
    conditions: {}
YAML

cat > "$WORKDIR/project-config.yaml" <<'YAML'
project_display_name: 'Test Project'
container_orchestrator: 'docker-compose'
frontend_framework: 'Next.js'
backend_languages:
  - 'Go'
e2e_framework: 'Playwright'

extra:
  frontend_dir: 'console-web'
  e2e_test_subdir: 'tests/e2e'
YAML

# ---- Fixture 1: per_story (T3+T4) 触发 — 任意非空 KEY ----
echo "Fixture 1: per_story (atdd/automate) 触发"
SPEC1="$WORKDIR/spec1.md"
echo "# Plain story content without trigger keywords" > "$SPEC1"
JSON1="$(TRIGGERS_YAML="$WORKDIR/triggers-base.yaml" PROJECT_CONFIG="$WORKDIR/project-config.yaml" \
    bash "$EVAL_SH" 1-2-foo "$SPEC1" 2>/dev/null)"
if assert_field "$JSON1" t3 true && assert_field "$JSON1" t4 true && assert_field "$JSON1" t5 false; then
    run_fixture "per_story triggers t3/t4 + plain spec leaves t5=false" PASS
else
    run_fixture "per_story triggers t3/t4 + plain spec leaves t5=false" FAIL
fi

# ---- Fixture 2: NFR keyword_match 触发 ----
echo "Fixture 2: NFR keyword_match 触发"
SPEC2="$WORKDIR/spec2.md"
cat > "$SPEC2" <<EOF
# Story about performance benchmarks
We need to measure throughput and load.
EOF
JSON2="$(TRIGGERS_YAML="$WORKDIR/triggers-base.yaml" PROJECT_CONFIG="$WORKDIR/project-config.yaml" \
    bash "$EVAL_SH" 5-1-perf "$SPEC2" 2>/dev/null)"
if assert_field "$JSON2" t5 true; then
    run_fixture "NFR keyword 'performance' triggers t5=true" PASS
else
    run_fixture "NFR keyword 'performance' triggers t5=true" FAIL
fi

# ---- Fixture 3: trace keyword_match 触发 ----
echo "Fixture 3: trace keyword_match (compliance) 触发"
SPEC3="$WORKDIR/spec3.md"
cat > "$SPEC3" <<EOF
# Compliance story
Implements regulatory audit gate
EOF
JSON3="$(TRIGGERS_YAML="$WORKDIR/triggers-base.yaml" PROJECT_CONFIG="$WORKDIR/project-config.yaml" \
    bash "$EVAL_SH" 6-1-comp "$SPEC3" 2>/dev/null)"
if assert_field "$JSON3" t6 true; then
    run_fixture "trace keyword 'compliance' triggers t6=true" PASS
else
    run_fixture "trace keyword 'compliance' triggers t6=true" FAIL
fi

# ---- Fixture 4: T1 once_per_project — EPIC 提取（数字打头） ----
# 用 epic=99 避免与仓库已有 epic-{1..6}-test-design.md 撞
echo "Fixture 4: T1 once_per_project — 数字打头 KEY 提取 epic（产物缺）"
JSON4="$(TRIGGERS_YAML="$WORKDIR/triggers-base.yaml" PROJECT_CONFIG="$WORKDIR/project-config.yaml" \
    bash "$EVAL_SH" 99-1-detection "$SPEC1" 2>/dev/null)"
if assert_field "$JSON4" t1 true; then
    run_fixture "数字打头 KEY (epic=99) → t1=true（产物缺）" PASS
else
    run_fixture "数字打头 KEY (epic=99) → t1=true（产物缺）" FAIL
fi

# ---- Fixture 5: T1 once_per_project — chore-retro-cN 提取 ----
echo "Fixture 5: T1 once_per_project — chore-retro-c98 提取 epic=98（产物缺）"
JSON5="$(TRIGGERS_YAML="$WORKDIR/triggers-base.yaml" PROJECT_CONFIG="$WORKDIR/project-config.yaml" \
    bash "$EVAL_SH" chore-retro-c98-B5 "$SPEC1" 2>/dev/null)"
if assert_field "$JSON5" t1 true; then
    run_fixture "chore-retro-c98-B5 → epic=98 → t1=true（产物缺）" PASS
else
    run_fixture "chore-retro-c98-B5 → epic=98 → t1=true（产物缺）" FAIL
fi

# ---- Fixture 6: teach manual_only 永远 false ----
echo "Fixture 6: teach manual_only 永远 false"
JSON6="$JSON1"  # reuse fixture-1 result
if assert_field "$JSON6" teach false; then
    run_fixture "teach manual_only → 永远 false" PASS
else
    run_fixture "teach manual_only → 永远 false" FAIL
fi

# ---- Fixture 7: test-review threshold（< 50 spec → false） ----
echo "Fixture 7: test-review threshold < 50 → false"
if assert_field "$JSON1" test_review false; then
    run_fixture "test-review threshold 不到 50 → false" PASS
else
    run_fixture "test-review threshold 不到 50 → false" FAIL
fi

# ---- Fixture 8: yaml 损坏 fail-open ----
echo "Fixture 8: yaml 损坏 → fail_open_default"
BAD_YAML="$WORKDIR/bad-triggers.yaml"
cat > "$BAD_YAML" <<EOF
this is not valid yaml :: just garbage [[[[[[[
random text without skills section at all
EOF
JSON8="$(TRIGGERS_YAML="$BAD_YAML" PROJECT_CONFIG="$WORKDIR/project-config.yaml" \
    bash "$EVAL_SH" 1-1-foo "$SPEC1" 2>/dev/null)"
if printf '%s' "$JSON8" | grep -q '"reason": "fail_open_default"'; then
    run_fixture "yaml 损坏 → fail_open_default reason" PASS
else
    echo "  json was: $JSON8" >&2
    run_fixture "yaml 损坏 → fail_open_default reason" FAIL
fi

# ---- Fixture 9: project config 缺失 → 占位 fallback + WARN（不 abort） ----
echo "Fixture 9: project config 缺失 → 占位 fallback"
JSON9="$(TRIGGERS_YAML="$WORKDIR/triggers-base.yaml" PROJECT_CONFIG="$WORKDIR/nonexistent-config.yaml" \
    bash "$EVAL_SH" 1-1-foo "$SPEC1" 2>/dev/null)"
# 仍应正常输出 real_eval（fail-open 用 default 占位）
if printf '%s' "$JSON9" | grep -qE '"reason": "(real_eval|fail_open_default)"'; then
    run_fixture "project config 缺失 → 仍输出 JSON（不 abort）" PASS
else
    echo "  json was: $JSON9" >&2
    run_fixture "project config 缺失 → 仍输出 JSON（不 abort）" FAIL
fi

# ---- summary ----
echo ""
echo "================================"
echo " self-test: PASS=$PASS  FAIL=$FAIL"
echo "================================"
if [ "$FAIL" -eq 0 ]; then
    echo "All 9 fixtures pass ✓"
    exit 0
else
    echo "$FAIL fixture(s) failed ✗"
    exit "$FAIL"
fi

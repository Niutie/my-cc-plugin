#!/usr/bin/env bash
# Self-test for harness_config.py + read_harness_config.sh.
#
# review 2026-06-10 #94：
#   - 顶层 RETURN trap 永不触发（只对函数返回/被 source 文件生效）→ 全部
#     fixture 收进单一 mktemp WORKDIR + EXIT trap，零泄漏
#   - PY_HELPER/SH_HELPER 改 $SCRIPT_DIR 同目录源文件（此前指向部署副本
#     $REPO_ROOT/.claude/harness/scripts/，源树/CI 跑不了）
#   - F1 不再断言 live 项目 config（'11 entries' 魔数绑定真实项目内容）；
#     改为 fixture 写死的完整 config，全 4 fixture 自包含
#   - 新增 get_frontend_dir / get_e2e_test_subdir 断言（Phase A finding #9
#     新 getter：显式值 + 缺省 fallback 两路）
#
# 4 fixtures × (Python + bash)：
#   1. 完整 yaml（全字段填满）       → 全字段读出 + 0 WARN
#   2. 缺字段 (artifacts_root unset) → fallback to default + WARN；
#      frontend_dir/e2e_test_subdir 静默 fallback（console-web / tests/e2e）
#   3. yaml 文件缺失                  → fallback to default + WARN
#   4. yaml 含自定义 artifacts_root   → 真用新值

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_HELPER="$SCRIPT_DIR/harness_config.py"
SH_HELPER="$SCRIPT_DIR/read_harness_config.sh"

if [ ! -f "$PY_HELPER" ] || [ ! -f "$SH_HELPER" ]; then
    echo "ERROR: helpers not found next to test: $PY_HELPER / $SH_HELPER" >&2
    exit 1
fi

# Single sandbox for ALL fixtures; EXIT trap (NOT RETURN — review #94).
WORKDIR="$(mktemp -d -t harness_config_test.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local fixture_name="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        echo "    ✓ $fixture_name: contains '$needle'"
        PASS=$((PASS + 1))
    else
        echo "    ✗ $fixture_name: missing '$needle'" >&2
        echo "      haystack:" >&2
        printf '%s\n' "$haystack" | head -10 | sed 's/^/        /' >&2
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local fixture_name="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        echo "    ✗ $fixture_name: should NOT contain '$needle'" >&2
        printf '%s\n' "$haystack" | head -10 | sed 's/^/        /' >&2
        FAIL=$((FAIL + 1))
    else
        echo "    ✓ $fixture_name: 0 occurrences of '$needle'"
        PASS=$((PASS + 1))
    fi
}

# make_helper_dir <fixture-root> — copies both helpers into the deployed-style
# layout (<root>/.claude/harness/scripts/) so harness_config.py's
# `parents[1]/harness-project-config.yaml` default resolution points inside
# the fixture. Echoes the scripts dir.
make_helper_dir() {
    local root="$1"
    local sdir="$root/.claude/harness/scripts"
    mkdir -p "$sdir"
    cp "$PY_HELPER" "$sdir/harness_config.py"
    cp "$SH_HELPER" "$sdir/read_harness_config.sh"
    echo "$sdir"
}

# Fixture 1: 完整 yaml — 全 smoke 字段填满 → 全部读出 + 0 WARN
echo "=== Fixture 1: 完整 yaml（自包含 fixture，全字段填满） ==="
TMP_F1="$WORKDIR/f1"
F1_HELPER_DIR="$(make_helper_dir "$TMP_F1")"
cat > "$TMP_F1/.claude/harness/harness-project-config.yaml" <<'YAML'
project_display_name: 'Fixture 1'
container_orchestrator: 'docker-compose'
frontend_framework: 'Next.js'
backend_languages:
  - 'TypeScript'
e2e_framework: 'Playwright'
artifacts_root: '_bmad-output/implementation-artifacts'

extra:
  frontend_dir: 'webapp'
  e2e_test_subdir: 'e2e/specs'
  path_classifiers:
    - label: 'backend source'
      regex: '^api/'
    - label: 'frontend source'
      regex: '^webapp/src/'
  verification_commands: |
    go vet ./api/...
    pnpm --filter webapp test
  project_context: |
    fixture-1 项目语境占位
  fullstack_review_steps:
    - label: 'a'
      file_path: 'api/internal/audit/fields.go'
YAML

F1_PY="$(python3 "$F1_HELPER_DIR/harness_config.py" 2>&1)"
assert_contains "$F1_PY" "_bmad-output/implementation-artifacts" "F1.py"
assert_contains "$F1_PY" "path_classifiers: 2 entries" "F1.py"
assert_contains "$F1_PY" "go vet ./api/..." "F1.py"
assert_contains "$F1_PY" "fullstack_review_steps: 1 entries" "F1.py"
# Phase A 新 getter（finding #9）：显式配置值读出
assert_contains "$F1_PY" "frontend_dir: webapp" "F1.py"
assert_contains "$F1_PY" "e2e_test_subdir: e2e/specs" "F1.py"
assert_not_contains "$F1_PY" "WARN" "F1.py"

F1_SH="$(bash -c "source '$F1_HELPER_DIR/read_harness_config.sh' && echo \"ART=\$HARNESS_ARTIFACTS_ROOT\" && echo \"FD=\$(read_harness_config_field frontend_dir console-web)\"" 2>&1)"
assert_contains "$F1_SH" "_bmad-output/implementation-artifacts" "F1.sh"
assert_contains "$F1_SH" "FD=webapp" "F1.sh"
assert_not_contains "$F1_SH" "WARN" "F1.sh"

# Fixture 2: yaml with artifacts_root field removed
echo ""
echo "=== Fixture 2: missing artifacts_root field ==="
TMP_F2="$WORKDIR/f2"
F2_HELPER_DIR="$(make_helper_dir "$TMP_F2")"
cat > "$TMP_F2/.claude/harness/harness-project-config.yaml" <<'YAML'
project_display_name: 'Fixture 2'
container_orchestrator: 'docker-compose'
frontend_framework: 'Next.js'
backend_languages:
  - 'TypeScript'
e2e_framework: 'Playwright'
extra:
  container_count: 3
YAML

F2_PY="$(python3 "$F2_HELPER_DIR/harness_config.py" 2>&1)"
assert_contains "$F2_PY" "WARN [harness_config]: artifacts_root not set" "F2.py"
assert_contains "$F2_PY" "_bmad-output/implementation-artifacts" "F2.py"
# Phase A 新 getter：未配置时静默 fallback（quiet — 不应有专属 WARN）
assert_contains "$F2_PY" "frontend_dir: console-web" "F2.py"
assert_contains "$F2_PY" "e2e_test_subdir: tests/e2e" "F2.py"
assert_not_contains "$F2_PY" "WARN [harness_config]: 'frontend_dir'" "F2.py"

F2_SH="$(bash -c "source '$F2_HELPER_DIR/read_harness_config.sh' 2>&1; echo \"ART=\$HARNESS_ARTIFACTS_ROOT\"" 2>&1)"
assert_contains "$F2_SH" "WARN [read_harness_config]: artifacts_root not set" "F2.sh"
assert_contains "$F2_SH" "_bmad-output/implementation-artifacts" "F2.sh"

# Fixture 3: yaml file does NOT exist
echo ""
echo "=== Fixture 3: yaml file missing ==="
TMP_F3="$WORKDIR/f3"
F3_HELPER_DIR="$(make_helper_dir "$TMP_F3")"
# DO NOT create yaml

F3_PY="$(python3 "$F3_HELPER_DIR/harness_config.py" 2>&1)"
assert_contains "$F3_PY" "WARN [harness_config]" "F3.py"
assert_contains "$F3_PY" "_bmad-output/implementation-artifacts" "F3.py"

F3_SH="$(bash -c "source '$F3_HELPER_DIR/read_harness_config.sh' 2>&1; echo \"ART=\$HARNESS_ARTIFACTS_ROOT\"" 2>&1)"
assert_contains "$F3_SH" "_bmad-output/implementation-artifacts" "F3.sh"

# Fixture 4: custom artifacts_root
echo ""
echo "=== Fixture 4: custom artifacts_root ==="
TMP_F4="$WORKDIR/f4"
F4_HELPER_DIR="$(make_helper_dir "$TMP_F4")"
cat > "$TMP_F4/.claude/harness/harness-project-config.yaml" <<'YAML'
project_display_name: 'Fixture 4'
container_orchestrator: 'docker-compose'
frontend_framework: 'Next.js'
backend_languages:
  - 'TypeScript'
e2e_framework: 'Playwright'
artifacts_root: 'docs/specs'
extra:
  frontend_dir: 'frontend'
YAML

F4_PY="$(python3 "$F4_HELPER_DIR/harness_config.py" 2>&1)"
assert_contains "$F4_PY" "docs/specs" "F4.py"
assert_not_contains "$F4_PY" "WARN [harness_config]: artifacts_root" "F4.py"

F4_SH="$(bash -c "source '$F4_HELPER_DIR/read_harness_config.sh' 2>&1; echo \"ART=\$HARNESS_ARTIFACTS_ROOT\"" 2>&1)"
assert_contains "$F4_SH" "docs/specs" "F4.sh"
assert_not_contains "$F4_SH" "WARN [read_harness_config]: artifacts_root not set" "F4.sh"

# Summary
echo ""
echo "================================"
echo " harness_config_test: PASS=$PASS FAIL=$FAIL"
echo "================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0

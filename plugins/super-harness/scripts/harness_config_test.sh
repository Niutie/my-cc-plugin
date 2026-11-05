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
#   - 0.3.0：get_frontend_dir / get_e2e_test_subdir 随测试阶段一起删除，
#     对应断言去掉；bash 侧 read_harness_config_field frontend_dir 仍保留断言
#
# 4 fixtures × (Python + bash)：
#   1. 完整 yaml（全字段填满）       → 全字段读出 + 0 WARN
#   2. 缺字段 (artifacts_root unset) → fallback to default + WARN
#   3. yaml 文件缺失                  → fallback to default + WARN
#   4. yaml 含自定义 artifacts_root   → 真用新值
#   5. 显式空值（[] / '' — 模板形态） → 0 WARN + check 通过（含模板文件本身）
#   6. extra 字段缺失                 → 中性默认（0 条 classifier，无 console-* / go vet）
#   7. 结构错误                       → `check` exit 3 + ERROR 行

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
artifacts_root: '_bmad-output/implementation-artifacts'

extra:
  frontend_dir: 'webapp'
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
extra:
  container_count: 3
YAML

F2_PY="$(python3 "$F2_HELPER_DIR/harness_config.py" 2>&1)"
assert_contains "$F2_PY" "WARN [harness_config]: artifacts_root not set" "F2.py"
assert_contains "$F2_PY" "_bmad-output/implementation-artifacts" "F2.py"

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

# Fixture 5: 显式空值（与模板同形：[] / ''）→ 合法，0 WARN；check 通过
# （0.3.1 回归：此前 `fullstack_review_steps: []` / `project_context: ''` 必 WARN，
#  init §4.5 "任何 WARN 即 rollback" 让新项目 init 一定失败）
echo ""
echo "=== Fixture 5: explicit empty values (template shape) ==="
TMP_F5="$WORKDIR/f5"
F5_HELPER_DIR="$(make_helper_dir "$TMP_F5")"
cat > "$TMP_F5/.claude/harness/harness-project-config.yaml" <<'YAML'
project_display_name: 'Fixture 5'
artifacts_root: ''
extra:
  frontend_dir: ''
  path_classifiers: []
  # 示例注释（不应被当成条目）：
  #   - label: 'x'
  #     regex: '^x/'
  verification_commands: ''
  project_context: ""
  fullstack_review_steps: []   # inline comment
YAML
F5_PY="$(python3 "$F5_HELPER_DIR/harness_config.py" 2>&1)"
assert_not_contains "$F5_PY" "WARN" "F5.py"
assert_contains "$F5_PY" "path_classifiers: 0 entries" "F5.py"
assert_contains "$F5_PY" "fullstack_review_steps: 0 entries" "F5.py"
F5_CHECK="$(python3 "$F5_HELPER_DIR/harness_config.py" check 2>&1)"; F5_RC=$?
assert_contains "$F5_CHECK rc=$F5_RC" "CONFIG_OK rc=0" "F5.check"
F5_SH="$(bash -c "source '$F5_HELPER_DIR/read_harness_config.sh' 2>&1; echo \"ART=\$HARNESS_ARTIFACTS_ROOT\"" 2>&1)"
assert_not_contains "$F5_SH" "WARN" "F5.sh"
assert_contains "$F5_SH" "_bmad-output/implementation-artifacts" "F5.sh"
# shipped template itself must be warning-free and pass check
TPL="$SCRIPT_DIR/../templates/harness-project-config.yaml.template"
if [ -f "$TPL" ]; then
    TPL_OUT="$(python3 "$PY_HELPER" --config-path "$TPL" smoke 2>&1)"
    assert_not_contains "$TPL_OUT" "WARN" "template.smoke"
    TPL_CHECK="$(python3 "$PY_HELPER" --config-path "$TPL" check 2>&1)"; TPL_RC=$?
    assert_contains "$TPL_CHECK rc=$TPL_RC" "CONFIG_OK rc=0" "template.check"
fi

# Fixture 6: 字段缺失 → 中性默认（不得回落到别的项目的 console-api / console-web）
echo ""
echo "=== Fixture 6: absent extra fields → project-neutral defaults ==="
TMP_F6="$WORKDIR/f6"
F6_HELPER_DIR="$(make_helper_dir "$TMP_F6")"
printf "project_display_name: 'Fixture 6'\nartifacts_root: '_bmad-output/implementation-artifacts'\n" \
    > "$TMP_F6/.claude/harness/harness-project-config.yaml"
F6_PY="$(python3 "$F6_HELPER_DIR/harness_config.py" 2>&1)"
assert_contains "$F6_PY" "path_classifiers: 0 entries" "F6.py"
assert_contains "$F6_PY" "WARN [harness_config]: path_classifiers not set" "F6.py"
assert_contains "$F6_PY" "WARN [harness_config]: verification_commands not set" "F6.py"
assert_not_contains "$F6_PY" "console-" "F6.py"
assert_not_contains "$F6_PY" "go vet" "F6.py"
F6_CHECK="$(python3 "$F6_HELPER_DIR/harness_config.py" check 2>/dev/null)"; F6_RC=$?
assert_contains "$F6_CHECK rc=$F6_RC" "CONFIG_OK rc=0" "F6.check (absent ≠ error)"

# Fixture 7: 结构错误 → check exit 3 + ERROR 行（init §4.5 rollback 依据）
echo ""
echo "=== Fixture 7: malformed structure → check exit 3 ==="
TMP_F7="$WORKDIR/f7"
F7_HELPER_DIR="$(make_helper_dir "$TMP_F7")"
cat > "$TMP_F7/.claude/harness/harness-project-config.yaml" <<'YAML'
extra:
  path_classifiers:
    - label: 'bad regex'
      regex: '^api/(('
  fullstack_review_steps:
    - label: 'no path'
  verification_commands:
    go test ./...
YAML
F7_CHECK="$(python3 "$F7_HELPER_DIR/harness_config.py" check 2>&1)"; F7_RC=$?
assert_contains "rc=$F7_RC" "rc=3" "F7.check exit"
assert_contains "$F7_CHECK" "ERROR [harness_config]: extra.path_classifiers 第 1 项 regex" "F7.check"
assert_contains "$F7_CHECK" "ERROR [harness_config]: extra.fullstack_review_steps 第 1 项缺 file_path" "F7.check"
assert_contains "$F7_CHECK" "ERROR [harness_config]: extra.verification_commands" "F7.check"
assert_not_contains "$F7_CHECK" "CONFIG_OK" "F7.check"
# missing file → check fails too
F7B="$(python3 "$PY_HELPER" --config-path "$WORKDIR/nope.yaml" check 2>&1)"; F7B_RC=$?
assert_contains "rc=$F7B_RC $F7B" "rc=3 ERROR [harness_config]: config file missing" "F7.check missing file"

# Summary
echo ""
echo "================================"
echo " harness_config_test: PASS=$PASS FAIL=$FAIL"
echo "================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0

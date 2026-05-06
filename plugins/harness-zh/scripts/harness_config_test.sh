#!/usr/bin/env bash
# Self-test for harness_config.py + read_harness_config.sh.
#
# 4 fixtures × (Python + bash):
#   1. 合法 yaml (默认配置)                → 全字段读出 + 0 WARN
#   2. 缺字段 (artifacts_root unset)       → fallback to default + WARN
#   3. yaml 文件缺失                        → fallback to default + WARN
#   4. yaml 含自定义 artifacts_root         → 真用新值

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PY_HELPER="$REPO_ROOT/.claude/harness/scripts/harness_config.py"
SH_HELPER="$REPO_ROOT/.claude/harness/scripts/read_harness_config.sh"

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
        FAIL=$((FAIL + 1))
    else
        echo "    ✓ $fixture_name: 0 occurrences of '$needle'"
        PASS=$((PASS + 1))
    fi
}

# Fixture 1: real project yaml (live config)
echo "=== Fixture 1: live project yaml ==="
F1_PY="$(python3 "$PY_HELPER" 2>&1)"
assert_contains "$F1_PY" "_bmad-output/implementation-artifacts" "F1.py"
assert_contains "$F1_PY" "path_classifiers: 11 entries" "F1.py"
assert_not_contains "$F1_PY" "WARN" "F1.py"

F1_SH="$(bash -c "source '$SH_HELPER' && echo \"\$HARNESS_ARTIFACTS_ROOT\"" 2>&1)"
assert_contains "$F1_SH" "_bmad-output/implementation-artifacts" "F1.sh"
assert_not_contains "$F1_SH" "WARN" "F1.sh"

# Fixture 2: yaml with artifacts_root field removed
echo ""
echo "=== Fixture 2: missing artifacts_root field ==="
TMP_F2="$(mktemp -d)"
trap 'rm -rf "$TMP_F2"' RETURN
cat > "$TMP_F2/harness-project-config.yaml" <<'YAML'
project_display_name: 'Fixture 2'
container_orchestrator: 'docker-compose'
frontend_framework: 'Next.js'
backend_languages:
  - 'TypeScript'
e2e_framework: 'Playwright'
extra:
  frontend_dir: 'frontend'
YAML
# Simulate by symlinking config dir
F2_HELPER_DIR="$TMP_F2/.claude/harness/scripts"
mkdir -p "$F2_HELPER_DIR"
mkdir -p "$TMP_F2/.claude/harness"
cp "$TMP_F2/harness-project-config.yaml" "$TMP_F2/.claude/harness/harness-project-config.yaml"
cp "$PY_HELPER" "$F2_HELPER_DIR/harness_config.py"
cp "$SH_HELPER" "$F2_HELPER_DIR/read_harness_config.sh"

F2_PY="$(python3 "$F2_HELPER_DIR/harness_config.py" 2>&1)"
assert_contains "$F2_PY" "WARN [harness_config]: artifacts_root not set" "F2.py"
assert_contains "$F2_PY" "_bmad-output/implementation-artifacts" "F2.py"

F2_SH="$(bash -c "source '$F2_HELPER_DIR/read_harness_config.sh' 2>&1; echo \"ART=\$HARNESS_ARTIFACTS_ROOT\"" 2>&1)"
assert_contains "$F2_SH" "WARN [read_harness_config]: artifacts_root not set" "F2.sh"
assert_contains "$F2_SH" "_bmad-output/implementation-artifacts" "F2.sh"

# Fixture 3: yaml file does NOT exist
echo ""
echo "=== Fixture 3: yaml file missing ==="
TMP_F3="$(mktemp -d)"
F3_HELPER_DIR="$TMP_F3/.claude/harness/scripts"
mkdir -p "$F3_HELPER_DIR"
mkdir -p "$TMP_F3/.claude/harness"
cp "$PY_HELPER" "$F3_HELPER_DIR/harness_config.py"
cp "$SH_HELPER" "$F3_HELPER_DIR/read_harness_config.sh"
# DO NOT create yaml

F3_PY="$(python3 "$F3_HELPER_DIR/harness_config.py" 2>&1)"
assert_contains "$F3_PY" "WARN [harness_config]" "F3.py"
assert_contains "$F3_PY" "_bmad-output/implementation-artifacts" "F3.py"

F3_SH="$(bash -c "source '$F3_HELPER_DIR/read_harness_config.sh' 2>&1; echo \"ART=\$HARNESS_ARTIFACTS_ROOT\"" 2>&1)"
assert_contains "$F3_SH" "_bmad-output/implementation-artifacts" "F3.sh"
rm -rf "$TMP_F3"

# Fixture 4: custom artifacts_root
echo ""
echo "=== Fixture 4: custom artifacts_root ==="
TMP_F4="$(mktemp -d)"
F4_HELPER_DIR="$TMP_F4/.claude/harness/scripts"
mkdir -p "$F4_HELPER_DIR"
mkdir -p "$TMP_F4/.claude/harness"
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
cp "$PY_HELPER" "$F4_HELPER_DIR/harness_config.py"
cp "$SH_HELPER" "$F4_HELPER_DIR/read_harness_config.sh"

F4_PY="$(python3 "$F4_HELPER_DIR/harness_config.py" 2>&1)"
assert_contains "$F4_PY" "docs/specs" "F4.py"
assert_not_contains "$F4_PY" "WARN [harness_config]: artifacts_root" "F4.py"

F4_SH="$(bash -c "source '$F4_HELPER_DIR/read_harness_config.sh' 2>&1; echo \"ART=\$HARNESS_ARTIFACTS_ROOT\"" 2>&1)"
assert_contains "$F4_SH" "docs/specs" "F4.sh"
assert_not_contains "$F4_SH" "WARN [read_harness_config]: artifacts_root not set" "F4.sh"
rm -rf "$TMP_F4"

# Summary
echo ""
echo "================================"
echo " harness_config_test: PASS=$PASS FAIL=$FAIL"
echo "================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0

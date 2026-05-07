#!/usr/bin/env bash
# Self-test for check_test_harness_env.sh F4 fix (runtime readiness 双字段).
#
# 3 fixture（chore-harness-codex-review-fixes-2026-05-04 spec Q4 锁定）：
#   F4-1 全装就绪    — npm package + chromium binary + version_check 全 true
#                     → framework_installed=true / chromium_installed=true /
#                       runtime_ready=true / all_available=true
#   F4-2 仅 framework — npm package true，chromium binary 缺
#                     → framework_installed=true / chromium_installed=false /
#                       runtime_ready=false / all_available=false
#   F4-3 全无         — node_modules 缺 → framework_installed=false / runtime_ready=false
#
# 通过 mock pnpm 一脚本（PATH 前置 mock 路径）+ 假 console-web/node_modules/@playwright/test
# 目录 + 假 chromium cache 目录（用 AEGIS_ENV_PROBE_PLAYWRIGHT_CACHE 钩子 override）
# 制造各路径状态。
#
# 整脚本退出码 = 失败 fixture 数（0 = 全过）。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_SH="${SCRIPT_DIR}/check_test_harness_env.sh"

if [ ! -f "$ENV_SH" ]; then
    echo "ERROR: check_test_harness_env.sh not found at $ENV_SH" >&2
    exit 1
fi

PASS=0
FAIL=0

# ---- helpers ----
make_mock_pnpm() {
    # $1 = mock dir，会写入 mock pnpm exec → echo 版本号 + exit 0
    local dir="$1"
    cat > "$dir/pnpm" <<'EOF'
#!/usr/bin/env bash
# Mock pnpm — handles `pnpm -C <dir> exec playwright --version`.
# Just print a fake version and exit 0.
echo "Version 1.50.0"
exit 0
EOF
    chmod +x "$dir/pnpm"
}

assert_field() {
    # $1 = label, $2 = json, $3 = field, $4 = expected (true|false)
    local label="$1" json="$2" field="$3" expected="$4"
    local actual
    actual="$(printf '%s' "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(str(d.get('$field')).lower())")"
    if [ "$actual" = "$expected" ]; then
        echo "  ✓ $label.$field=$expected"
        PASS=$((PASS+1))
        return 0
    fi
    echo "  ✗ $label.$field expected=$expected actual=$actual" >&2
    echo "    json: $json" >&2
    FAIL=$((FAIL+1))
    return 1
}

run_probe() {
    # $1 = repo dir override, $2 = playwright cache dir override
    # Stdin: PATH ordering controlled by caller via mock_pnpm_dir param above.
    local repo="$1" pw_cache="$2"
    AEGIS_ENV_PROBE_REPO="$repo" \
    AEGIS_ENV_PROBE_PLAYWRIGHT_CACHE="$pw_cache" \
    bash "$ENV_SH"
}

# ============================================================================
# Workspace（共用 mock pnpm + 共用 path prefix）
# ============================================================================
WORKDIR="$(mktemp -d -t check_env_test.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

MOCK_BIN="$WORKDIR/mock-bin"
mkdir -p "$MOCK_BIN"
make_mock_pnpm "$MOCK_BIN"
# Front-load mock dir on PATH so the env probe finds our fake pnpm
# (only when this fixture wants pnpm to "succeed"). For "all missing"
# fixture we run with original PATH minus mock so framework dir absence
# is the determining factor.
export PATH="$MOCK_BIN:$PATH"

# ============================================================================
# F4-1: 全装就绪
# ============================================================================
echo "F4-1: 全装就绪（framework + chromium + version 全装）"
F1_REPO="$WORKDIR/repo-all"
mkdir -p "$F1_REPO/console-web/node_modules/@playwright/test"
F1_PW_CACHE="$WORKDIR/pw-cache-all"
mkdir -p "$F1_PW_CACHE/chromium-1129"

OUT="$(run_probe "$F1_REPO" "$F1_PW_CACHE")"
assert_field "F4-1" "$OUT" "framework_installed" "true"
assert_field "F4-1" "$OUT" "chromium_installed"  "true"
assert_field "F4-1" "$OUT" "runtime_ready"       "true"
assert_field "F4-1" "$OUT" "all_available"       "true"

# ============================================================================
# F4-2: 仅 framework（npm 装但 chromium 缺）
# ============================================================================
echo "F4-2: 仅 framework（npm 装但 chromium binary 缺）"
F2_REPO="$WORKDIR/repo-frameworkonly"
mkdir -p "$F2_REPO/console-web/node_modules/@playwright/test"
F2_PW_CACHE="$WORKDIR/pw-cache-empty"
mkdir -p "$F2_PW_CACHE"   # 目录存在但无 chromium-* 子目录

OUT="$(run_probe "$F2_REPO" "$F2_PW_CACHE")"
assert_field "F4-2" "$OUT" "framework_installed" "true"
assert_field "F4-2" "$OUT" "chromium_installed"  "false"
assert_field "F4-2" "$OUT" "runtime_ready"       "false"
assert_field "F4-2" "$OUT" "all_available"       "false"
# reason 应含 "chromium" 标识缺失维度
if echo "$OUT" | grep -q "chromium"; then
    echo "  ✓ F4-2.reason 含 'chromium'"
    PASS=$((PASS+1))
else
    echo "  ✗ F4-2.reason 不含 'chromium' — out: $OUT" >&2
    FAIL=$((FAIL+1))
fi

# ============================================================================
# F4-3: 全无（node_modules 缺）
# ============================================================================
echo "F4-3: 全无（console-web 不存在）"
F3_REPO="$WORKDIR/repo-empty"
mkdir -p "$F3_REPO"   # 仅根目录，无 console-web
F3_PW_CACHE="$WORKDIR/pw-cache-nonexistent"   # 不创建目录

OUT="$(run_probe "$F3_REPO" "$F3_PW_CACHE")"
assert_field "F4-3" "$OUT" "framework_installed" "false"
assert_field "F4-3" "$OUT" "chromium_installed"  "false"
assert_field "F4-3" "$OUT" "runtime_ready"       "false"
assert_field "F4-3" "$OUT" "all_available"       "false"

# ============================================================================
# F4-4: harness-project-config.yaml 含 extra.frontend_dir='web' →
#       探针应查 web/node_modules/@playwright/test，而非硬编码 console-web/
#       （0.1.18 修 0.1.17 之前的硬编码 bug — solo-dev 项目 frontend_dir 非
#        console-web 时全部 story 被静默 sandbox-skip）
# ============================================================================
echo "F4-4: 自定义 frontend_dir='web' via config（修 console-web 硬编码 bug）"
F4_REPO="$WORKDIR/repo-customdir"
mkdir -p "$F4_REPO/.claude/harness"
mkdir -p "$F4_REPO/web/node_modules/@playwright/test"
# 不在 console-web 创建任何东西 — 验证探针真的去 'web' 而非默认
cat > "$F4_REPO/.claude/harness/harness-project-config.yaml" <<'YAML'
project_display_name: 'Test Project'
container_orchestrator: 'docker-compose'

extra:
  frontend_dir: 'web'               # 项目自报前端目录（非 console-web）
  e2e_test_subdir: 'tests/e2e'
YAML
F4_PW_CACHE="$WORKDIR/pw-cache-customdir"
mkdir -p "$F4_PW_CACHE/chromium-1129"

OUT="$(run_probe "$F4_REPO" "$F4_PW_CACHE")"
assert_field "F4-4" "$OUT" "framework_installed" "true"
assert_field "F4-4" "$OUT" "chromium_installed"  "true"
assert_field "F4-4" "$OUT" "runtime_ready"       "true"
assert_field "F4-4" "$OUT" "all_available"       "true"
# 新字段 frontend_dir 必须 == "web"（透明显示探测目录）
if echo "$OUT" | python3 -c "import sys,json; sys.exit(0 if json.load(sys.stdin).get('frontend_dir') == 'web' else 1)" 2>/dev/null; then
    echo "  ✓ F4-4.frontend_dir=web (从 config extra: 解析)"
    PASS=$((PASS+1))
else
    echo "  ✗ F4-4.frontend_dir 应为 'web' — out: $OUT" >&2
    FAIL=$((FAIL+1))
fi

# ============================================================================
# F4-5: config 顶层 frontend_dir 优先（不在 extra: 下也能读出来）
# ============================================================================
echo "F4-5: 顶层 frontend_dir='frontend' via config（顶层 scalar 路径）"
F5_REPO="$WORKDIR/repo-toplevel-fd"
mkdir -p "$F5_REPO/.claude/harness"
mkdir -p "$F5_REPO/frontend/node_modules/@playwright/test"
cat > "$F5_REPO/.claude/harness/harness-project-config.yaml" <<'YAML'
project_display_name: 'Top Level FD Test'
frontend_dir: 'frontend'
YAML
F5_PW_CACHE="$WORKDIR/pw-cache-toplevel"
mkdir -p "$F5_PW_CACHE/chromium-1129"

OUT="$(run_probe "$F5_REPO" "$F5_PW_CACHE")"
assert_field "F4-5" "$OUT" "framework_installed" "true"
assert_field "F4-5" "$OUT" "runtime_ready"       "true"
if echo "$OUT" | python3 -c "import sys,json; sys.exit(0 if json.load(sys.stdin).get('frontend_dir') == 'frontend' else 1)" 2>/dev/null; then
    echo "  ✓ F4-5.frontend_dir=frontend (从 config 顶层 scalar 解析)"
    PASS=$((PASS+1))
else
    echo "  ✗ F4-5.frontend_dir 应为 'frontend' — out: $OUT" >&2
    FAIL=$((FAIL+1))
fi

# ============================================================================
# F4-6: config 文件存在但 frontend_dir 为空字符串 → 保 fallback 'console-web'
#       （template 默认 `frontend_dir: ''` 场景）
# ============================================================================
echo "F4-6: config 有但 frontend_dir='' → fallback 到 console-web"
F6_REPO="$WORKDIR/repo-empty-fd"
mkdir -p "$F6_REPO/.claude/harness"
mkdir -p "$F6_REPO/console-web/node_modules/@playwright/test"
cat > "$F6_REPO/.claude/harness/harness-project-config.yaml" <<'YAML'
project_display_name: 'Empty FD Test'

extra:
  frontend_dir: ''                  # template 默认 — 未填
YAML
F6_PW_CACHE="$WORKDIR/pw-cache-empty-fd"
mkdir -p "$F6_PW_CACHE/chromium-1129"

OUT="$(run_probe "$F6_REPO" "$F6_PW_CACHE")"
assert_field "F4-6" "$OUT" "framework_installed" "true"   # console-web 找得到
if echo "$OUT" | python3 -c "import sys,json; sys.exit(0 if json.load(sys.stdin).get('frontend_dir') == 'console-web' else 1)" 2>/dev/null; then
    echo "  ✓ F4-6.frontend_dir=console-web (空字符串 fallback)"
    PASS=$((PASS+1))
else
    echo "  ✗ F4-6.frontend_dir 应 fallback 'console-web' — out: $OUT" >&2
    FAIL=$((FAIL+1))
fi

# ============================================================================
echo "============================================================================"
echo "PASS=$PASS FAIL=$FAIL"
exit $FAIL

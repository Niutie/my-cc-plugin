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
#   F4-3b pnpm 缺失   — 受控 PATH 无 pnpm → pnpm=false / version_check 缺
#                       （review 2026-06-10 #96 补盲区）
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
# Front-load mock dir on PATH so the env probe finds our fake pnpm. The mock
# stays on PATH for ALL fixtures below — F4-3 ("全无") is driven purely by the
# frontend dir being absent (framework_installed=false), NOT by pnpm absence.
# The pnpm-absent probe branch is covered separately by F4-3b, which runs the
# probe under a restricted PATH (symlink farm without any pnpm).
# (review 2026-06-10 #96：此前这段注释声称 "run with original PATH minus
# mock"，但实现从未恢复 PATH — 注释已对齐实现，pnpm 缺失分支由 F4-3b 真覆盖。)
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
# F4-3 全程带 mock pnpm 跑（见 PATH 注释）→ pnpm 字段应为 true，证明
# framework_installed=false 完全由 console-web 目录缺失驱动
assert_field "F4-3" "$OUT" "pnpm" "true"

# ============================================================================
# F4-3b: pnpm 命令缺失分支（review 2026-06-10 #96 — 此前无任何 fixture 覆盖
#        probe 的 PNPM_RC=1 / PKG_MGR_RC=1 路径）
#        受控 PATH：symlink farm 仅含 probe 必需工具、不含任何 pnpm —— 即使
#        开发机装了真 pnpm 也探测不到。framework + chromium 都齐，唯独 pnpm
#        缺 → version_check 跳过 → runtime_ready=false 且 reason 点名
#        version_check，"pnpm": false。
# ============================================================================
echo "F4-3b: pnpm 缺失（受控 PATH 无 pnpm）→ pnpm=false + version_check 缺"
CLEAN_BIN="$WORKDIR/clean-bin"
mkdir -p "$CLEAN_BIN"
# python3 经 sys.executable 解析真实解释器（绕开 pyenv/venv shim 对 PATH 的依赖）
_real_py="$(python3 -c 'import sys; print(sys.executable)')"
ln -s "$_real_py" "$CLEAN_BIN/python3"
for _tool in bash sh find grep sed awk tr uname head dirname basename env; do
    _p="$(command -v "$_tool" 2>/dev/null || true)"
    [ -n "$_p" ] && [ ! -e "$CLEAN_BIN/$_tool" ] && ln -s "$_p" "$CLEAN_BIN/$_tool"
done
F3B_REPO="$WORKDIR/repo-no-pnpm"
mkdir -p "$F3B_REPO/console-web/node_modules/@playwright/test"
F3B_PW_CACHE="$WORKDIR/pw-cache-no-pnpm"
mkdir -p "$F3B_PW_CACHE/chromium-1129"

OUT="$(PATH="$CLEAN_BIN" AEGIS_ENV_PROBE_REPO="$F3B_REPO" \
       AEGIS_ENV_PROBE_PLAYWRIGHT_CACHE="$F3B_PW_CACHE" \
       bash "$ENV_SH")"
assert_field "F4-3b" "$OUT" "pnpm"                "false"
assert_field "F4-3b" "$OUT" "framework_installed" "true"
assert_field "F4-3b" "$OUT" "chromium_installed"  "true"
assert_field "F4-3b" "$OUT" "runtime_ready"       "false"
assert_field "F4-3b" "$OUT" "all_available"       "false"
# reason 应点名 version_check（pnpm 不可执行 → version 探测被跳过）
if echo "$OUT" | grep -q "version_check"; then
    echo "  ✓ F4-3b.reason 含 'version_check'"
    PASS=$((PASS+1))
else
    echo "  ✗ F4-3b.reason 不含 'version_check' — out: $OUT" >&2
    FAIL=$((FAIL+1))
fi

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
# F4-7: e2e_framework='none' → reason="no_e2e_configured"，跳 Playwright 探测
#       (v0.1.19 A 档 — 解纯后端 Java/Go/Python 项目 sandbox-skip 污染)
# ============================================================================
echo "F4-7: e2e_framework='none' → no_e2e_configured 短路"
F7_REPO="$WORKDIR/repo-no-e2e"
mkdir -p "$F7_REPO/.claude/harness"
# 故意不创建任何 console-web/ 目录 — 验证短路真的不去探测
cat > "$F7_REPO/.claude/harness/harness-project-config.yaml" <<'YAML'
project_display_name: 'Pure Backend Project'
backend_languages:
  - 'Java 17'
e2e_framework: 'none'              # 项目自报无 e2e 需求

extra:
  frontend_dir: ''                  # 无前端
YAML

OUT="$(run_probe "$F7_REPO" "$WORKDIR/pw-cache-doesnt-matter")"
# runtime_ready 应为 false（短路不探测，所有 RC=1）；reason 应为 no_e2e_configured
assert_field "F4-7" "$OUT" "framework_installed" "false"
assert_field "F4-7" "$OUT" "runtime_ready"       "false"
assert_field "F4-7" "$OUT" "all_available"       "false"
if echo "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('reason') == 'no_e2e_configured' and d.get('e2e_framework') == 'none' else 1)" 2>/dev/null; then
    echo "  ✓ F4-7.reason=no_e2e_configured + e2e_framework=none"
    PASS=$((PASS+1))
else
    echo "  ✗ F4-7.reason / e2e_framework — out: $OUT" >&2
    FAIL=$((FAIL+1))
fi

# ============================================================================
# F4-8: e2e_framework='Cypress' → reason="probe_not_implemented_for_Cypress"
# ============================================================================
echo "F4-8: e2e_framework='Cypress' → probe_not_implemented_for_Cypress 短路"
F8_REPO="$WORKDIR/repo-cypress"
mkdir -p "$F8_REPO/.claude/harness"
mkdir -p "$F8_REPO/web/cypress"
cat > "$F8_REPO/.claude/harness/harness-project-config.yaml" <<'YAML'
project_display_name: 'Cypress Project'
e2e_framework: 'Cypress'

extra:
  frontend_dir: 'web'
YAML

# stderr 抓 WARN
F8_STDERR="$WORKDIR/f8-stderr.txt"
OUT="$(run_probe "$F8_REPO" "$WORKDIR/pw-cache-doesnt-matter" 2>"$F8_STDERR")"

assert_field "F4-8" "$OUT" "runtime_ready" "false"
assert_field "F4-8" "$OUT" "all_available" "false"
if echo "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('reason') == 'probe_not_implemented_for_Cypress' and d.get('e2e_framework') == 'Cypress' else 1)" 2>/dev/null; then
    echo "  ✓ F4-8.reason=probe_not_implemented_for_Cypress"
    PASS=$((PASS+1))
else
    echo "  ✗ F4-8.reason / e2e_framework — out: $OUT" >&2
    FAIL=$((FAIL+1))
fi
# 验证 stderr 有 WARN
if grep -q "WARN.*e2e_framework='Cypress'" "$F8_STDERR" 2>/dev/null; then
    echo "  ✓ F4-8.stderr 含 WARN about Cypress"
    PASS=$((PASS+1))
else
    echo "  ✗ F4-8.stderr 缺 WARN — content: $(cat "$F8_STDERR" 2>/dev/null)" >&2
    FAIL=$((FAIL+1))
fi

# ============================================================================
# F4-9: e2e_framework='Playwright' （显式声明）+ frontend_dir='web' →
#       走真 probe；不短路
# ============================================================================
echo "F4-9: e2e_framework='Playwright' 显式 → 真 probe 不短路"
F9_REPO="$WORKDIR/repo-explicit-pw"
mkdir -p "$F9_REPO/.claude/harness"
mkdir -p "$F9_REPO/web/node_modules/@playwright/test"
cat > "$F9_REPO/.claude/harness/harness-project-config.yaml" <<'YAML'
project_display_name: 'Explicit Playwright'
e2e_framework: 'Playwright'

extra:
  frontend_dir: 'web'
YAML
F9_PW_CACHE="$WORKDIR/pw-cache-explicit"
mkdir -p "$F9_PW_CACHE/chromium-1129"

OUT="$(run_probe "$F9_REPO" "$F9_PW_CACHE")"
assert_field "F4-9" "$OUT" "framework_installed" "true"
assert_field "F4-9" "$OUT" "chromium_installed"  "true"
assert_field "F4-9" "$OUT" "runtime_ready"       "true"
if echo "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('reason') == 'real_probe' and d.get('e2e_framework') == 'Playwright' else 1)" 2>/dev/null; then
    echo "  ✓ F4-9.reason=real_probe + e2e_framework=Playwright"
    PASS=$((PASS+1))
else
    echo "  ✗ F4-9.reason / e2e_framework — out: $OUT" >&2
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
# F4-10: pnpm-lock.yaml → package_manager='pnpm' (default & explicit)
# ============================================================================
echo "F4-10: pnpm-lock.yaml → package_manager=pnpm"
F10_REPO="$WORKDIR/repo-pnpm-lock"
mkdir -p "$F10_REPO/.claude/harness"
mkdir -p "$F10_REPO/web/node_modules/@playwright/test"
touch "$F10_REPO/web/pnpm-lock.yaml"
cat > "$F10_REPO/.claude/harness/harness-project-config.yaml" <<'YAML'
extra:
  frontend_dir: 'web'
YAML
F10_PW_CACHE="$WORKDIR/pw-cache-pnpm-lock"
mkdir -p "$F10_PW_CACHE/chromium-1129"

OUT="$(run_probe "$F10_REPO" "$F10_PW_CACHE")"
if echo "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('package_manager') == 'pnpm' else 1)" 2>/dev/null; then
    echo "  ✓ F4-10.package_manager=pnpm (lockfile=pnpm-lock.yaml)"
    PASS=$((PASS+1))
else
    echo "  ✗ F4-10.package_manager 应=pnpm — out: $OUT" >&2
    FAIL=$((FAIL+1))
fi

# ============================================================================
# F4-11: yarn.lock → package_manager='yarn' (核心修复 — 旧版 yarn 用户硬编码 pnpm 失败)
# ============================================================================
echo "F4-11: yarn.lock → package_manager=yarn"
F11_REPO="$WORKDIR/repo-yarn-lock"
mkdir -p "$F11_REPO/.claude/harness"
mkdir -p "$F11_REPO/web/node_modules/@playwright/test"
touch "$F11_REPO/web/yarn.lock"
# 注意：故意不放 pnpm-lock.yaml — 验证检测到 yarn 而非 fallback pnpm
cat > "$F11_REPO/.claude/harness/harness-project-config.yaml" <<'YAML'
extra:
  frontend_dir: 'web'
YAML
F11_PW_CACHE="$WORKDIR/pw-cache-yarn-lock"
mkdir -p "$F11_PW_CACHE/chromium-1129"

OUT="$(run_probe "$F11_REPO" "$F11_PW_CACHE")"
if echo "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('package_manager') == 'yarn' else 1)" 2>/dev/null; then
    echo "  ✓ F4-11.package_manager=yarn (lockfile=yarn.lock)"
    PASS=$((PASS+1))
else
    echo "  ✗ F4-11.package_manager 应=yarn — out: $OUT" >&2
    FAIL=$((FAIL+1))
fi

# ============================================================================
# F4-12: package-lock.json → package_manager='npm'
# ============================================================================
echo "F4-12: package-lock.json → package_manager=npm"
F12_REPO="$WORKDIR/repo-npm-lock"
mkdir -p "$F12_REPO/.claude/harness"
mkdir -p "$F12_REPO/web/node_modules/@playwright/test"
touch "$F12_REPO/web/package-lock.json"
cat > "$F12_REPO/.claude/harness/harness-project-config.yaml" <<'YAML'
extra:
  frontend_dir: 'web'
YAML
F12_PW_CACHE="$WORKDIR/pw-cache-npm-lock"
mkdir -p "$F12_PW_CACHE/chromium-1129"

OUT="$(run_probe "$F12_REPO" "$F12_PW_CACHE")"
if echo "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('package_manager') == 'npm' else 1)" 2>/dev/null; then
    echo "  ✓ F4-12.package_manager=npm (lockfile=package-lock.json)"
    PASS=$((PASS+1))
else
    echo "  ✗ F4-12.package_manager 应=npm — out: $OUT" >&2
    FAIL=$((FAIL+1))
fi

# ============================================================================
# F4-13: bun.lock → package_manager='bun'
# ============================================================================
echo "F4-13: bun.lock → package_manager=bun"
F13_REPO="$WORKDIR/repo-bun-lock"
mkdir -p "$F13_REPO/.claude/harness"
mkdir -p "$F13_REPO/web/node_modules/@playwright/test"
touch "$F13_REPO/web/bun.lock"
cat > "$F13_REPO/.claude/harness/harness-project-config.yaml" <<'YAML'
extra:
  frontend_dir: 'web'
YAML
F13_PW_CACHE="$WORKDIR/pw-cache-bun-lock"
mkdir -p "$F13_PW_CACHE/chromium-1129"

OUT="$(run_probe "$F13_REPO" "$F13_PW_CACHE")"
if echo "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('package_manager') == 'bun' else 1)" 2>/dev/null; then
    echo "  ✓ F4-13.package_manager=bun (lockfile=bun.lock)"
    PASS=$((PASS+1))
else
    echo "  ✗ F4-13.package_manager 应=bun — out: $OUT" >&2
    FAIL=$((FAIL+1))
fi

# ============================================================================
# F4-14: 无 lockfile → fallback package_manager='pnpm' (保 backward-compat)
# ============================================================================
echo "F4-14: 无 lockfile → fallback package_manager=pnpm"
F14_REPO="$WORKDIR/repo-no-lock"
mkdir -p "$F14_REPO/.claude/harness"
mkdir -p "$F14_REPO/web/node_modules/@playwright/test"
# 故意不放任何 lockfile
cat > "$F14_REPO/.claude/harness/harness-project-config.yaml" <<'YAML'
extra:
  frontend_dir: 'web'
YAML
F14_PW_CACHE="$WORKDIR/pw-cache-no-lock"
mkdir -p "$F14_PW_CACHE/chromium-1129"

OUT="$(run_probe "$F14_REPO" "$F14_PW_CACHE")"
if echo "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('package_manager') == 'pnpm' else 1)" 2>/dev/null; then
    echo "  ✓ F4-14.package_manager=pnpm (无 lockfile fallback)"
    PASS=$((PASS+1))
else
    echo "  ✗ F4-14.package_manager 应 fallback=pnpm — out: $OUT" >&2
    FAIL=$((FAIL+1))
fi

# ============================================================================
# F4-16: codex review fix #1 — frontend_dir 含单引号 + 磁盘上含恶意目录时
#        sh -c 命令注入回归（v0.1.21 — 把 `sh -c "cd '${var}'..."` 改成
#        `bash -c '... "$1" ...' _ "$var"` 后应彻底拦死）
# ============================================================================
echo "F4-16: codex fix #1 — sh -c 命令注入回归（恶意 frontend_dir + 磁盘 evil dir）"
F16_REPO="$WORKDIR/repo-injection-regression"
mkdir -p "$F16_REPO/.claude/harness"
PWN_FILE="$WORKDIR/f16-codex-finding1-pwn-marker"
rm -f "$PWN_FILE"
# 在 repo 内建一个名字含单引号的"前端目录"，并在内部建 framework 路径，
# 让 [-d] check 通过、走到 version_check（注入触发面）
EVIL_NAME="web'; touch '$PWN_FILE'; cd '"
mkdir -p "$F16_REPO/$EVIL_NAME/node_modules/@playwright/test"
cat > "$F16_REPO/.claude/harness/harness-project-config.yaml" <<EOF
extra:
  frontend_dir: "${EVIL_NAME}"
EOF
F16_PW_CACHE="$WORKDIR/pw-cache-injection"
mkdir -p "$F16_PW_CACHE/chromium-1129"

# Mock pnpm-lock.yaml 触发 pkg manager = pnpm 路径（含 sh -c）
touch "$F16_REPO/$EVIL_NAME/pnpm-lock.yaml"

run_probe "$F16_REPO" "$F16_PW_CACHE" >/dev/null 2>&1

if [ ! -f "$PWN_FILE" ]; then
    echo "  ✓ F4-16 sh -c 注入被拦截（PWN_FILE 未创建 — bash -c '... \$1 ...' 不做插值）"
    PASS=$((PASS+1))
else
    echo "  ✗ F4-16 注入仍触发：$PWN_FILE 被创建" >&2
    rm -f "$PWN_FILE"
    FAIL=$((FAIL+1))
fi
rm -rf "$F16_REPO"

# ============================================================================
# F4-17: codex review fix #2 — yaml 字段含裸双引号时 JSON 输出仍合法
#        (v0.1.21 — printf 改 python3 json.dumps 后应自动转义)
# ============================================================================
echo "F4-17: codex fix #2 — yaml 含裸双引号 → JSON 输出合法（python3 编码）"
F17_REPO="$WORKDIR/repo-json-escape"
mkdir -p "$F17_REPO/.claude/harness"
mkdir -p "$F17_REPO/web/node_modules/@playwright/test"
# yaml single-quoted scalar 内的 " 不转义，是 JSON 输出的真实压力测试
cat > "$F17_REPO/.claude/harness/harness-project-config.yaml" <<'YAML'
e2e_framework: 'Cypress "v13"'

extra:
  frontend_dir: 'web'
YAML
F17_PW_CACHE="$WORKDIR/pw-cache-json-escape"
mkdir -p "$F17_PW_CACHE/chromium-1129"

OUT="$(run_probe "$F17_REPO" "$F17_PW_CACHE")"
# 用 python3 真解析 — 0.1.20 之前会 JSONDecodeError；0.1.21 之后应通过
if echo "$OUT" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    if d.get('e2e_framework') == 'Cypress \"v13\"':
        print('OK')
    else:
        print('PARSE_OK_BUT_VALUE_WRONG:', repr(d.get('e2e_framework')))
except json.JSONDecodeError as e:
    print('PARSE_FAIL:', e)
" 2>/dev/null | grep -q "^OK$"; then
    echo "  ✓ F4-17 含裸双引号 yaml → JSON 仍合法 + 字段值正确"
    PASS=$((PASS+1))
else
    echo "  ✗ F4-17 JSON 转义未修好 — out: $OUT" >&2
    FAIL=$((FAIL+1))
fi
rm -rf "$F17_REPO"

# ============================================================================
# F4-15: 多个 lockfile 共存 → pnpm-lock.yaml 优先（priority cascade 验证）
# ============================================================================
echo "F4-15: pnpm-lock + yarn.lock 共存 → pnpm 优先"
F15_REPO="$WORKDIR/repo-multi-lock"
mkdir -p "$F15_REPO/.claude/harness"
mkdir -p "$F15_REPO/web/node_modules/@playwright/test"
touch "$F15_REPO/web/pnpm-lock.yaml"
touch "$F15_REPO/web/yarn.lock"
touch "$F15_REPO/web/package-lock.json"
cat > "$F15_REPO/.claude/harness/harness-project-config.yaml" <<'YAML'
extra:
  frontend_dir: 'web'
YAML
F15_PW_CACHE="$WORKDIR/pw-cache-multi-lock"
mkdir -p "$F15_PW_CACHE/chromium-1129"

OUT="$(run_probe "$F15_REPO" "$F15_PW_CACHE")"
if echo "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('package_manager') == 'pnpm' else 1)" 2>/dev/null; then
    echo "  ✓ F4-15.package_manager=pnpm (优先级 pnpm > yarn > npm)"
    PASS=$((PASS+1))
else
    echo "  ✗ F4-15.package_manager 应=pnpm (cascade 优先) — out: $OUT" >&2
    FAIL=$((FAIL+1))
fi

# ============================================================================
echo "============================================================================"
echo "PASS=$PASS FAIL=$FAIL"
exit $FAIL

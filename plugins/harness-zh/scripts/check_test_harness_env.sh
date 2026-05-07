#!/usr/bin/env bash
# Test harness environment probe
#
# 检测当前会话是否具备跑 e2e 测试的全部条件（docker / pnpm / node / @playwright/test
# 框架装载 / Playwright runtime 真就绪）。输出**一行 JSON** 到 stdout（供
# .claude/commands/run-test.md 解析），exit 0 永远——所有"环境受限"路径都由
# 调用方按 JSON 决断 graceful skip，不通过退出码传信号。
#
# F4 finding 修复（codex adversarial review 2026-05-04）：原版用
# `[ -d console-web/node_modules/@playwright/test ]` 把 npm 包装载当 Playwright
# 就绪，但 chromium binary 由 `playwright install --with-deps chromium` 单独装。
# CI 装 npm 但漏跑 install 时 all_available=true 路由到真 e2e → runtime 挂。
# 升级为运行时检查：
#   - framework_installed = npm 包目录存在
#   - chromium_installed  = ~/Library/Caches/ms-playwright/chromium-* 存在
#                           或 ${PLAYWRIGHT_BROWSERS_PATH}/chromium-* 存在
#   - version_check       = `pnpm exec playwright --version` exit 0 + 输出含版本号
#                           （bounded 5s timeout，防 lockup hang 探针）
#   - runtime_ready       = framework && chromium && version
#   - all_available       = runtime_ready（向后兼容；原 docker/pnpm/node/playwright
#                           三维度仍输出但不再纳入 all_available 判定）
#
# Sandbox override（用于 stage 5.5 / 5-fallback graceful skip 路径单测）：
#   FORCE_SANDBOX=1 → 不真探测，所有维度直接返回 false（reason="forced_sandbox"）
#
# Self-test mock 钩子（仅 check_test_harness_env_test.sh 用）：
#   AEGIS_ENV_PROBE_REPO=<path>           override repo root（默认 git rev-parse）
#   AEGIS_ENV_PROBE_PLAYWRIGHT_CACHE=<path>  override chromium cache 探测路径
#                                            （默认 ~/Library/Caches/ms-playwright）
#
# frontend_dir 解析（v0.1.18 — 修 0.1.17 之前硬编码 console-web 的 bug）：
# 从 ${REPO_ROOT}/.claude/harness/harness-project-config.yaml 读 `frontend_dir`
# 字段（顶层 scalar 或 `extra:` 二级 scalar）。未配置 / 文件缺失 → fallback
# 到 'console-web'（保 backward-compat：旧用户 + 现有 self-test fixture 不变）。
#
# e2e_framework 短路（v0.1.19 — A 档：解 Java/Go/Python 纯后端项目 sandbox-skip
# 污染 deferred-work.md 的痛点）：
# 从 config 读顶层 `e2e_framework` 字段，case-insensitive 分流：
#   - 'none' / 'n/a' / 'na' / 'no' → 短路成 reason="no_e2e_configured"，跳过
#       Playwright 探测（因为项目自报无 e2e 需求）。run-test.md §4 据此走 clean
#       no-e2e skip 路径，**不**写 FU-Test-*-sandbox 到 deferred-work
#   - 'cypress' / 'webdriverio' / 'selenium' / 任何其它非空非 Playwright 值
#       → 短路成 reason="probe_not_implemented_for_<X>" + stderr WARN，提示
#       T3/T4 stages 仍是 Playwright 实现，本栈未支持
#   - 'playwright' / 空 / 缺失 → 走现有 Playwright 探测（默认）
# 短路路径下所有 RC 设 1（runtime_ready=false），让现有 §4 sandbox-skip 入口
# 兼容；branch 由 reason 字段决定。
#
# 输出 JSON 含 `frontend_dir` + `e2e_framework` 字段供调用方透明显示。
#
# 输出 schema（紧凑 JSON 一行 + 末尾换行）：
#   {"docker": <bool>, "pnpm": <bool>, "node": <bool>, "playwright": <bool>,
#    "framework_installed": <bool>, "chromium_installed": <bool>,
#    "runtime_ready": <bool>, "all_available": <bool>,
#    "frontend_dir": "<probed dir>",
#    "e2e_framework": "<configured framework or ''>",
#    "reason": "real_probe"|"forced_sandbox"|"no_e2e_configured"
#            |"probe_not_implemented_for_<X>"|"real_probe; missing: ..."}
#
# 用法：
#   bash .claude/harness/scripts/check_test_harness_env.sh
#   FORCE_SANDBOX=1 bash .claude/harness/scripts/check_test_harness_env.sh

set -u

# ---- emit JSON helper（避免 bash bool 的奇怪写法） ----
bool() {
    if [ "$1" = "0" ]; then echo "true"; else echo "false"; fi
}

# ---- portable timeout (Linux: timeout / macOS+homebrew: gtimeout / fallback: pure bash) ----
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
        return $?
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$secs" "$@"
        return $?
    fi
    # Pure-bash fallback (no GNU coreutils available)
    "$@" &
    local pid=$!
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$secs" ]; then
            kill -TERM "$pid" 2>/dev/null
            sleep 1
            kill -KILL "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 1
        waited=$((waited+1))
    done
    wait "$pid" 2>/dev/null
    return $?
}

# ---- repo root（cwd-independent；self-test 可通过 AEGIS_ENV_PROBE_REPO override） ----
if [ -n "${AEGIS_ENV_PROBE_REPO:-}" ]; then
    REPO_ROOT="$AEGIS_ENV_PROBE_REPO"
else
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

# ---- Playwright chromium cache override（self-test 可 override） ----
PW_CACHE_DIR="${AEGIS_ENV_PROBE_PLAYWRIGHT_CACHE:-${PLAYWRIGHT_BROWSERS_PATH:-$HOME/Library/Caches/ms-playwright}}"

# ---- frontend_dir：从 harness-project-config.yaml 读；缺则 fallback 'console-web' ----
# 不 source read_harness_config.sh — 那个 helper 把 REPO_ROOT 绑定到自己的脚本路径，
# 与本脚本通过 AEGIS_ENV_PROBE_REPO 控制 REPO_ROOT 的语义冲突。本地 inline 解析。
FRONTEND_DIR="console-web"
_HARNESS_CONFIG="${REPO_ROOT}/.claude/harness/harness-project-config.yaml"
if [ -f "$_HARNESS_CONFIG" ]; then
    # 顶层 scalar 优先
    _fd_val="$(grep -E "^frontend_dir:[[:space:]]" "$_HARNESS_CONFIG" 2>/dev/null \
              | head -1 \
              | sed -E "s/^frontend_dir:[[:space:]]+//")"
    # 退到 extra: 二级 scalar
    if [ -z "$_fd_val" ]; then
        _fd_val="$(awk '
            /^extra:/ { in_extra=1; next }
            in_extra && /^[^[:space:]#]/ { in_extra=0 }
            in_extra && /^[[:space:]]+frontend_dir:[[:space:]]/ {
                sub(/^[[:space:]]+frontend_dir:[[:space:]]+/, "")
                # 同时去掉行尾 inline comment（`# foo` 段）
                sub(/[[:space:]]+#.*$/, "")
                print
                exit
            }
        ' "$_HARNESS_CONFIG" 2>/dev/null)"
    fi
    if [ -n "$_fd_val" ]; then
        # 去外层引号 + 尾随空白
        _fd_val="${_fd_val#\'}"; _fd_val="${_fd_val%\'}"
        _fd_val="${_fd_val#\"}"; _fd_val="${_fd_val%\"}"
        _fd_val="${_fd_val%"${_fd_val##*[![:space:]]}"}"
        # 空字符串（template 默认 '' 或被清空）→ 保 fallback 'console-web'
        if [ -n "$_fd_val" ]; then
            FRONTEND_DIR="$_fd_val"
        fi
    fi
fi

# ---- e2e_framework：短路决策（v0.1.19 A 档） ----
# 仅顶层 scalar；extra: 下不放本字段（template 设计 — 保跟 frontend_framework /
# backend_languages 等顶层栈字段对齐）。
E2E_FRAMEWORK=""
if [ -f "$_HARNESS_CONFIG" ]; then
    _ef_val="$(grep -E "^e2e_framework:[[:space:]]" "$_HARNESS_CONFIG" 2>/dev/null \
              | head -1 \
              | sed -E "s/^e2e_framework:[[:space:]]+//")"
    if [ -n "$_ef_val" ]; then
        # strip inline comment 先（避免引号去剥 + 注释一起被当 value）
        _ef_val="$(printf '%s' "$_ef_val" | sed -E 's/[[:space:]]+#.*$//')"
        # 去外层引号
        _ef_val="${_ef_val#\'}"; _ef_val="${_ef_val%\'}"
        _ef_val="${_ef_val#\"}"; _ef_val="${_ef_val%\"}"
        # 去尾随空白
        _ef_val="${_ef_val%"${_ef_val##*[![:space:]]}"}"
        E2E_FRAMEWORK="$_ef_val"
    fi
fi

# 短路判定 — case-insensitive 分流
SHORT_CIRCUIT=""
_ef_lower="$(printf '%s' "$E2E_FRAMEWORK" | tr '[:upper:]' '[:lower:]')"
case "$_ef_lower" in
    none|"n/a"|na|no)
        SHORT_CIRCUIT="no_e2e_configured"
        ;;
    ""|playwright)
        # 默认 Playwright 路径 — 不短路
        :
        ;;
    cypress|webdriverio|selenium)
        SHORT_CIRCUIT="probe_not_implemented_for_${E2E_FRAMEWORK}"
        echo "WARN [check_test_harness_env]: e2e_framework='${E2E_FRAMEWORK}' — probe 仅实现 Playwright；T3/T4 stages 也是 Playwright-coded。本栈走 sandbox-skip + informative reason；如需真支持请提 feature request。" >&2
        ;;
    *)
        # unknown framework — 当作未实现处理
        SHORT_CIRCUIT="probe_not_implemented_for_${E2E_FRAMEWORK}"
        echo "WARN [check_test_harness_env]: 未识别 e2e_framework='${E2E_FRAMEWORK}' — 仅 Playwright 完整支持。走 sandbox-skip。" >&2
        ;;
esac

# ---- FORCE_SANDBOX env override + e2e_framework SHORT_CIRCUIT ----
# 优先级：FORCE_SANDBOX > SHORT_CIRCUIT > 真探测
REASON_DETAIL=""
if [ "${FORCE_SANDBOX:-0}" = "1" ]; then
    DOCKER_RC=1
    PNPM_RC=1
    NODE_RC=1
    PLAYWRIGHT_RC=1
    FRAMEWORK_RC=1
    CHROMIUM_RC=1
    VERSION_RC=1
    REASON="forced_sandbox"
elif [ -n "$SHORT_CIRCUIT" ]; then
    # e2e_framework 短路：跳过 Playwright 探测；所有 RC=1 让 §4 sandbox-skip 入口
    # 兼容；reason 字段决定 §4 内 branch（no_e2e clean skip 还是 sandbox-skip）
    DOCKER_RC=1
    PNPM_RC=1
    NODE_RC=1
    PLAYWRIGHT_RC=1
    FRAMEWORK_RC=1
    CHROMIUM_RC=1
    VERSION_RC=1
    REASON="$SHORT_CIRCUIT"
else
    REASON="real_probe"

    # docker：command 存在 + daemon 可达
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        DOCKER_RC=0
    else
        DOCKER_RC=1
    fi

    # pnpm
    if command -v pnpm >/dev/null 2>&1; then
        PNPM_RC=0
    else
        PNPM_RC=1
    fi

    # node
    if command -v node >/dev/null 2>&1; then
        NODE_RC=0
    else
        NODE_RC=1
    fi

    # framework_installed: ${FRONTEND_DIR}/node_modules/@playwright/test 目录存在
    if [ -d "${REPO_ROOT}/${FRONTEND_DIR}/node_modules/@playwright/test" ]; then
        FRAMEWORK_RC=0
        PLAYWRIGHT_RC=0   # legacy field — kept for backward compat
    else
        FRAMEWORK_RC=1
        PLAYWRIGHT_RC=1
    fi

    # chromium_installed: PW_CACHE_DIR/chromium-* 任一目录存在
    CHROMIUM_RC=1
    if [ -d "$PW_CACHE_DIR" ]; then
        # find -maxdepth 1 + -name 比 glob 更可靠（PW_CACHE_DIR 不存在时 glob 会展开为 literal）
        if find "$PW_CACHE_DIR" -maxdepth 1 -mindepth 1 -type d -name 'chromium-*' 2>/dev/null | grep -q .; then
            CHROMIUM_RC=0
        fi
    fi

    # version_check: pnpm exec playwright --version 在 5s 内退 0 + 输出含 "Version" 或数字
    VERSION_RC=1
    if [ "$FRAMEWORK_RC" = "0" ] && [ "$PNPM_RC" = "0" ]; then
        PW_OUT="$(run_with_timeout 5 pnpm -C "${REPO_ROOT}/${FRONTEND_DIR}" exec playwright --version 2>/dev/null || true)"
        # Playwright --version 输出形如 "Version 1.50.0" 或 "1.50.0"
        if echo "$PW_OUT" | grep -Eq '[0-9]+\.[0-9]+\.[0-9]+'; then
            VERSION_RC=0
        fi
    fi

    # 拼 reason 详细 missing 列表（runtime_ready=false 时填）
    MISSING=""
    [ "$FRAMEWORK_RC" != "0" ] && MISSING="${MISSING}framework "
    [ "$CHROMIUM_RC" != "0" ]  && MISSING="${MISSING}chromium "
    [ "$VERSION_RC" != "0" ]   && MISSING="${MISSING}version_check "
    if [ -n "$MISSING" ]; then
        # 修剪尾部空格
        MISSING="${MISSING% }"
        REASON_DETAIL="missing: ${MISSING}"
    fi
fi

# runtime_ready = framework && chromium && version
if [ "$FRAMEWORK_RC" = "0" ] && [ "$CHROMIUM_RC" = "0" ] && [ "$VERSION_RC" = "0" ]; then
    RUNTIME_RC=0
else
    RUNTIME_RC=1
fi

# all_available = runtime_ready (F4 fix — 不再用旧 4 维度联合)
ALL_RC=$RUNTIME_RC

# REASON 字段最终拼接：
#   - forced_sandbox / no_e2e_configured / probe_not_implemented_for_X → 直返
#   - real_probe + missing → "real_probe; missing: ..."
#   - real_probe + ready → "real_probe"
case "$REASON" in
    forced_sandbox|no_e2e_configured|probe_not_implemented_for_*)
        FINAL_REASON="$REASON"
        ;;
    *)
        if [ -n "$REASON_DETAIL" ]; then
            FINAL_REASON="real_probe; ${REASON_DETAIL}"
        else
            FINAL_REASON="real_probe"
        fi
        ;;
esac

# 紧凑 JSON 单行
printf '{"docker": %s, "pnpm": %s, "node": %s, "playwright": %s, "framework_installed": %s, "chromium_installed": %s, "runtime_ready": %s, "all_available": %s, "frontend_dir": "%s", "e2e_framework": "%s", "reason": "%s"}\n' \
    "$(bool $DOCKER_RC)" \
    "$(bool $PNPM_RC)" \
    "$(bool $NODE_RC)" \
    "$(bool $PLAYWRIGHT_RC)" \
    "$(bool $FRAMEWORK_RC)" \
    "$(bool $CHROMIUM_RC)" \
    "$(bool $RUNTIME_RC)" \
    "$(bool $ALL_RC)" \
    "$FRONTEND_DIR" \
    "$E2E_FRAMEWORK" \
    "$FINAL_REASON"

exit 0

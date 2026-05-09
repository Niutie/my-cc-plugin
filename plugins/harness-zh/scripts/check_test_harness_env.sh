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
# 输出 JSON 含 `frontend_dir` + `e2e_framework` + `package_manager` 字段供调
# 用方透明显示。
#
# package_manager 自动检测（v0.1.20 — 解 0.1.19 之前 pnpm 写死的痛点）：
# 在 ${FRONTEND_DIR} 内查 lockfile 决定 package manager；优先级：
#   pnpm-lock.yaml → pnpm
#   bun.lock(b)    → bun
#   yarn.lock      → yarn
#   package-lock.json → npm
#   都没有         → 默认 pnpm（保 backward-compat）
# 决定后用对应 manager 跑 version_check：
#   pnpm: pnpm exec playwright --version
#   yarn: yarn exec playwright --version
#   npm:  npx playwright --version
#   bun:  bun x playwright --version
# 解决了 yarn/npm/bun 项目即使装了 Playwright 也被静默判 false 的 bug。
#
# 输出 schema（紧凑 JSON 一行 + 末尾换行）：
#   {"docker": <bool>, "pnpm": <bool>, "node": <bool>, "playwright": <bool>,
#    "framework_installed": <bool>, "chromium_installed": <bool>,
#    "runtime_ready": <bool>, "all_available": <bool>,
#    "frontend_dir": "<probed dir>",
#    "e2e_framework": "<configured framework or ''>",
#    "package_manager": "<detected: pnpm|yarn|npm|bun, '' on short-circuit>",
#    "reason": "real_probe"|"forced_sandbox"|"no_e2e_configured"
#            |"probe_not_implemented_for_<X>"|"real_probe; missing: ..."}
#
# 用法：
#   bash .claude/harness/scripts/check_test_harness_env.sh
#   FORCE_SANDBOX=1 bash .claude/harness/scripts/check_test_harness_env.sh

set -uo pipefail

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
# v0.1.27+：shell-out 调 harness_config.py（消除 4-way YAML 解析重复）。
# 用 --config-path flag 而非 source read_harness_config.sh，保留本脚本通过
# AEGIS_ENV_PROBE_REPO 控制 REPO_ROOT 的能力（read_harness_config.sh 把
# REPO_ROOT 绑定到自己的脚本路径，与本脚本语义冲突）。
# python3 不在或 harness_config.py 缺失时退化到内联 awk 兜底。
FRONTEND_DIR="console-web"
_HARNESS_CONFIG="${REPO_ROOT}/.claude/harness/harness-project-config.yaml"
_CTHE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HARNESS_CONFIG_PY="$_CTHE_DIR/harness_config.py"
if [ -f "$_HARNESS_CONFIG" ]; then
    if command -v python3 >/dev/null 2>&1 && [ -f "$_HARNESS_CONFIG_PY" ]; then
        _fd_val="$(python3 "$_HARNESS_CONFIG_PY" \
                       --config-path "$_HARNESS_CONFIG" \
                       --get frontend_dir --default '' --quiet 2>/dev/null || true)"
    else
        # Fallback: inline awk parser (verbatim pre-0.1.27)
        _fd_val="$(grep -E "^frontend_dir:[[:space:]]" "$_HARNESS_CONFIG" 2>/dev/null \
                  | head -1 \
                  | sed -E "s/^frontend_dir:[[:space:]]+//")"
        if [ -z "$_fd_val" ]; then
            _fd_val="$(awk '
                /^extra:/ { in_extra=1; next }
                in_extra && /^[^[:space:]#]/ { in_extra=0 }
                in_extra && /^[[:space:]]+frontend_dir:[[:space:]]/ {
                    sub(/^[[:space:]]+frontend_dir:[[:space:]]+/, "")
                    sub(/[[:space:]]+#.*$/, "")
                    print
                    exit
                }
            ' "$_HARNESS_CONFIG" 2>/dev/null)"
        fi
        # 去外层引号（single OR double，不两轮都剥；v0.1.21 fix）
        case "$_fd_val" in
            \'*\') _fd_val="${_fd_val#\'}"; _fd_val="${_fd_val%\'}" ;;
            \"*\") _fd_val="${_fd_val#\"}"; _fd_val="${_fd_val%\"}" ;;
        esac
        _fd_val="${_fd_val%"${_fd_val##*[![:space:]]}"}"
    fi
    if [ -n "$_fd_val" ]; then
        FRONTEND_DIR="$_fd_val"
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
        # 去外层引号 — single OR double 二选一（不是两轮都剥）。
        # v0.1.21 同 frontend_dir parser 修补。
        case "$_ef_val" in
            \'*\') _ef_val="${_ef_val#\'}"; _ef_val="${_ef_val%\'}" ;;
            \"*\") _ef_val="${_ef_val#\"}"; _ef_val="${_ef_val%\"}" ;;
        esac
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
PKG_MGR=""   # 默认空；真探测分支会按 lockfile 检测后填入
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

    # ---- package manager 检测（v0.1.20）— 按 lockfile 自动选 ----
    # 在 ${FRONTEND_DIR} 内查 lockfile 决定 manager；优先级：
    #   pnpm-lock.yaml > bun.lock(b) > yarn.lock > package-lock.json > 默认 pnpm
    # 选完用对应 manager 跑 version_check，避免 pnpm 用户写 yarn 项目时 silent skip。
    PKG_MGR="pnpm"   # fallback 默认（保 backward-compat）
    _fd_abs="${REPO_ROOT}/${FRONTEND_DIR}"
    if [ -f "${_fd_abs}/pnpm-lock.yaml" ]; then
        PKG_MGR="pnpm"
    elif [ -f "${_fd_abs}/bun.lock" ] || [ -f "${_fd_abs}/bun.lockb" ]; then
        PKG_MGR="bun"
    elif [ -f "${_fd_abs}/yarn.lock" ]; then
        PKG_MGR="yarn"
    elif [ -f "${_fd_abs}/package-lock.json" ]; then
        PKG_MGR="npm"
    fi

    # pnpm（legacy 字段 — 始终探 pnpm 命令存在性，与 PKG_MGR 解耦）
    if command -v pnpm >/dev/null 2>&1; then
        PNPM_RC=0
    else
        PNPM_RC=1
    fi

    # 检测到的 PKG_MGR 是否可执行
    PKG_MGR_RC=1
    if command -v "$PKG_MGR" >/dev/null 2>&1; then
        PKG_MGR_RC=0
    fi

    # node
    if command -v node >/dev/null 2>&1; then
        NODE_RC=0
    else
        NODE_RC=1
    fi

    # framework_installed: ${FRONTEND_DIR}/node_modules/@playwright/test 目录存在
    if [ -d "${_fd_abs}/node_modules/@playwright/test" ]; then
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

    # version_check: <PKG_MGR> exec/dlx/x playwright --version 在 5s 内退 0 + 输出含版本号
    # 各 manager 调 dependency CLI 的语法不同，用 case 分流。
    #
    # v0.1.21 codex review fix #1（CWE-78 命令注入修补）：
    # 原版用 `sh -c "cd '${_fd_abs}' && ..."` 字符串插值；当 yaml `frontend_dir`
    # 含单引号 + 磁盘上真存在该路径时（含恶意 yaml 的 clone 场景）会执行任意命
    # 令。改用 `bash -c '... "$1" ...' _ "$_fd_abs"` 把路径作位置参 $1 传入，
    # 单引号包裹的 bash 命令字符串内**不**做变量插值，shell 元字符无法逃逸。
    VERSION_RC=1
    if [ "$FRAMEWORK_RC" = "0" ] && [ "$PKG_MGR_RC" = "0" ]; then
        case "$PKG_MGR" in
            pnpm)
                PW_OUT="$(run_with_timeout 5 bash -c 'cd "$1" && pnpm exec playwright --version' _ "$_fd_abs" 2>/dev/null || true)"
                ;;
            yarn)
                # yarn classic: `yarn exec`；yarn berry: 也支持 `yarn exec`（berry 还有 `yarn dlx`）
                PW_OUT="$(run_with_timeout 5 bash -c 'cd "$1" && yarn exec playwright --version' _ "$_fd_abs" 2>/dev/null || true)"
                ;;
            npm)
                # npm 用 npx 或 `npm exec`；npx 兼容性更广
                PW_OUT="$(run_with_timeout 5 bash -c 'cd "$1" && npx playwright --version' _ "$_fd_abs" 2>/dev/null || true)"
                ;;
            bun)
                PW_OUT="$(run_with_timeout 5 bash -c 'cd "$1" && bun x playwright --version' _ "$_fd_abs" 2>/dev/null || true)"
                ;;
            *)
                PW_OUT=""
                ;;
        esac
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
#
# v0.1.21 codex review fix #2（JSON 转义修补）：
# 原版用 printf '..."%s"...' 直接插字符串字段，当 yaml 含裸双引号 / 反斜杠 /
# 换行（如 `e2e_framework: 'Cypress "v13"'`）会输出破坏的 JSON，下游
# `json.loads` 抛 JSONDecodeError 让 run-test.md §0.1 解析炸。改用 python3
# 标准 JSON encoder，所有字符串字段透过 sys.argv 传入，自动按 JSON spec 转义
# 控制字符 + `"` + `\` + 非 ASCII。
python3 -c '
import json, sys
data = {
    "docker": sys.argv[1] == "true",
    "pnpm": sys.argv[2] == "true",
    "node": sys.argv[3] == "true",
    "playwright": sys.argv[4] == "true",
    "framework_installed": sys.argv[5] == "true",
    "chromium_installed": sys.argv[6] == "true",
    "runtime_ready": sys.argv[7] == "true",
    "all_available": sys.argv[8] == "true",
    "frontend_dir": sys.argv[9],
    "e2e_framework": sys.argv[10],
    "package_manager": sys.argv[11],
    "reason": sys.argv[12],
}
print(json.dumps(data, ensure_ascii=False))
' \
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
    "$PKG_MGR" \
    "$FINAL_REASON"

exit 0

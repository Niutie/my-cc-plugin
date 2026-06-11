#!/usr/bin/env bash
# read_harness_config — sourced by harness bash scripts to access harness-project-config.yaml.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/read_harness_config.sh"
#   echo "$HARNESS_ARTIFACTS_ROOT"
#   custom="$(read_harness_config_field some_extra_key 'default_val')"
#
# Exposed:
#   - read_harness_config_field <key> [default]   — function (top-level scalar OR extra map scalar)
#   - HARNESS_REPO_ROOT                            — env var, absolute path to repo root
#   - HARNESS_CONFIG_PATH                          — env var, absolute path to yaml file
#   - HARNESS_ARTIFACTS_ROOT                       — env var, absolute artifacts dir path
#   - HARNESS_SPRINT_STATUS_PATH                   — env var, absolute sprint-status.yaml path
#   - HARNESS_DEFERRED_WORK_PATH                   — env var, absolute deferred-work.md path
#
# Fallback: missing field / file → use hardcoded default + stderr WARN. Aligned
# with eval_test_stage_triggers.sh fail_open_default precedent.
#
# Note on `set` flags:
#   This file is `source`d by other scripts. We do NOT enable `set -e` here
#   (would force-exit caller on awk/grep miss inside fallback paths). We DO
#   enable `pipefail` for the fallback awk|head|sed pipelines below — caller
#   inherits this; scripts that intentionally rely on no-pipefail should
#   `set +o pipefail` after sourcing.

set -o pipefail

# Compute repo root from this file's location: 3 levels up from .claude/harness/scripts/
# _RHC_SCRIPT_DIR 在 source 期解析为绝对路径，且**不进末尾 unset 清单**：
# read_harness_config_field 在调用期（可能远晚于 source、caller 已 cd 走）仍要靠它
# 定位 harness_config.py。issue #7：前身 _RHC_THIS 在 source 末被 unset，caller
# `set -u` 下任何 post-source 调用直接 'unbound variable' exit 1。
#
# 自身路径解析三级兜底（v0.1.38 F1）：bash → BASH_SOURCE；zsh（init/upgrade md
# 协议块经 Claude Code Bash tool 直接 source 本文件，而该 tool 继承用户 login
# shell —— macOS 默认 zsh，BASH_SOURCE 为空，旧实现把 repo root 误算成 cwd/../../..）
# → `${(%):-%x}` prompt 展开（藏进 eval 字符串，bash 3.2 解析器不可见）；再兜底 $0。
_RHC_SELF="${BASH_SOURCE[0]:-}"
if [ -z "$_RHC_SELF" ] && [ -n "${ZSH_VERSION:-}" ]; then
    eval '_RHC_SELF="${(%):-%x}"'
fi
[ -z "$_RHC_SELF" ] && _RHC_SELF="$0"
_RHC_SCRIPT_DIR="$(cd "$(dirname "$_RHC_SELF")" && pwd)"
HARNESS_REPO_ROOT="$(cd "$_RHC_SCRIPT_DIR/../../.." && pwd)"
HARNESS_CONFIG_PATH="$HARNESS_REPO_ROOT/.claude/harness/harness-project-config.yaml"

_DEFAULT_HARNESS_ARTIFACTS_ROOT="_bmad-output/implementation-artifacts"

# strip surrounding quotes + inline comment from yaml scalar value
# review #20：与 harness_config.py _strip_yaml_scalar（SoT）行为对齐——
#   (1) 去 inline 注释：非引号 scalar 截到第一个 #；引号 scalar 找 closing 引号、
#       其后是 # 注释才截（引号内 # 保留）
#   (2) 引号剥离改成 single OR double 二选一的成对剥离（不两轮都剥；
#       v0.1.21 check_test_harness_env.sh 同款修补）
_rhc_strip_yaml_value() {
    local val="$1"
    # 去首尾空白
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    # 去 inline 注释
    case "$val" in
        \'*|\"*)
            local _q="${val:0:1}"
            local _rest="${val:1}"
            if [ "${_rest#*"$_q"}" != "$_rest" ]; then
                local _body="${_rest%%"$_q"*}"   # closing 引号前的内容
                local _tail="${_rest#*"$_q"}"    # closing 引号后的内容
                _tail="${_tail#"${_tail%%[![:space:]]*}"}"
                case "$_tail" in
                    '#'*) val="${_q}${_body}${_q}" ;;
                esac
            fi
            ;;
        *)
            val="${val%%#*}"
            val="${val%"${val##*[![:space:]]}"}"
            ;;
    esac
    # 去外层引号 — 成对剥离（single OR double 二选一）
    case "$val" in
        \'*\') val="${val#\'}"; val="${val%\'}" ;;
        \"*\") val="${val#\"}"; val="${val%\"}" ;;
    esac
    printf '%s' "$val"
}

# read_harness_config_field <key> [default]
# 查 yaml 的顶层 scalar；命中失败查 extra: 二级 scalar；都失败返 default。
#
# v0.1.27+ 实现：直接 shell-out 调 harness_config.py --get（消除 4-way YAML 解析
# 重复 — 详 codex review 2026-05-09）。Python 不在场或 yaml 损坏时退化到内联
# awk 兜底（保证 read_harness_config.sh 自身仍 self-contained 可用，
# 即便 harness_config.py 损坏）。
read_harness_config_field() {
    # set -u caller 防御（issue #7 同族）：无 key 调用 / HARNESS_CONFIG_PATH
    # 被外部 unset 时降级回 default，而非 unbound variable 杀死 caller shell。
    local key="${1:-}"
    local default="${2:-}"
    if [ -z "$key" ]; then
        echo "WARN [read_harness_config]: read_harness_config_field called without key" >&2
        echo "$default"
        return 0
    fi
    if [ ! -f "${HARNESS_CONFIG_PATH:-}" ]; then
        echo "$default"
        return 0
    fi
    # Primary path: Python harness_config.py（SoT）
    # ${_RHC_SCRIPT_DIR:-} 双保险：万一全局被外部 unset，空串令 -f 测试失败 →
    # 安全退化到下方 awk fallback，而非 set -u 崩溃（issue #7 的 bug class）。
    local _harness_config_py="${_RHC_SCRIPT_DIR:-}/harness_config.py"
    if command -v python3 >/dev/null 2>&1 && [ -f "$_harness_config_py" ]; then
        # review #19：捕获 python 退出码——运行期失败（文件截断 / 坏 pyenv shim /
        # 权限异常）时不再无条件返回空串，而是 WARN + fall through 到下方 awk
        # 兜底，兑现头注释「harness_config.py 损坏时退化到内联 awk」的契约。
        # 成功路径原样直返（含合法空值），与失败可区分。
        local val
        if val="$(HARNESS_CONFIG_PATH="$HARNESS_CONFIG_PATH" \
               python3 "$_harness_config_py" --get "$key" \
                       --default "$default" --quiet 2>/dev/null)"; then
            printf '%s\n' "$val"
            return 0
        fi
        echo "WARN [read_harness_config]: harness_config.py failed for key '$key' — falling back to inline awk parser" >&2
    fi
    # Fallback: inline awk parser (kept verbatim from pre-0.1.27 implementation;
    # only triggered when python3 missing or harness_config.py损坏).
    local val=""
    val="$(grep -E "^${key}:[[:space:]]" "$HARNESS_CONFIG_PATH" 2>/dev/null \
            | head -1 \
            | sed -E "s/^${key}:[[:space:]]+//")"
    if [ -z "$val" ]; then
        val="$(awk -v k="$key" '
            /^extra:/ { in_extra=1; next }
            in_extra && /^[^[:space:]#]/ { in_extra=0 }
            in_extra {
                pat = "^[[:space:]]+" k ":[[:space:]]"
                if ($0 ~ pat) {
                    sub("^[[:space:]]+" k ":[[:space:]]+", "")
                    print
                    exit
                }
            }
        ' "$HARNESS_CONFIG_PATH" 2>/dev/null)"
    fi
    # 先 strip 再判空：`key: ''`（显式空引号值）经 strip 后为空 → 返 default，
    # 与 harness_config.py SoT 行为一致（review #20 漂移收口）。
    if [ -n "$val" ]; then
        val="$(_rhc_strip_yaml_value "$val")"
    fi
    if [ -z "$val" ]; then
        echo "$default"
        return 0
    fi
    printf '%s\n' "$val"
}

# Auto-resolve key paths into env vars (relative artifacts_root → absolute)
_rhc_artifacts_rel="$(read_harness_config_field artifacts_root '')"
if [ -z "$_rhc_artifacts_rel" ]; then
    echo "WARN [read_harness_config]: artifacts_root not set, using default '$_DEFAULT_HARNESS_ARTIFACTS_ROOT'" >&2
    _rhc_artifacts_rel="$_DEFAULT_HARNESS_ARTIFACTS_ROOT"
fi

HARNESS_ARTIFACTS_ROOT="$HARNESS_REPO_ROOT/$_rhc_artifacts_rel"
HARNESS_SPRINT_STATUS_PATH="$HARNESS_ARTIFACTS_ROOT/sprint-status.yaml"
HARNESS_DEFERRED_WORK_PATH="$HARNESS_ARTIFACTS_ROOT/deferred-work.md"

# Cleanup source-time-only vars (NOT _RHC_SCRIPT_DIR — function needs it at call time)
unset _rhc_artifacts_rel _DEFAULT_HARNESS_ARTIFACTS_ROOT _RHC_SELF

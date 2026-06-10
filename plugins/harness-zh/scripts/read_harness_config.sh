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
_RHC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_REPO_ROOT="$(cd "$_RHC_SCRIPT_DIR/../../.." && pwd)"
HARNESS_CONFIG_PATH="$HARNESS_REPO_ROOT/.claude/harness/harness-project-config.yaml"

_DEFAULT_HARNESS_ARTIFACTS_ROOT="_bmad-output/implementation-artifacts"

# strip surrounding quotes + inline comment from yaml scalar value
_rhc_strip_yaml_value() {
    local val="$1"
    # 去外层引号
    val="${val#\'}"; val="${val%\'}"
    val="${val#\"}"; val="${val%\"}"
    # 去尾随空白
    val="${val%"${val##*[![:space:]]}"}"
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
        local val
        val="$(HARNESS_CONFIG_PATH="$HARNESS_CONFIG_PATH" \
               python3 "$_harness_config_py" --get "$key" \
                       --default "$default" --quiet 2>/dev/null || true)"
        printf '%s\n' "$val"
        return 0
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
    if [ -z "$val" ]; then
        echo "$default"
        return 0
    fi
    _rhc_strip_yaml_value "$val"
    echo
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
unset _rhc_artifacts_rel _DEFAULT_HARNESS_ARTIFACTS_ROOT

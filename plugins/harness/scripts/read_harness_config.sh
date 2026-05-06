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

# Compute repo root from this file's location: 3 levels up from .claude/harness/scripts/
_RHC_THIS="${BASH_SOURCE[0]}"
HARNESS_REPO_ROOT="$(cd "$(dirname "$_RHC_THIS")/../../.." && pwd)"
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
read_harness_config_field() {
    local key="$1"
    local default="${2:-}"
    if [ ! -f "$HARNESS_CONFIG_PATH" ]; then
        echo "$default"
        return 0
    fi
    local val=""
    # 顶层 scalar
    val="$(grep -E "^${key}:[[:space:]]" "$HARNESS_CONFIG_PATH" 2>/dev/null \
            | head -1 \
            | sed -E "s/^${key}:[[:space:]]+//")"
    if [ -z "$val" ]; then
        # extra: 二级
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

# Cleanup local var (not exported)
unset _rhc_artifacts_rel _RHC_THIS _DEFAULT_HARNESS_ARTIFACTS_ROOT

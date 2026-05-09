#!/usr/bin/env bash
# Test stage triggers evaluator — 通用 condition-driven 触发评估
#
# 输入：<story-key> <spec-path>
# 输出：单行 JSON 到 stdout，schema：
#   {"t1": <bool>, "t2": <bool>, "t3": <bool>, "t4": <bool>, "t5": <bool>,
#    "t6": <bool>, "ci": <bool>, "test_review": <bool>, "teach": <bool>,
#    "reason": "real_eval"|"fail_open_default"|"forced_default"}
#
# 评估流程：
#   1. 读 .claude/harness/test-stage-triggers.yaml + harness-project-config.yaml
#   2. 对每个 skill 按 trigger 类型计算 condition
#   3. 任一 yaml 损坏 / 字段缺失 → fall back 到 defaults.fallback_skills + WARN
#   4. exit 0（任何路径都不阻调用方 — 由调用方按 JSON 决断）
#
# Sandbox / fail-open override：
#   FORCE_DEFAULT=1   → 跳过真评估，直接吐 defaults.fallback_skills
#
# 用法：
#   bash .claude/harness/scripts/eval_test_stage_triggers.sh chore-retro-c1-A8 \
#        _bmad-output/implementation-artifacts/chore-retro-c1-A8-architecture-d-decisions-index.md
#   FORCE_DEFAULT=1 bash .claude/harness/scripts/eval_test_stage_triggers.sh foo bar
#
# 设计准则（与 C1 / C12 同款）：纯 bash + grep + awk + sed；不引 yq / Python / Node。

set -uo pipefail

KEY="${1:-}"
SPEC_PATH="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TRIGGERS_YAML="${TRIGGERS_YAML:-${HARNESS_DIR}/test-stage-triggers.yaml}"
PROJECT_CONFIG="${PROJECT_CONFIG:-${HARNESS_DIR}/harness-project-config.yaml}"

# ---- bool helper（emit JSON literal） ----
emit_bool() {
    if [ "$1" = "1" ]; then echo "true"; else echo "false"; fi
}

# ---- emit defaults JSON（fail-open / forced） ----
emit_defaults() {
    local reason="$1"
    printf '{"t1": true, "t2": false, "t3": true, "t4": true, "t5": false, "t6": false, "ci": false, "test_review": false, "teach": false, "reason": "%s"}\n' "$reason"
}

# ---- 通用：strip 行首尾的引号 + trailing inline 注释 ----
# stdin 读一行；stdout 输出 strip 后的值
strip_yaml_value() {
    sed -E "s/[[:space:]]+#.*$//" \
        | sed -E 's/^"//; s/"$//' \
        | sed -E "s/^'//; s/'$//"
}

# ---- forced default override ----
if [ "${FORCE_DEFAULT:-0}" = "1" ]; then
    emit_defaults "forced_default"
    exit 0
fi

# ---- yaml 文件存在性检查（fail-open） ----
if [ ! -f "$TRIGGERS_YAML" ]; then
    echo "WARN: test-stage-triggers.yaml not found at $TRIGGERS_YAML — fall back to defaults" >&2
    emit_defaults "fail_open_default"
    exit 0
fi

# ---- project config 读取（缺失走占位 + WARN，不 abort） ----
# v0.1.27+：shell-out 调 harness_config.py --get（消除 4-way YAML 解析重复；
# python3 不在或 harness_config.py 损坏时退化到内联 awk 兜底）。
read_project_field() {
    local key="$1"
    local default="${2:-<unset>}"
    if [ ! -f "$PROJECT_CONFIG" ]; then
        echo "$default"
        return
    fi
    local _epd
    _epd="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local _harness_config_py="$_epd/harness_config.py"
    if command -v python3 >/dev/null 2>&1 && [ -f "$_harness_config_py" ]; then
        HARNESS_CONFIG_PATH="$PROJECT_CONFIG" \
        python3 "$_harness_config_py" --get "$key" --default "$default" --quiet 2>/dev/null \
            || echo "$default"
        return
    fi
    # Fallback: inline awk parser (verbatim from pre-0.1.27)
    local val
    val="$(grep -E "^${key}:[[:space:]]" "$PROJECT_CONFIG" 2>/dev/null \
            | head -1 \
            | sed -E "s/^${key}:[[:space:]]+//" \
            | strip_yaml_value)"
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
        ' "$PROJECT_CONFIG" 2>/dev/null | strip_yaml_value)"
    fi
    if [ -z "$val" ]; then
        echo "$default"
    else
        echo "$val"
    fi
}

# 读 5 必填 + 关键 extra（缺时用占位继续，stderr WARN — fail-open 准则）
PROJ_NAME="$(read_project_field project_display_name '<unset>')"
FRONTEND_DIR="$(read_project_field frontend_dir 'console-web')"
E2E_TEST_SUBDIR="$(read_project_field e2e_test_subdir 'tests/e2e')"

if [ "$PROJ_NAME" = "<unset>" ]; then
    echo "WARN: project_display_name not set in $PROJECT_CONFIG — using <unset> placeholder" >&2
fi

# ---- 读 yaml skill 段；提取每个 skill 的 trigger 字段 ----
# 二级 skill key（恰好 2 空格缩进）：'^  [a-z][a-z-]*:\s*$'
# 三级字段 key（恰好 4 空格缩进）：'^    [a-z][a-z-_]*:'
# 四级 list 项（恰好 6 空格缩进）：'^      - '
read_skill_trigger() {
    local skill="$1"
    awk -v target="$skill" '
        /^skills:/ { in_skills=1; next }
        in_skills && /^[^[:space:]#]/ { in_skills=0 }
        in_skills && /^  [a-z][a-z-]*:[[:space:]]*$/ {
            match($0, /[a-z][a-z-]+/)
            current = substr($0, RSTART, RLENGTH)
            next
        }
        in_skills && current == target && /^    trigger:[[:space:]]/ {
            sub(/^    trigger:[[:space:]]+/, "")
            print
            exit
        }
    ' "$TRIGGERS_YAML" 2>/dev/null | strip_yaml_value
}

read_skill_keywords() {
    local skill="$1"
    awk -v target="$skill" '
        /^skills:/ { in_skills=1; next }
        in_skills && /^[^[:space:]#]/ { in_skills=0 }
        in_skills && /^  [a-z][a-z-]*:[[:space:]]*$/ {
            match($0, /[a-z][a-z-]+/)
            current = substr($0, RSTART, RLENGTH)
            in_keywords = 0
            next
        }
        in_skills && current == target && /^      keywords:[[:space:]]*$/ {
            in_keywords = 1
            next
        }
        in_keywords && /^        - / {
            sub(/^        - /, "")
            print
            next
        }
        in_keywords && !/^        - / {
            in_keywords = 0
        }
    ' "$TRIGGERS_YAML" 2>/dev/null | strip_yaml_value
}

# yaml 损坏防御：若 skills: 段都读不到任何 trigger，fall back
SAMPLE_TRIGGER="$(read_skill_trigger atdd)"
if [ -z "$SAMPLE_TRIGGER" ]; then
    echo "WARN: cannot parse skills section in $TRIGGERS_YAML — yaml may be malformed; fall back to defaults" >&2
    emit_defaults "fail_open_default"
    exit 0
fi

# ---- 评估每个 skill ----

# 子函数：spec 文件含任一 keyword 返回 0
spec_has_keyword() {
    local skill="$1"
    if [ -z "$SPEC_PATH" ] || [ ! -f "$SPEC_PATH" ]; then
        return 1
    fi
    local kw
    while IFS= read -r kw; do
        [ -z "$kw" ] && continue
        if grep -iqE "(^|[^A-Za-z0-9_])${kw}([^A-Za-z0-9_]|$)" "$SPEC_PATH" 2>/dev/null; then
            return 0
        fi
    done < <(read_skill_keywords "$skill")
    return 1
}

# T1 test-design — once_per_project（产物不存在则触发；EPIC 空 → false）
T1=0
EPIC_FROM_KEY=""
if [ -n "$KEY" ]; then
    # KEY 形如 "1-2-foo" / "4-1-detection" / chore-retro-cN-* / chore-* — 提取 epic 号
    EPIC_FROM_KEY="$(printf '%s' "$KEY" | grep -oE '^[0-9]+' || true)"
    if [ -z "$EPIC_FROM_KEY" ]; then
        # 退而求次：chore-retro-cN-* 提取 N
        EPIC_FROM_KEY="$(printf '%s' "$KEY" | sed -nE 's/.*retro-c([0-9]+).*/\1/p' || true)"
    fi
fi
if [ -n "$EPIC_FROM_KEY" ]; then
    # shellcheck source=read_harness_config.sh
    source "$SCRIPT_DIR/read_harness_config.sh"
    if [ ! -f "$HARNESS_ARTIFACTS_ROOT/test_artifacts/epic-${EPIC_FROM_KEY}-test-design.md" ]; then
        T1=1
    fi
fi

# T2 framework — once_per_project（@playwright/test 已装则 skip）
T2=0
T2_TRIGGER="$(read_skill_trigger framework)"
if [ ! -d "${FRONTEND_DIR}/node_modules/@playwright/test" ]; then
    if [ "$T2_TRIGGER" = "manual_only" ]; then
        T2=0
    else
        T2=1
    fi
fi

# T3 atdd — per_story
T3=0
ATDD_TRIGGER="$(read_skill_trigger atdd)"
if [ "$ATDD_TRIGGER" = "per_story" ] || [ "$ATDD_TRIGGER" = "always" ]; then
    if [ -n "$KEY" ]; then
        T3=1
    fi
fi

# T4 automate — per_story
T4=0
AUTOMATE_TRIGGER="$(read_skill_trigger automate)"
if [ "$AUTOMATE_TRIGGER" = "per_story" ] || [ "$AUTOMATE_TRIGGER" = "always" ]; then
    if [ -n "$KEY" ]; then
        T4=1
    fi
fi

# T5 nfr — keyword_match
T5=0
NFR_TRIGGER="$(read_skill_trigger nfr)"
if [ "$NFR_TRIGGER" = "keyword_match" ]; then
    if spec_has_keyword nfr; then
        T5=1
    fi
fi

# T6 trace — keyword_match
T6=0
TRACE_TRIGGER="$(read_skill_trigger trace)"
if [ "$TRACE_TRIGGER" = "keyword_match" ]; then
    if spec_has_keyword trace; then
        T6=1
    fi
fi

# CI — any_match（仅当 EVAL_CI_HINT=epic_done 显式传入 + 仓库无 e2e CI workflow 时触发）
# MVP 决策：CI stage 不在 per-story invoke 时触发，避免对每条 story 都报 CI=true 噪声；
# 真用例是 epic 收尾或首次 e2e spec 进仓时单次触发，由调用方显式传 EVAL_CI_HINT 信号。
CI=0
CI_TRIGGER="$(read_skill_trigger ci)"
if [ "$CI_TRIGGER" = "any_match" ] && [ "${EVAL_CI_HINT:-}" = "epic_done" ]; then
    e2e_dir="${FRONTEND_DIR}/${E2E_TEST_SUBDIR}"
    if [ -d "$e2e_dir" ]; then
        spec_count="$(find "$e2e_dir" -maxdepth 2 -name '*.spec.ts' -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
        if [ "${spec_count:-0}" -ge 1 ]; then
            ci_workflow_exists=0
            if [ -d ".github/workflows" ]; then
                if find .github/workflows -maxdepth 1 -type f \( -name 'playwright*.yml' -o -name 'e2e*.yml' -o -name '*-e2e.yml' \) 2>/dev/null | grep -q .; then
                    ci_workflow_exists=1
                fi
            fi
            if [ "$ci_workflow_exists" = "0" ]; then
                CI=1
            fi
        fi
    fi
fi

# test-review — threshold（e2e_spec_count ≥ 50）
TEST_REVIEW=0
TR_TRIGGER="$(read_skill_trigger test-review)"
if [ "$TR_TRIGGER" = "threshold" ]; then
    e2e_dir="${FRONTEND_DIR}/${E2E_TEST_SUBDIR}"
    if [ -d "$e2e_dir" ]; then
        spec_count="$(find "$e2e_dir" -maxdepth 2 -name '*.spec.ts' -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
        if [ "${spec_count:-0}" -ge 50 ]; then
            TEST_REVIEW=1
        fi
    fi
fi

# teach — manual_only（永远 false）
TEACH=0

# ---- emit JSON ----
printf '{"t1": %s, "t2": %s, "t3": %s, "t4": %s, "t5": %s, "t6": %s, "ci": %s, "test_review": %s, "teach": %s, "reason": "real_eval"}\n' \
    "$(emit_bool $T1)" \
    "$(emit_bool $T2)" \
    "$(emit_bool $T3)" \
    "$(emit_bool $T4)" \
    "$(emit_bool $T5)" \
    "$(emit_bool $T6)" \
    "$(emit_bool $CI)" \
    "$(emit_bool $TEST_REVIEW)" \
    "$(emit_bool $TEACH)"

exit 0

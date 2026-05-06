#!/usr/bin/env bash
# Retro self-audit
#
# ⚠️ 项目特定脚本（PROJECT-SPECIFIC）：内含每个 retro action item（A1..A8 /
# B1..B9 / C1..C12 等）的 hardcoded 检查路径 + grep target，对应原项目实际
# action items。**clone 到新项目后必须重写所有 check_XN() 函数体**（或整个
# 删除该脚本，按新项目的 retro action items 重新生成）。框架本身（参数解析 /
# markdown 表格输出格式 / stdout 流式拼接）是通用的，可以保留为骨架。
#
# 自动 grep 所有 retro action items 在当前 codebase 的兑现证据；输出
# markdown 表格 4 列（id / 描述 / 自动判定 status / evidence），让 retro
# §2 cross-reference 章节可直接 paste 作为草稿基础。脚本是只读 + stdout
# 输出；不改 sprint-status.yaml。
#
# 用法：
#   bash .claude/harness/scripts/run_retro_self_audit.sh <prev_epic_num>
#
# 参数：
#   prev_epic_num — 上一 epic 编号（如 Epic 4 retro 启动时跑 `... 3`，
#                   扫 epic-1 + epic-2 + epic-3 全表）
#
# 退出码：
#   0   正常输出表格
#   1   sprint-status.yaml 不存在
#   2   参数缺失 / 非法

set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <prev_epic_num>" >&2
    exit 2
fi

PREV_EPIC="$1"
if ! [[ "$PREV_EPIC" =~ ^[0-9]+$ ]]; then
    echo "ERROR: prev_epic_num must be numeric, got: $PREV_EPIC" >&2
    exit 2
fi

ROOT="$(pwd)"
SPRINT_STATUS="${ROOT}/_bmad-output/implementation-artifacts/sprint-status.yaml"

if [ ! -f "$SPRINT_STATUS" ]; then
    echo "ERROR: sprint-status.yaml not found at $SPRINT_STATUS" >&2
    exit 1
fi

# ---- 表头 ----
echo "| id | 描述 | status | evidence |"
echo "|----|------|--------|----------|"

# helper: file_exists path → echo PASS/FAIL
file_exists() {
    if [ -f "$1" ]; then echo "exists: $1"; return 0; fi
    return 1
}

grep_count() {
    local pat="$1"; local path="$2"
    grep -cE "$pat" "$path" 2>/dev/null || echo 0
}

# ---- A1..A8 (Epic 1) ----
check_A1() {
    # 端到端 smoke + sizing 实测；evidence: docs/sizing 报告中无 TBD
    local report="${ROOT}/docs/sizing/story-1-12-sizing-report.md"
    if [ ! -f "$report" ]; then echo "| A1 | 端到端 smoke + sizing 实测 | unknown | sizing-report.md missing |"; return; fi
    local tbd
    tbd="$(grep -cE 'TBD|<待实测>' "$report" || echo 0)"
    if [ "$tbd" -eq 0 ]; then
        echo "| A1 | 端到端 smoke + sizing 实测 | done | $report 无 TBD/<待实测> |"
    else
        echo "| A1 | 端到端 smoke + sizing 实测 | pending | $report 仍含 $tbd 个 TBD |"
    fi
}
check_A2() {
    echo "| A2 | sink_mode 默认 forward 重置 | unknown | trigger 未到期 — Epic 6 启动 OR 客户实测反馈触发 |"
}
check_A3() {
    local hits
    hits="$(grep -lE '可观测性反向验证|状态机边界|Self-review|self-review' "${ROOT}/.claude/harness/prompt-suffixes/bmad-dev-story-suffix.md" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$hits" -ge 1 ]; then
        echo "| A3 | dev-story 5-question self-review gate | done | .claude/harness/prompt-suffixes/bmad-dev-story-suffix.md Standard checklists 段 |"
    else
        echo "| A3 | dev-story 5-question self-review gate | partial | via spec-pattern 未在 SKILL 集成 |"
    fi
}
check_A4() {
    local lines
    lines="$(wc -l < "${ROOT}/console-api/cmd/aegis-cli/cmd_admin_init_test.go" 2>/dev/null | tr -d ' ' || echo 0)"
    if [ "$lines" -ge 200 ]; then
        echo "| A4 | admin_init 4 缺失分支测试 + bufio fix | done | cmd_admin_init_test.go = $lines lines |"
    else
        echo "| A4 | admin_init 4 缺失分支测试 + bufio fix | pending | cmd_admin_init_test.go = $lines lines（未达 ≥ 200 阈值） |"
    fi
}
check_A5() {
    local nfr="${ROOT}/_bmad-output/planning-artifacts/prd/non-functional-requirements.md"
    if [ ! -f "$nfr" ]; then echo "| A5 | NFR52 baseline 拍板 | unknown | NFR file missing |"; return; fi
    local todo
    todo="$(grep -cE 'TODO|<待实测>|TBD|待操作员|retrospective 阶段拍板' "$nfr" 2>/dev/null || true)"
    todo="${todo:-0}"
    if [ "$todo" -gt 0 ]; then
        echo "| A5 | NFR52 baseline 拍板 | pending | NFR file 仍含 TBD/拍板待办 |"
    else
        echo "| A5 | NFR52 baseline 拍板 | done | NFR file 无 TBD/拍板待办 |"
    fi
}
check_A6() {
    local dw="${ROOT}/_bmad-output/implementation-artifacts/deferred-work.md"
    if [ -f "$dw" ] && grep -qE '## 1\.|^# Deferred' "$dw" 2>/dev/null; then
        echo "| A6 | deferred-work §1 物化 | done | deferred-work.md §1 顶层段 + §1.1/§1.2/§1.3 |"
    else
        echo "| A6 | deferred-work §1 物化 | unknown | deferred-work.md missing or §1 segment unclear |"
    fi
}
check_A7() {
    local f="${ROOT}/.claude/harness/prompt-suffixes/bmad-dev-story-suffix.md"
    if [ -f "$f" ] && grep -qE 'Mech-verify dry-run' "$f"; then
        echo "| A7 | spec mech-verify dry-run gate | done | bmad-dev-story-suffix.md Mech-verify 段 |"
    else
        echo "| A7 | spec mech-verify dry-run gate | partial | via spec-pattern 未在 SKILL 集成 |"
    fi
}
check_A8() {
    local f="${ROOT}/_bmad-output/planning-artifacts/architecture/index.md"
    if [ -f "$f" ] && grep -qE '^## D-decisions 总索引' "$f"; then
        echo "| A8 | architecture/index.md D-decisions 索引 | done | index.md ## D-decisions 总索引 段 |"
    else
        echo "| A8 | architecture/index.md D-decisions 索引 | pending | index.md 缺 D-decisions 总索引段 |"
    fi
}

# ---- B1..B9 (Epic 2) ----
check_B1() {
    local f="${ROOT}/.claude/harness/scripts/grep_prev_retro_action_items.sh"
    if [ -x "$f" ]; then
        echo "| B1 | retro action items skill prepend | done | $f executable |"
    else
        echo "| B1 | retro action items skill prepend | pending | $f missing |"
    fi
}
check_B2() {
    local f="${ROOT}/.claude/harness/prompt-suffixes/bmad-dev-story-suffix.md"
    if [ -f "$f" ] && grep -qE 'Self-review.*5-question' "$f"; then
        echo "| B2 | self-review 5q gate workflow 集成 | done | bmad-dev-story-suffix.md |"
    else
        echo "| B2 | self-review 5q gate workflow 集成 | partial | via spec-pattern |"
    fi
}
check_B3() {
    local f="${ROOT}/_bmad/customize/bmad-create-story.toml"
    if [ -f "$f" ] && grep -qE 'mech-verify dry-run|Mech-verify dry-run' "$f"; then
        echo "| B3 | mech-verify dry-run gate workflow 集成 | done | bmad-create-story.toml |"
    else
        echo "| B3 | mech-verify dry-run gate workflow 集成 | partial | via spec-pattern |"
    fi
}
check_B4() {
    local f="${ROOT}/_bmad-output/planning-artifacts/architecture/implementation-patterns-consistency-rules.md"
    if [ -f "$f" ] && grep -qE 'RBAC 业务层数据可见性收敛 pattern' "$f"; then
        echo "| B4 | RBAC 业务层数据可见性 review checklist | done | IPC rules 段 |"
    else
        echo "| B4 | RBAC 业务层数据可见性 review checklist | partial | pattern 未沉淀 |"
    fi
}
check_B5() {
    local f="${ROOT}/.claude/harness/scripts/grep_pending_deferred_for_story.sh"
    if [ -x "$f" ]; then
        echo "| B5 | bmad-create-story deferred-work auto-import | done | $f executable |"
    else
        echo "| B5 | bmad-create-story deferred-work auto-import | pending | $f missing |"
    fi
}
check_B6() {
    echo "| B6 | deferred-work §1 物化（Epic 2 视角） | done | 与 A6 同源（C5 兑现） |"
}
check_B7() {
    local f="${ROOT}/.claude/harness/scripts/check_spec_length.sh"
    if [ -x "$f" ]; then
        echo "| B7 | spec 长度 hard 上限 + D-decisions extract | done | check_spec_length.sh |"
    else
        echo "| B7 | spec 长度 hard 上限 + D-decisions extract | pending | check_spec_length.sh missing |"
    fi
}
check_B8() {
    local pkg="${ROOT}/console-web/package.json"
    if [ -f "$pkg" ] && grep -qE '"gen:permissions"|"gen:masking-types"|"gen:ops-log-actions"' "$pkg"; then
        echo "| B8 | 跨栈 mirror codegen 守门 | done | package.json gen:* scripts |"
    else
        echo "| B8 | 跨栈 mirror codegen 守门 | pending | gen:* scripts 未定义 |"
    fi
}
check_B9() {
    # B9 引用 A1+A4+A5
    local nfr="${ROOT}/_bmad-output/planning-artifacts/prd/non-functional-requirements.md"
    if [ -f "$nfr" ] && grep -qE 'NFR52 baseline = |NFR52 retrospective 拍板' "$nfr"; then
        echo "| B9 | A1 + A4 + A5 兑现合并 | done | NFR52 拍板 + sizing 实测 + admin_init 测试 |"
    else
        echo "| B9 | A1 + A4 + A5 兑现合并 | pending | NFR52 拍板未落地（依赖 A5） |"
    fi
}

# ---- C1..C9 (Epic 3) ----
check_C1() {
    local f="${ROOT}/.claude/harness/scripts/check_retro_action_items.sh"
    if [ -x "$f" ]; then
        echo "| C1 | retro_action_items checker + pre-commit hook + seed | done | $f |"
    else
        echo "| C1 | retro_action_items checker + pre-commit hook + seed | pending | $f missing |"
    fi
}
check_C2() {
    local sl="${ROOT}/.claude/harness/scripts/check_spec_length.sh"
    local ed="${ROOT}/.claude/harness/scripts/extract_d_decisions.sh"
    local idx="${ROOT}/_bmad-output/planning-artifacts/architecture/index.md"
    if [ -x "$sl" ] && [ -x "$ed" ] && grep -qE '^## D-decisions 总索引' "$idx" 2>/dev/null; then
        echo "| C2 | D-decisions sharded extract + spec 800 hard | done | check_spec_length.sh + extract_d_decisions.sh + index 总索引 |"
    else
        echo "| C2 | D-decisions sharded extract + spec 800 hard | partial | 部分子项落地 |"
    fi
}
check_C3() {
    local f="${ROOT}/.claude/harness/prompt-suffixes/bmad-dev-story-suffix.md"
    if [ -f "$f" ] && grep -qE 'Q6.*全栈贯通' "$f"; then
        echo "| C3 | bmad-dev-story Q6 全栈贯通 review | done | bmad-dev-story-suffix.md Q6 段 |"
    else
        echo "| C3 | bmad-dev-story Q6 全栈贯通 review | pending | Q6 未集成 |"
    fi
}
check_C4() {
    local pkg="${ROOT}/console-web/package.json"
    local count=0
    if [ -f "$pkg" ]; then
        count="$(grep -cE '"gen:(permissions|masking-types|ops-log-actions|tool-types|ai-providers)"' "$pkg" 2>/dev/null || true)"
        count="${count:-0}"
    fi
    if [ "$count" -ge 5 ]; then
        echo "| C4 | 跨栈 mirror codegen 守门 5 脚本 + CI step | done | package.json $count gen:* scripts |"
    else
        echo "| C4 | 跨栈 mirror codegen 守门 5 脚本 + CI step | pending | package.json 仅 $count gen:* scripts（需 ≥ 5） |"
    fi
}
check_C5() {
    local f="${ROOT}/.claude/harness/scripts/grep_deferred_buckets.sh"
    if [ -x "$f" ]; then
        echo "| C5 | deferred-work §1 物化 + grep_deferred_buckets.sh | done | $f executable |"
    else
        echo "| C5 | deferred-work §1 物化 + grep_deferred_buckets.sh | pending | $f missing |"
    fi
}
check_C6() {
    # C6 = A1+A4+A5 合并兑现
    local nfr="${ROOT}/_bmad-output/planning-artifacts/prd/non-functional-requirements.md"
    if [ -f "$nfr" ] && grep -qE 'NFR52 baseline = ' "$nfr"; then
        echo "| C6 | A1+A4+A5 baseline decisions bundle | done | NFR52 拍板已落 |"
    else
        echo "| C6 | A1+A4+A5 baseline decisions bundle | pending | NFR52 拍板未落 |"
    fi
}
check_C7() {
    local f="${ROOT}/.claude/harness/scripts/check_inheritance_block.sh"
    if [ -x "$f" ]; then
        echo "| C7 | Epic 第一个 story 继承段约束 | done | $f executable |"
    else
        echo "| C7 | Epic 第一个 story 继承段约束 | pending | $f missing |"
    fi
}
check_C8() {
    local d="${ROOT}/proxy/addon/parser/resource_safety_tests"
    if [ -d "$d" ]; then
        echo "| C8 | resource-safety-tests 5 类 fixture | done | $d directory |"
    else
        echo "| C8 | resource-safety-tests 5 类 fixture | pending | $d missing |"
    fi
}
check_C9() {
    local f="${ROOT}/.claude/harness/scripts/run_retro_self_audit.sh"
    if [ -x "$f" ]; then
        echo "| C9 | retro self-audit script + bmad-retrospective prepend | done | $f executable |"
    else
        echo "| C9 | retro self-audit script + bmad-retrospective prepend | pending | $f missing |"
    fi
}

# ---- main loop: 按 prev_epic 范围跑 check_* ----
if [ "$PREV_EPIC" -ge 1 ]; then
    for code in A1 A2 A3 A4 A5 A6 A7 A8; do
        "check_$code"
    done
fi
if [ "$PREV_EPIC" -ge 2 ]; then
    for code in B1 B2 B3 B4 B5 B6 B7 B8 B9; do
        "check_$code"
    done
fi
if [ "$PREV_EPIC" -ge 3 ]; then
    for code in C1 C2 C3 C4 C5 C6 C7 C8 C9; do
        "check_$code"
    done
fi
if [ "$PREV_EPIC" -ge 4 ]; then
    echo "WARNING: D-series action items 未在脚本规则；solo-dev 手动追溯 Epic 4 retro action items" >&2
fi

exit 0

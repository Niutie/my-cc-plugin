#!/usr/bin/env bash
# Self-test for harness-prompt-suffix.py — schema v1 contract regression guard.
#
# 触发场景：2026-05-05 codex adversarial review 发现 stage-2 prompt 教 dev agent
# 写老 inline 后缀模式（— **Resolved by Story X.Y** (date)），但 pre-commit hook
# gate ② schema v1 拒该格式 — 真现役自相矛盾。本 test 防止将来再次漂移。
#
# 检查项：
#   1. stage 2 输出**不含**老 inline 后缀字面量 `Resolved by Story X.Y` 当作
#      "教 agent 写"的 wording（出现在禁止段 / docstring 引用 OK，但不能在
#      "→ 追加 ` — Resolved by Story ..."" 这种 instructional 句式里）
#   2. stage 2 输出**含** schema v1 关键字（[status:pending] / [status:resolved]
#      / [target:Story / 历史 子段）— 证明走 schema v1 路径
#   3. 所有 stage 都有代答政策块（每个 stage 必带）
#   4. stage 1 含 §O deferred-work injection notice
#   5. stage 5 含 §N review-progress.json schema 块
#   6. 退出码 0 = 全过；≥ 1 = 失败数

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUFFIX_PY="$SCRIPT_DIR/harness-prompt-suffix.py"

if [ ! -f "$SUFFIX_PY" ]; then
    echo "ERROR: harness-prompt-suffix.py not found at $SUFFIX_PY" >&2
    exit 1
fi

failed=0
pass() { echo "PASS [$1]"; }
fail() { echo "FAIL [$1]: $2" >&2; failed=$((failed + 1)); }

# --- Test 1: stage 2 不含老 inline 后缀的 instructional wording ---
# 允许出现在"禁止"段（"❌ 老 inline 后缀模式 — 不要写 ..."），但不能出现在
# instructional 句式（"→ 追加 ` — **Resolved by Story <short>** (date): ..."）。
# 简化检测：grep 命中"追加 .*Resolved by Story" 或 "追加 .*Partial resolution by Story"
# 视为 instructional wording（即"教 agent 写"），fail。
stage2="$(python3 "$SUFFIX_PY" 2 2>&1)"
if echo "$stage2" | grep -qE "追加.*\*\*Resolved by Story|追加.*\*\*Partial resolution by Story"; then
    fail "no-legacy-inline-instructional" "stage 2 prompt 含 instructional wording 教 dev agent 写老 inline 后缀；与 pre-commit hook gate ② schema v1 拒该格式矛盾"
else
    pass "no-legacy-inline-instructional"
fi

# --- Test 2: stage 2 含 schema v1 关键字（status flip / 历史 sub-entry / target tag）---
if echo "$stage2" | grep -qE "\[status:pending\]" && \
   echo "$stage2" | grep -qE "\[status:resolved\]" && \
   echo "$stage2" | grep -qE "\[target:Story" && \
   echo "$stage2" | grep -qE "历史"; then
    pass "schema-v1-keywords-present"
else
    fail "schema-v1-keywords-present" "stage 2 prompt 缺 schema v1 关键字（[status:pending] / [status:resolved] / [target:Story / 历史 子段）"
fi

# --- Test 3: 所有 stage（1-6）都含代答政策块 ---
all_stages_have_answer_policy=1
for s in 1 2 3 4 5 6; do
    if ! python3 "$SUFFIX_PY" "$s" 2>&1 | grep -q "代答政策"; then
        fail "answer-policy-stage-$s" "stage $s 缺代答政策块"
        all_stages_have_answer_policy=0
    fi
done
[ "$all_stages_have_answer_policy" = "1" ] && pass "answer-policy-all-stages"

# --- Test 4: stage 1 含 §O deferred-work injection notice ---
if python3 "$SUFFIX_PY" 1 2>&1 | grep -q "Deferred-work 注入提示"; then
    pass "stage1-deferred-injection-notice"
else
    fail "stage1-deferred-injection-notice" "stage 1 缺 §O deferred-work 注入提示段"
fi

# --- Test 5: stage 5 含 §N review-progress.json schema 块 ---
if python3 "$SUFFIX_PY" 5 2>&1 | grep -q "review-progress.json schema"; then
    pass "stage5-review-progress-schema"
else
    fail "stage5-review-progress-schema" "stage 5 缺 §N review-progress.json schema 块"
fi

# --- Test 6: stage 2 含 Q6 全栈贯通 review 块 ---
if python3 "$SUFFIX_PY" 2 2>&1 | grep -q "Q6 — 全栈贯通 review"; then
    pass "stage2-q6-block"
else
    fail "stage2-q6-block" "stage 2 缺 Q6 全栈贯通 review 块（yaml-driven 渲染）"
fi

# --- Test 7: 所有 stage（1-6）都含任务追踪工具禁令（issue #9 finding 2）---
all_stages_have_task_ban=1
for s in 1 2 3 4 5 6; do
    if ! python3 "$SUFFIX_PY" "$s" 2>&1 | grep -q "任务追踪工具禁令"; then
        fail "task-tools-ban-stage-$s" "stage $s 缺任务追踪工具禁令段（TaskCreate/TaskUpdate/TaskList 污染主 orchestrator 任务清单）"
        all_stages_have_task_ban=0
    fi
done
[ "$all_stages_have_task_ban" = "1" ] && pass "task-tools-ban-all-stages"

# --- Test 8: stage 2/4 含禁止过程 marker 文件段（issue #8）；stage 5 不含 ---
marker_ban_ok=1
for s in 2 4; do
    if ! python3 "$SUFFIX_PY" "$s" 2>&1 | grep -q "禁止过程 marker 文件"; then
        fail "no-process-marker-stage-$s" "stage $s 缺禁止过程 marker 文件段（maven-skipped.json 之类的冗余产出源头收敛）"
        marker_ban_ok=0
    fi
done
if python3 "$SUFFIX_PY" 5 2>&1 | grep -q "禁止过程 marker 文件"; then
    fail "no-process-marker-stage-5-absent" "stage 5 不应含禁止过程 marker 文件段（仅 dev stage 2/4）"
    marker_ban_ok=0
fi
[ "$marker_ban_ok" = "1" ] && pass "no-process-marker-stages-2-4"

echo
if [ "$failed" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
echo "$failed test(s) failed." >&2
exit 1

#!/usr/bin/env bash
# Issue #7 回归测试 — read_harness_config_field 在 caller `set -u` 下 post-source 调用。
#
# Bug（v0.1.36 及之前）：read_harness_config.sh source 末尾 unset 了 _RHC_THIS，
# 但 read_harness_config_field 函数体（调用期才执行）line ~63 仍引用它 →
# caller `set -euo pipefail` + config yaml 在场（不走 file-not-found early-return）
# 时，任何 post-source 调用命中 'unbound variable' exit 1。
# 次生：process_retro_residue.sh 的 declare -a 数组未 =() 初始化，bash >= 4.3
# （含 issue 现场的 Debian bash 5.2）在 set -u 下连 ${#arr[@]} 都报 unbound
# （bash <= 4.2 / macOS 3.2 容忍）。
#
# 注意：既有测试从 plugin 源码树跑时 config yaml 不在场（函数 early-return），
# 永远走不到崩溃行 — 所以本测试必须搭 deployed 式 fixture（config yaml 在场）。
#
# 4 fixture：
#   T1 issue 原始复现一行：set -euo pipefail + source + call → rc=0 + 读出 yaml 值
#   T2 source 后 cd 走再 call → 仍读出 yaml 值（锁 _RHC_SCRIPT_DIR source 期绝对化）
#   T3 harness_config.py 缺席（awk fallback 路径）→ 同样 set -u 安全
#   T4 process_retro_residue.sh 端到端（deployed 式树 + config 在场）→ rc=0

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN=$'\033[32m'
RED=$'\033[31m'
RESET=$'\033[0m'

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# deployed 式 fixture：.claude/harness/scripts/ + config yaml 在场
# ---------------------------------------------------------------------------
FX="$(mktemp -d)"
trap 'rm -rf "$FX"' EXIT

FX_SCRIPTS="$FX/.claude/harness/scripts"
mkdir -p "$FX_SCRIPTS"
cp "$SCRIPT_DIR/read_harness_config.sh" "$FX_SCRIPTS/"
cp "$SCRIPT_DIR/harness_config.py" "$FX_SCRIPTS/"

cat > "$FX/.claude/harness/harness-project-config.yaml" <<'YAML'
project_display_name: 'Fixture Issue7'
artifacts_root: 'artifacts'
YAML
mkdir -p "$FX/artifacts"

check() {
    local name="$1" rc="$2" out="$3" expect_rc="$4" expect_substr="$5"
    if [[ "$rc" -eq "$expect_rc" ]] && \
       grep -qF "$expect_substr" <<< "$out" && \
       ! grep -q "unbound variable" <<< "$out"; then
        echo "${GREEN}PASS${RESET}: $name (rc=$rc)"
        PASS=$((PASS + 1))
    else
        echo "${RED}FAIL${RESET}: $name — rc=$rc (expect $expect_rc), expect substr '$expect_substr', no 'unbound variable'"
        echo "--- output ---"
        echo "$out" | head -10
        echo "--------------"
        FAIL=$((FAIL + 1))
    fi
}

# ---------------------------------------------------------------------------
# T1 — issue #7 原始复现一行（确定性触发，pre-fix rc=1 'unbound variable'）
# ---------------------------------------------------------------------------
echo ""
echo "=== T1 — set -euo pipefail + source + post-source call ==="
out_t1="$(bash -c "set -euo pipefail; source '$FX_SCRIPTS/read_harness_config.sh'; read_harness_config_field project_display_name x" 2>&1)"
rc_t1=$?
check "T1 set -u post-source call" "$rc_t1" "$out_t1" 0 "Fixture Issue7"

# ---------------------------------------------------------------------------
# T2 — source 后 cd 到别处再 call（锁 _RHC_SCRIPT_DIR source 期绝对路径化：
#      调用期 cwd 已变，仍必须定位到 fixture 的 harness_config.py / config yaml）
# ---------------------------------------------------------------------------
echo ""
echo "=== T2 — call after cd elsewhere ==="
OTHER_DIR="$(mktemp -d)"
out_t2="$(bash -c "set -euo pipefail; cd '$FX'; source '.claude/harness/scripts/read_harness_config.sh'; cd '$OTHER_DIR'; read_harness_config_field project_display_name x" 2>&1)"
rc_t2=$?
rm -rf "$OTHER_DIR"
check "T2 call-time cwd changed" "$rc_t2" "$out_t2" 0 "Fixture Issue7"

# ---------------------------------------------------------------------------
# T3 — harness_config.py 缺席 → awk fallback 路径同样 set -u 安全
# ---------------------------------------------------------------------------
echo ""
echo "=== T3 — awk fallback (harness_config.py absent) ==="
FX3="$(mktemp -d)"
FX3_SCRIPTS="$FX3/.claude/harness/scripts"
mkdir -p "$FX3_SCRIPTS"
cp "$SCRIPT_DIR/read_harness_config.sh" "$FX3_SCRIPTS/"
cp "$FX/.claude/harness/harness-project-config.yaml" "$FX3/.claude/harness/"
out_t3="$(bash -c "set -euo pipefail; source '$FX3_SCRIPTS/read_harness_config.sh'; read_harness_config_field project_display_name x" 2>&1)"
rc_t3=$?
rm -rf "$FX3"
check "T3 awk fallback under set -u" "$rc_t3" "$out_t3" 0 "Fixture Issue7"

# ---------------------------------------------------------------------------
# T4 — process_retro_residue.sh 端到端：deployed 式树 + config 在场。
#      pre-fix：line 240 call 崩（_RHC_THIS）；bash >= 4.3 还有 EXISTING_SPECS。
#
#      注（2026-06-10 Phase B 验证）：fixture **有意不拷** prompt_template_lib.sh
#      —— process_retro_residue.sh 对该 lib 是 guarded-source（缺失时走内联
#      fallback 渲染，partial-deployment skew 防御），本 fixture 顺带锁定该
#      fallback 路径可用。别"顺手补拷"该 lib，否则 fallback 分支失去覆盖。
# ---------------------------------------------------------------------------
echo ""
echo "=== T4 — process_retro_residue.sh end-to-end with config present ==="
cp "$SCRIPT_DIR/process_retro_residue.sh" "$FX_SCRIPTS/"
cp "$SCRIPT_DIR/process_retro_residue_prompt.md" "$FX_SCRIPTS/"

cat > "$FX/artifacts/sprint-status.yaml" <<'YAML'
retro_action_items:
  epic-7-retro:
    Z1: pending
    Z2: done
YAML

cat > "$FX/artifacts/epic-7-retro-2026-06-10.md" <<'MD'
# Epic 7 Retrospective

## 6. Action Items

### Z1 — fake item
### Z2 — fake done item
MD

out_t4="$(bash "$FX_SCRIPTS/process_retro_residue.sh" --epic 7 \
    --sprint-status "$FX/artifacts/sprint-status.yaml" \
    --retro-md "$FX/artifacts/epic-7-retro-2026-06-10.md" \
    --artifact-dir "$FX/artifacts" 2>&1)"
rc_t4=$?
check "T4 process_retro_residue e2e" "$rc_t4" "$out_t4" 0 "RETRO RESIDUE PROCESSOR"

# prompt 模板的 ${project_display_name} 占位符必须被 yaml 值替换（证明 line 240
# 的 read_harness_config_field 真读到了值，而非崩溃或 default 兜底）
if grep -qF "Fixture Issue7" <<< "$out_t4"; then
    echo "${GREEN}PASS${RESET}: T4 prompt placeholder substituted with yaml value"
    PASS=$((PASS + 1))
else
    echo "${RED}FAIL${RESET}: T4 — 'Fixture Issue7' not found in prompt output"
    FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
echo ""
echo "================================"
echo " read_harness_config_issue7_test: PASS=$PASS FAIL=$FAIL"
echo "================================"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0

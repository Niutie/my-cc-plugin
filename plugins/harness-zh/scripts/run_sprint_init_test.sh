#!/usr/bin/env bash
# Self-test for /harness-zh:init §1 prerequisite helper.
#
# Slash command 本身是 LLM-orchestrated（无法 bash 直接 invoke）；本脚本测可机械化的
# §1 prereq gate（run_sprint_init_check_prereq.sh）— 这是 init 流程的硬错误关。
# §2-§4 LLM-driven 部分由人工验收（--dry-run 真实跑 / spot-check 14 字段填值）。
#
# review 2026-06-10 #93：
#   - F3 对齐 helper 现行为：product-brief 自 v0.1.8 起是**可选**产物
#     （缺失 → rc=0 + optional_missing 提示，不再 exit 2）
#   - 新增 F4：真 MUST-EXIST（prd）缺失 → exit 2 + stderr 引导
#   - 新增 F5：sprint-status.yaml 缺失 → exit 3 + /bmad-sprint-planning 引导
#   - HELPER 改 $SCRIPT_DIR 同目录源文件（helper 支持 --root，fixture 全
#     mktemp 自包含 — 不再依赖部署副本，源树/CI 可直跑）
#
# 5 fixtures：
#   F1 全新项目     — 空 yaml + BMad 必需文件全 + sprint-status 全          → exit 0
#   F2 mid-project — 半填 yaml + BMad 必需文件全 + sprint-status 全         → exit 0（同 F1）
#   F3 缺 product-brief.md（可选）                                          → exit 0 + optional_missing
#   F4 缺 prd.md（必需）                                                    → exit 2 + stderr 引导
#   F5 缺 sprint-status.yaml                                                → exit 3 + stderr 引导

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/run_sprint_init_check_prereq.sh"

if [ ! -f "$HELPER" ]; then
    echo "ERROR: helper not found: $HELPER" >&2
    exit 1
fi

GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
PASS=0; FAIL=0

# All fixture roots live under one mktemp sandbox, cleaned by EXIT trap
# (NOT RETURN trap — never fires at top level; review #94 bug class).
WORKDIR="$(mktemp -d -t run_sprint_init_test.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- 创建一个 fixture root（BMad 必需产物 + 可选 product-brief + sprint-status.yaml） ---
make_full_fixture() {
    local d
    d=$(mktemp -d "$WORKDIR/fixture.XXXXXX")
    mkdir -p "$d/_bmad-output/planning-artifacts/architecture"
    mkdir -p "$d/_bmad-output/implementation-artifacts"
    echo "# Product Brief" > "$d/_bmad-output/planning-artifacts/product-brief.md"
    echo "# PRD"           > "$d/_bmad-output/planning-artifacts/prd.md"
    echo "# Tech Stack"    > "$d/_bmad-output/planning-artifacts/architecture/tech-stack.md"
    echo "# Repo Structure"> "$d/_bmad-output/planning-artifacts/architecture/repo-structure.md"
    echo "development_status: {}" > "$d/_bmad-output/implementation-artifacts/sprint-status.yaml"
    echo "$d"
}

# ---------------------------------------------------------------------------
# F1 — 全新项目：空 yaml + 全 BMad → 期望 exit 0 + JSON all_present=true
# ---------------------------------------------------------------------------
echo "=== Fixture 1: 全新项目（空 yaml + BMad 必需文件全 + sprint-status 全） ==="
F1=$(make_full_fixture)
set +e
F1_OUT=$(bash "$HELPER" --root "$F1" 2>&1)
F1_RC=$?
set -e
if [ "$F1_RC" -eq 0 ] && printf '%s' "$F1_OUT" | grep -q '"all_present": true'; then
    echo "${GREEN}PASS${RESET}: F1 — exit 0 + all_present=true (rc=$F1_RC)"
    PASS=$((PASS + 1))
else
    echo "${RED}FAIL${RESET}: F1 — expected rc=0 + all_present=true; got rc=$F1_RC"
    echo "--- output ---"; printf '%s\n' "$F1_OUT" | head -10; echo "--------------"
    FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# F2 — mid-project：半填 yaml（assert init 不破坏既有字段的契约位）
# 注：LLM-driven merge 实际生效需要真实 invoke slash command；本 fixture 仅断言
# helper 在 yaml 已有内容时仍能顺利 PASS prereq gate（不校验 yaml 内容形态）。
# ---------------------------------------------------------------------------
echo ""
echo "=== Fixture 2: mid-project（半填 yaml + BMad 必需文件全） ==="
F2=$(make_full_fixture)
# 半填 yaml — 5/14 字段已有非空值（mid-project 启用 harness 的典型态）
mkdir -p "$F2/.claude/harness"
cat > "$F2/.claude/harness/harness-project-config.yaml" <<'YAML'
project_display_name: 'My Mid-Project'
container_orchestrator: 'docker-compose'
frontend_framework: 'Next.js 16'
backend_languages:
  - 'Go 1.23'
e2e_framework: 'Playwright'
extra:
  frontend_dir: 'frontend'
YAML
set +e
F2_OUT=$(bash "$HELPER" --root "$F2" 2>&1)
F2_RC=$?
set -e
if [ "$F2_RC" -eq 0 ] && printf '%s' "$F2_OUT" | grep -q '"all_present": true'; then
    echo "${GREEN}PASS${RESET}: F2 — exit 0 + all_present=true (mid-project yaml 不影响 prereq) (rc=$F2_RC)"
    PASS=$((PASS + 1))
else
    echo "${RED}FAIL${RESET}: F2 — expected rc=0 + all_present=true; got rc=$F2_RC"
    echo "--- output ---"; printf '%s\n' "$F2_OUT" | head -10; echo "--------------"
    FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# F3 — product-brief.md 缺失（**可选**产物）→ exit 0 + optional_missing 提示
#      （helper 自 v0.1.8 起把 product-brief 降级为可选；缺失只 WARN，
#       project_display_name 字段从 prd.md 兜底 — review #93 行为对齐）
# ---------------------------------------------------------------------------
echo ""
echo "=== Fixture 3: 可选产物缺失（删 product-brief.md）→ exit 0 + optional_missing ==="
F3=$(make_full_fixture)
rm -f "$F3/_bmad-output/planning-artifacts/product-brief.md"
set +e
F3_OUT=$(bash "$HELPER" --root "$F3" 2>&1)
F3_RC=$?
set -e
if [ "$F3_RC" -eq 0 ] \
   && printf '%s' "$F3_OUT" | grep -q '"all_present": true' \
   && printf '%s' "$F3_OUT" | grep -q '"optional_missing": \[' \
   && printf '%s' "$F3_OUT" | grep -q "product-brief" \
   && printf '%s' "$F3_OUT" | grep -q "从 prd.md 兜底"; then
    echo "${GREEN}PASS${RESET}: F3 — exit 0 + optional_missing 含 product-brief（可选不阻流） (rc=$F3_RC)"
    PASS=$((PASS + 1))
else
    echo "${RED}FAIL${RESET}: F3 — expected rc=0 + optional_missing 含 product-brief; got rc=$F3_RC"
    echo "--- output ---"; printf '%s\n' "$F3_OUT" | head -15; echo "--------------"
    FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# F4 — 真 MUST-EXIST 缺失（删 prd.md）→ exit 2 + stderr 含 "/bmad-create-prd"
# ---------------------------------------------------------------------------
echo ""
echo "=== Fixture 4: MUST-EXIST 缺失（删 prd.md）→ exit 2 + stderr 引导 ==="
F4=$(make_full_fixture)
rm -f "$F4/_bmad-output/planning-artifacts/prd.md"
set +e
F4_OUT=$(bash "$HELPER" --root "$F4" 2>&1)
F4_RC=$?
set -e
if [ "$F4_RC" -eq 2 ] \
   && printf '%s' "$F4_OUT" | grep -q '"all_present": false' \
   && printf '%s' "$F4_OUT" | grep -q "prd.md" \
   && printf '%s' "$F4_OUT" | grep -q "/bmad-create-prd"; then
    echo "${GREEN}PASS${RESET}: F4 — exit 2 + stderr 含 '/bmad-create-prd' (rc=$F4_RC)"
    PASS=$((PASS + 1))
else
    echo "${RED}FAIL${RESET}: F4 — expected rc=2 + stderr 引导; got rc=$F4_RC"
    echo "--- output ---"; printf '%s\n' "$F4_OUT" | head -15; echo "--------------"
    FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# F5 — sprint-status.yaml 缺失 → exit 3 + stderr 含 "/bmad-sprint-planning"
# ---------------------------------------------------------------------------
echo ""
echo "=== Fixture 5: sprint-status.yaml 缺失 → exit 3 + stderr 引导 ==="
F5=$(make_full_fixture)
rm -f "$F5/_bmad-output/implementation-artifacts/sprint-status.yaml"
set +e
F5_OUT=$(bash "$HELPER" --root "$F5" 2>&1)
F5_RC=$?
set -e
if [ "$F5_RC" -eq 3 ] \
   && printf '%s' "$F5_OUT" | grep -q '"all_present": false' \
   && printf '%s' "$F5_OUT" | grep -q '"missing_sprint_status": true' \
   && printf '%s' "$F5_OUT" | grep -q "/bmad-sprint-planning"; then
    echo "${GREEN}PASS${RESET}: F5 — exit 3 + stderr 含 '/bmad-sprint-planning' (rc=$F5_RC)"
    PASS=$((PASS + 1))
else
    echo "${RED}FAIL${RESET}: F5 — expected rc=3 + stderr 引导; got rc=$F5_RC"
    echo "--- output ---"; printf '%s\n' "$F5_OUT" | head -15; echo "--------------"
    FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "================================"
echo " run_sprint_init_test: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -gt 0 ] && exit 1
exit 0

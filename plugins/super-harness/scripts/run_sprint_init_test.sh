#!/usr/bin/env bash
# Self-test for /super-harness:init §1 prerequisite helper.
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
#   F6-F9（0.3.1）产物目录解析：_bmad/bmm/config.yaml（{project-root} / {output_folder}）
#      > harness yaml artifacts_root > 默认；引导文本用 BMad 6.12 实际 skill 名
#   F10-F14（0.5.4，#32）BMad 6.12+ 运行目录：prds/<运行目录>/prd.md、
#      architecture/<运行目录>/ARCHITECTURE-SPINE.md、briefs/<运行目录>/brief.md；
#      多个运行目录的选择；customize.toml 与 _bmad/custom 覆盖；只有运行目录的
#      architecture/ 不算 sharded

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
   && printf '%s' "$F3_OUT" | grep -q "从 PRD 兜底"; then
    echo "${GREEN}PASS${RESET}: F3 — exit 0 + optional_missing 含 product-brief（可选不阻流） (rc=$F3_RC)"
    PASS=$((PASS + 1))
else
    echo "${RED}FAIL${RESET}: F3 — expected rc=0 + optional_missing 含 product-brief; got rc=$F3_RC"
    echo "--- output ---"; printf '%s\n' "$F3_OUT" | head -15; echo "--------------"
    FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# F4 — 真 MUST-EXIST 缺失（删 prd.md）→ exit 2 + stderr 含 "/bmad-prd"
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
   && printf '%s' "$F4_OUT" | grep -q "/bmad-prd"; then
    echo "${GREEN}PASS${RESET}: F4 — exit 2 + stderr 含 '/bmad-prd' (rc=$F4_RC)"
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
# F6-F9 — 产物目录解析（0.3.1）：BMad 配置 > harness yaml artifacts_root > 默认
# ---------------------------------------------------------------------------
set +e
check_case() {  # check_case <name> <root> <expected rc> <grep patterns...>
    local name="$1" root="$2" want="$3" out rc p; shift 3
    out=$(bash "$HELPER" --root "$root" 2>&1); rc=$?
    for p in "$@"; do
        if ! printf '%s' "$out" | grep -qF -- "$p"; then
            echo "${RED}FAIL${RESET}: $name — missing '$p' (rc=$rc)"
            printf '%s\n' "$out" | head -15
            FAIL=$((FAIL + 1)); return
        fi
    done
    if [ "$rc" -ne "$want" ]; then
        echo "${RED}FAIL${RESET}: $name — rc=$rc, want $want"; printf '%s\n' "$out" | head -15
        FAIL=$((FAIL + 1)); return
    fi
    echo "${GREEN}PASS${RESET}: $name"
    PASS=$((PASS + 1))
}

echo ""
echo "=== Fixture 6: _bmad/bmm/config.yaml 自定义目录（{project-root} 占位符） ==="
F6=$(mktemp -d "$WORKDIR/fixture.XXXXXX")
mkdir -p "$F6/_bmad/bmm" "$F6/docs/plan" "$F6/docs/impl"
cat > "$F6/_bmad/bmm/config.yaml" <<'EOF'
# BMM Module Configuration
planning_artifacts: "{project-root}/docs/plan"
implementation_artifacts: '{project-root}/docs/impl'   # comment
EOF
echo "# PRD" > "$F6/docs/plan/prd.md"
echo "# Arch" > "$F6/docs/plan/architecture.md"
echo "development_status: {}" > "$F6/docs/impl/sprint-status.yaml"
check_case "F6 BMad config paths honoured" "$F6" 0 \
    '"all_present": true' '"planning_dir": "docs/plan"' '"implementation_dir": "docs/impl"' \
    '"planning_source": "bmad-config"' '"implementation_source": "bmad-config"'
rm "$F6/docs/impl/sprint-status.yaml"
check_case "F6b sprint-status looked up in the BMad implementation dir" "$F6" 3 \
    "$F6/docs/impl/sprint-status.yaml" "/bmad-sprint-planning"

echo ""
echo "=== Fixture 7: {output_folder} 占位符 ==="
F7=$(mktemp -d "$WORKDIR/fixture.XXXXXX")
mkdir -p "$F7/_bmad/bmm" "$F7/out/planning-artifacts" "$F7/out/implementation-artifacts"
printf 'output_folder: "{project-root}/out"\nplanning_artifacts: "{output_folder}/planning-artifacts"\nimplementation_artifacts: "{output_folder}/implementation-artifacts"\n' \
    > "$F7/_bmad/bmm/config.yaml"
echo "# PRD" > "$F7/out/planning-artifacts/prd.md"
mkdir -p "$F7/out/planning-artifacts/architecture"; echo "# Arch" > "$F7/out/planning-artifacts/architecture/index.md"
echo "development_status: {}" > "$F7/out/implementation-artifacts/sprint-status.yaml"
check_case "F7 {output_folder} resolved" "$F7" 0 '"planning_dir": "out/planning-artifacts"' '"implementation_dir": "out/implementation-artifacts"'

echo ""
echo "=== Fixture 8: 无 BMad 配置 → harness yaml artifacts_root ==="
F8=$(make_full_fixture)
mkdir -p "$F8/.claude/harness" "$F8/specs"
printf "project_display_name: 'x'\nartifacts_root: 'specs'\n" > "$F8/.claude/harness/harness-project-config.yaml"
check_case "F8 yaml artifacts_root used when BMad config absent" "$F8" 3 \
    '"implementation_dir": "specs"' '"implementation_source": "harness-yaml"' '"planning_source": "default"'
echo "development_status: {}" > "$F8/specs/sprint-status.yaml"
check_case "F8b sprint-status found under artifacts_root" "$F8" 0 '"all_present": true'

echo ""
echo "=== Fixture 9: 都没有 → 默认目录；引导用 BMad 6.12 实际 skill 名 ==="
F9=$(mktemp -d "$WORKDIR/fixture.XXXXXX")
check_case "F9 defaults + 6.12 command names" "$F9" 2 \
    '"planning_dir": "_bmad-output/planning-artifacts"' '"implementation_source": "default"' \
    "/bmad-prd" "/bmad-architecture" "/bmad-create-epics-and-stories"
OUT9=$(bash "$HELPER" --root "$F9" 2>&1)
if printf '%s' "$OUT9" | grep -qE '/bmad:|/bmad-create-prd 生成|/bmad-create-architecture 生成'; then
    echo "${RED}FAIL${RESET}: F9b — guidance still suggests colon aliases / pre-6.11 names"; FAIL=$((FAIL + 1))
else
    echo "${GREEN}PASS${RESET}: F9b — no colon aliases or pre-6.11 names suggested"; PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
# F10-F14 — BMad 6.12+ 运行目录布局（#32）
# ---------------------------------------------------------------------------
# make_run_folder_fixture — 只有 prds/<运行目录>/prd.md 和 architecture/<运行目录>/ARCHITECTURE-SPINE.md
make_run_folder_fixture() {
    local d p
    d=$(mktemp -d "$WORKDIR/fixture.XXXXXX")
    p="$d/_bmad-output/planning-artifacts"
    mkdir -p "$d/_bmad/bmm" "$p/prds/prd-demo-2026-11-07" "$p/architecture/architecture-demo-2026-11-09/reviews" \
             "$d/_bmad-output/implementation-artifacts"
    printf 'planning_artifacts: "{project-root}/_bmad-output/planning-artifacts"\nimplementation_artifacts: "{project-root}/_bmad-output/implementation-artifacts"\n' \
        > "$d/_bmad/bmm/config.yaml"
    printf -- '---\ntitle: demo\nstatus: final\n---\n# PRD\n' > "$p/prds/prd-demo-2026-11-07/prd.md"
    printf -- "---\nname: 'demo'\nstatus: final\n---\n# Spine\n" > "$p/architecture/architecture-demo-2026-11-09/ARCHITECTURE-SPINE.md"
    echo "# review" > "$p/architecture/architecture-demo-2026-11-09/reviews/r.md"
    echo "development_status: {}" > "$d/_bmad-output/implementation-artifacts/sprint-status.yaml"
    echo "$d"
}

echo ""
echo "=== Fixture 10: BMad 6.12.4 默认运行目录（prds/、architecture/） ==="
F10=$(make_run_folder_fixture)
check_case "F10 run folders recognised, paths reported" "$F10" 0 '"all_present": true' \
    '"prd_path": "_bmad-output/planning-artifacts/prds/prd-demo-2026-11-07/prd.md"' '"prd_form": "run-folder"' \
    '"architecture_path": "_bmad-output/planning-artifacts/architecture/architecture-demo-2026-11-09/ARCHITECTURE-SPINE.md"' \
    '"architecture_form": "run-folder"'

echo ""
echo "=== Fixture 11: 多个运行目录 — status: final 优先，其次日期最新 ==="
F11=$(make_run_folder_fixture)
P11="$F11/_bmad-output/planning-artifacts/prds"
mkdir -p "$P11/prd-demo-2026-11-12" "$P11/prd-demo-2026-11-01"
printf -- '---\nstatus: draft\n---\n# newer draft\n' > "$P11/prd-demo-2026-11-12/prd.md"
printf -- '---\nstatus: final\n---\n# older final\n' > "$P11/prd-demo-2026-11-01/prd.md"
check_case "F11 final beats newer draft; newest final wins" "$F11" 0 \
    '"prd_path": "_bmad-output/planning-artifacts/prds/prd-demo-2026-11-07/prd.md"'
sed -i 's/status: final/status: draft/' "$P11/prd-demo-2026-11-07/prd.md" "$P11/prd-demo-2026-11-01/prd.md"
check_case "F11b no final → newest date wins" "$F11" 0 \
    '"prd_path": "_bmad-output/planning-artifacts/prds/prd-demo-2026-11-12/prd.md"'

echo ""
echo "=== Fixture 12: customize.toml / _bmad/custom 覆盖输出位置 ==="
F12=$(make_run_folder_fixture)
P12="$F12/_bmad-output/planning-artifacts"
mkdir -p "$F12/.claude/skills/bmad-prd" "$F12/_bmad/custom" "$P12/docs-prd/x-demo" "$P12/team-prd/run-1"
printf '[workflow]\nprd_output_path = "{planning_artifacts}/docs-prd"\nrun_folder_pattern = "x-{project_name}"\n' \
    > "$F12/.claude/skills/bmad-prd/customize.toml"
rm -rf "$P12/prds"
echo "# PRD" > "$P12/docs-prd/x-demo/prd.md"
check_case "F12 customize.toml output path honoured" "$F12" 0 \
    '"prd_path": "_bmad-output/planning-artifacts/docs-prd/x-demo/prd.md"'
printf '[workflow]\nprd_output_path = "{planning_artifacts}/team-prd"   # team\nrun_folder_pattern = "run-{n}"\n' \
    > "$F12/_bmad/custom/bmad-prd.toml"
echo "# PRD" > "$P12/team-prd/run-1/prd.md"
check_case "F12b _bmad/custom team override beats customize.toml" "$F12" 0 \
    '"prd_path": "_bmad-output/planning-artifacts/team-prd/run-1/prd.md"'

echo ""
echo "=== Fixture 13: architecture/ 里只有运行目录、没有 SPINE → 不算 sharded ==="
F13=$(make_run_folder_fixture)
rm "$F13/_bmad-output/planning-artifacts/architecture/architecture-demo-2026-11-09/ARCHITECTURE-SPINE.md"
check_case "F13 empty-of-md architecture/ is missing" "$F13" 2 '"architecture_path": ""' "/bmad-architecture"
echo "# Tech" > "$F13/_bmad-output/planning-artifacts/architecture/tech-stack.md"
check_case "F13b architecture/ with .md files is sharded" "$F13" 0 \
    '"architecture_path": "_bmad-output/planning-artifacts/architecture"' '"architecture_form": "sharded"'

echo ""
echo "=== Fixture 14: 单文件优先；brief 运行目录 ==="
F14=$(make_run_folder_fixture)
P14="$F14/_bmad-output/planning-artifacts"
echo "# PRD" > "$P14/prd.md"
mkdir -p "$P14/briefs/brief-demo-2026-11-05"
echo "# Brief" > "$P14/briefs/brief-demo-2026-11-05/brief.md"
check_case "F14 prd.md wins over run folder; brief run folder found" "$F14" 0 \
    '"prd_path": "_bmad-output/planning-artifacts/prd.md"' '"prd_form": "single"' \
    '"product_brief_path": "_bmad-output/planning-artifacts/briefs/brief-demo-2026-11-05/brief.md"' \
    '"optional_missing": []'

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "================================"
echo " run_sprint_init_test: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -gt 0 ] && exit 1
exit 0

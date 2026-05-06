#!/usr/bin/env bash
# Test harness manual bootstrap
#
# 首次接通 testarch 三 skill（test-design / framework / atdd）的引导脚本。**solo-dev
# 在场触发**——本脚本不直接调 Claude Skill 工具（脚本能力之外），而是：
#
#   1. 跑 .claude/harness/scripts/check_test_harness_env.sh 输出环境快照
#   2. 给 stdout 打"接下来主 agent 应做什么"的 deterministic 引导（含 3 步 testarch
#      skill 调用顺序 + 预期产出文件清单 + sandbox 受限时的 dry-run 路径）
#   3. seed _bmad-output/implementation-artifacts/sprint-status.yaml 顶层
#      `test_status:` 段（如已存在则 no-op；如缺失则插入 placeholder header
#      让后续 testarch 调用有 yaml anchor 可写）
#
# stdout 被主 agent 当成"manifest"：主 agent 读完依次调 /bmad-testarch-test-design /
# /bmad-testarch-framework / /bmad-testarch-atdd（按 .claude/harness/answer-policy.md 自决，
# 解决任何内部 ask 节点），最后跑 ## Verification 段的产物校验命令。
#
# 用法：
#   bash .claude/harness/scripts/bootstrap_test_harness.sh [--epic <num>] [--story <key>]
#
# 默认值（与 chore-test-harness-bootstrap spec Q3/Q1 锁定值一致）：
#   --epic   = 4                                      （Epic 4 是首次 test-design 目标）
#   --story  = chore-retro-c1-A8-architecture-d-decisions-index
#                                                     （C10 实际命名；spec 写错为 c10-A8）
#
# 退出码：
#   0   引导文本已写到 stdout + sprint-status seed 已就位
#   1   sprint-status.yaml 路径异常 / yaml seed 失败 — 主 agent 走 §3 halt 模板

set -uo pipefail

EPIC="${EPIC:-4}"
STORY="${STORY:-chore-retro-c1-A8-architecture-d-decisions-index}"

# ---- 参数解析（接受 long 形式 --epic <n> / --story <k>） ----
while [ $# -gt 0 ]; do
    case "$1" in
        --epic)  EPIC="${2:-}"; shift 2;;
        --story) STORY="${2:-}"; shift 2;;
        *) echo "ERROR: unknown arg: $1" >&2; exit 1;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=read_harness_config.sh
source "$SCRIPT_DIR/read_harness_config.sh"
REPO_ROOT="$HARNESS_REPO_ROOT"
SPRINT_STATUS="$HARNESS_SPRINT_STATUS_PATH"
TEST_ARTIFACTS_DIR="$HARNESS_ARTIFACTS_ROOT/test_artifacts"

if [ ! -f "$SPRINT_STATUS" ]; then
    echo "ERROR: sprint-status.yaml not found at $SPRINT_STATUS" >&2
    exit 1
fi

# ---- 环境快照 ----
ENV_JSON="$(bash "$REPO_ROOT/.claude/harness/scripts/check_test_harness_env.sh")"

# ---- seed test_artifacts/ 目录（首次 bootstrap 创建 + .gitkeep） ----
mkdir -p "$TEST_ARTIFACTS_DIR"
if [ ! -f "$TEST_ARTIFACTS_DIR/.gitkeep" ]; then
    : > "$TEST_ARTIFACTS_DIR/.gitkeep"
fi

# ---- seed sprint-status.yaml 顶层 test_status: 段（如缺失） ----
# 设计：放在文件末尾（不动既有 development_status / retro_action_items 段）。
# 结构：
#   test_status:
#     <key>:
#       atdd: pending|red|green|skipped
#       e2e_last_run: ISO-8601 string OR null
#       sandbox_bound: true|false
#
# 首次 seed 写一个 placeholder comment block，testarch-atdd 第一次跑后会写第一条 entry。
if ! grep -qE "^test_status:" "$SPRINT_STATUS"; then
    {
        echo ""
        echo "# ============================================================================"
        echo "# Test Status — chore C-bootstrap test harness 接通后的 atdd / e2e 跑动状态"
        echo "# ============================================================================"
        echo "# 由 .claude/commands/run-test-sprint.md 各 stage（T3 atdd / T4 e2e）写入。"
        echo "# 字段："
        echo "#   atdd          pending | red | green | skipped"
        echo "#   e2e_last_run  ISO-8601 时间戳 OR null（never run）"
        echo "#   sandbox_bound true 表示该 key 因环境受限走 graceful skip 路径"
        echo "# ============================================================================"
        echo "test_status: {}"
    } >> "$SPRINT_STATUS"
fi

# ---- 输出引导 manifest 给主 agent / solo-dev ----
cat <<EOF
=== Test Harness Bootstrap Manifest ===
Generated: $(date '+%Y-%m-%dT%H:%M:%S')
Target epic: $EPIC
Trial story:  $STORY

[1/3] Environment probe (real_probe unless FORCE_SANDBOX=1):
$ENV_JSON

[2/3] sprint-status.yaml test_status: section seeded (no-op if already present).

[3/3] Next steps for主 agent (按 .claude/harness/answer-policy.md 自决，按顺序触发):

  Step A — testarch test-design (Epic-level test plan):
    skill:       /bmad-testarch-test-design
    expected output:
      _bmad-output/implementation-artifacts/test_artifacts/epic-${EPIC}-test-design.md
    sandbox note: 即使 all_available=false 也可跑（产出纯 markdown，不依赖 docker/playwright）.

  Step B — testarch framework init (Playwright 框架装载):
    skill:       /bmad-testarch-framework
    args:        --tool playwright --target console-web
    expected output:
      console-web/playwright.config.ts
      console-web/tests/e2e/ (目录 + 1 个 example.spec.ts)
      console-web/package.json (devDep: @playwright/test ^1.50.0; scripts: e2e/e2e:install/e2e:report)
      .gitignore (加 console-web/tests/e2e/playwright-report/ + test-results/)
    sandbox note: ⚠️ 不在沙箱实跑 'pnpm install @playwright/test' 与 'pnpm playwright install
                  --with-deps chromium'（spec 边界 — 不在 sandbox 强跑）；写 config + devDep 即停，
                  solo-dev post-merge 在本地执行 install。

  Step C — testarch atdd (Trial story 红相 spec):
    skill:       /bmad-testarch-atdd
    args:        --story $STORY
    expected output:
      _bmad-output/implementation-artifacts/test_artifacts/${STORY}.atdd-checklist.md
      console-web/tests/e2e/${STORY}.spec.ts (红相 placeholder — 无依赖断言)
    sandbox note: spec.ts 是红相 scaffold；实际跑 e2e 留给后续 stage 5.5 / /run-test-sprint
                  入口。本步只产 scaffold 不实跑。

[Verification commands (主 agent 全部跑完 A/B/C 后跑):]
  test -f _bmad-output/implementation-artifacts/test_artifacts/epic-${EPIC}-test-design.md
  test -f console-web/playwright.config.ts
  test -d console-web/tests/e2e
  test -f _bmad-output/implementation-artifacts/test_artifacts/${STORY}.atdd-checklist.md
  test -f console-web/tests/e2e/${STORY}.spec.ts

[Single commit msg suggestion:]
  chore(test-harness): testarch first integration — test-design + playwright + atdd
=== END Manifest ===
EOF

exit 0

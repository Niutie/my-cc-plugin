---
description: 测试 harness 单 story 入口（atdd 红相 + e2e 实跑 + sandbox graceful skip）；可独立触发或由 run-sprint stage 5.5 自动调用
argument-hint: '--story <key>'
allowed-tools: Bash, Read, Edit, Write, Task, AskUserQuestion
---

# Test Sprint Loop（chore C-bootstrap 第一版）

你是测试 harness 的**主 orchestrator**。当用户触发 `/harness-zh:run-test --story <key>`，或当 `/harness-zh:run` 阶段 ⑤.5 自动调用，你必须按以下手册顺序执行 stage T1 / T3 / T4。

**与 `/harness-zh:run` 共享的行为契约**：

- **代答政策**：每个用 `Agent` / `SendMessage` 调度的 testarch 子 agent，prompt 末尾必须含"按 `.claude/harness/answer-policy.md` 自决，不要发问"。该文件只含跨项目**通用决策原则**（见 [`answer-policy.md`](../harness/answer-policy.md)）；项目特定语境按其自述由 `harness-prompt-suffix.py` 注入——run-test 的 testarch 子 agent（T 系 stage 无 suffix 入口）仅依赖通用原则自决。
- **进度可视化**：用 TaskCreate 给本次 test sprint 建一个任务（标题形如 `Test Sprint: <key>`），stage 进入时 `in_progress`，完成时 `completed`。
- **Commit 协议**：每次 commit 调 `python3 .claude/harness/scripts/harness-commit.py <stage> <key>`（stage 取值：`T1` / `T3` / `T4`）；不允许 `git add -A`。
- **结构化校验信任链**：不做"广义错误词"文本扫描；产物缺失 / schema 不合规 / harness-commit 退出码 1 — 这三类硬错误才 halt。

**v1 范围**（chore C-bootstrap 第一版限定）：

- ✅ Stage T1（test-design）/ T3（atdd）/ T4（automate-e2e）
- ❌ T2（framework-check 由 bootstrap.sh 一次性 init）/ T5（nfr-per-epic）/ T6（trace-per-epic）— 留 v0.2+
- ✅ 单 story 模式（`--story <key>` 必传）；批量 `--epic` 留 v0.2+
- ✅ Sandbox graceful skip（all_available=false → 写 skipped report + FU-Test-<key>-sandbox + exit 0，不阻调用方）

---

## −1. Commit 协议（test-sprint 专用 stage 命名空间）

`harness-commit.py` 已扩展支持 `T1` / `T3` / `T4` stage（详 chore C-bootstrap Phase C；与 run-sprint 5-stage 隔离命名空间）。每个 stage 的预期产出：

| Stage | 预期产出路径 | Commit msg 模板 |
|---|---|---|
| `T1` | `_bmad-output/implementation-artifacts/test_artifacts/epic-${EPIC}-test-design.md` + `sprint-status.yaml` | `test(epic-${epic}): test-design` |
| `T3` | `_bmad-output/implementation-artifacts/test_artifacts/<key>.atdd-checklist.md` + `${FRONTEND_DIR}/${E2E_SUBDIR}/<key>.spec.ts`（占位符 = §0.1 解析值；默认 `console-web/tests/e2e`——harness-commit.py 的 e2e spec 白名单前缀与之同源读 config） + `sprint-status.yaml` | `test(<key>): atdd red-phase scaffold` |
| `T4` | `_bmad-output/implementation-artifacts/test_artifacts/<key>-test-result.json` + `sprint-status.yaml` + `deferred-work.md`（fail/sandbox 时） | `test(<key>): atdd + e2e (run-sprint stage 5.5)` |

每次 commit 退出码处理：
- **0（STATUS=ok）**：脚本 stage 完毕，主 agent 用 SUGGEST_COMMIT_MSG + HEREDOC + Co-Authored-By: 行 commit
- **1（STATUS=halt）**：按 §3 halt 模板贴脚本 stdout 给用户
- **2（STATUS=skip）**：worktree 干净，跳过该 stage commit

---

## 0. 启动前置

### 0.0 参数解析

| 参数 | 行为 |
|---|---|
| `--story <key>` | 必传；本次目标 story key（一般是 `_bmad-output/implementation-artifacts/<key>.md` 文件名去 `.md`） |
| `--epic <num>` | 可选；override sprint-status `epic-of <key>` 解析。v1 仅用作 T1 epic-test-design 路径计算 |
| `--dry-run` | 不实跑 testarch skill / 不实跑 pnpm e2e；仅 echo 计划 + 退出 |

绑定到对话上下文：
- `KEY` = `--story` 值
- `EPIC` = `--epic` 值；若未传 → 跑 `python3 .claude/harness/scripts/sprint-status.py epic-of $KEY`；脚本退出码 1（chore-* / spec-* 类 key 无 epic）→ `EPIC=""`（T1 跳过）
- `DRY_RUN` = `--dry-run` 给定 → `1`，否则 `0`

### 0.0.5 触发条件评估（chore-test-harness-conditional-triggers）

调 `eval_test_stage_triggers.sh` 评估当前 story 应跑哪些 stage（condition-driven）：

```bash
EVAL_JSON=$(bash .claude/harness/scripts/eval_test_stage_triggers.sh "$KEY" \
    "_bmad-output/implementation-artifacts/$KEY.md" 2>/dev/null)
T1_TRIG=$(echo "$EVAL_JSON" | sed -nE 's/.*"t1":[[:space:]]*([a-z]+).*/\1/p')
T3_TRIG=$(echo "$EVAL_JSON" | sed -nE 's/.*"t3":[[:space:]]*([a-z]+).*/\1/p')
T4_TRIG=$(echo "$EVAL_JSON" | sed -nE 's/.*"t4":[[:space:]]*([a-z]+).*/\1/p')
T5_TRIG=$(echo "$EVAL_JSON" | sed -nE 's/.*"t5":[[:space:]]*([a-z]+).*/\1/p')
T6_TRIG=$(echo "$EVAL_JSON" | sed -nE 's/.*"t6":[[:space:]]*([a-z]+).*/\1/p')
EVAL_REASON=$(echo "$EVAL_JSON" | sed -nE 's/.*"reason":[[:space:]]*"([a-z_]+)".*/\1/p')
```

**Fail-open 准则**：eval 脚本失败 / yaml 损坏 / `EVAL_REASON=fail_open_default` → 主 agent **不阻流**；按 defaults（t1/t3/t4=true, 其余 false）继续 + stderr 输出 WARN（与 §3 死循环防护表第 4 条 graceful skip 同款）。

stage 跑或 skip 由后续每条 stage 的"触发判断"门决定（见 §1 各 stage）。

> **5-5 commit 由本 subagent 内部 T4 stage 完成（chore-harness-epic-4-orchestration-observations T2.2，2026-05-04）**：当本 subagent 由 `/harness-zh:run` stage 5.5 自动调起时，run-sprint 主 agent **不会再调用** `harness-commit.py 5-5` 当 commit 路径——只会跑 5-5 命令做 sanity gate（期待 STATUS=skip 验证 worktree 已被 T3+T4 commit 清干净）。本 subagent 必须负责跑完整 T1/T3/T4 + 各自 commit；T4 commit message 含 "(run-sprint stage 5.5)" 后缀让 grep 稳定找。详 [`run.md`](run.md) §1 阶段 ⑤.5。

### 0.1 环境探测

```bash
ENV_JSON=$(bash .claude/harness/scripts/check_test_harness_env.sh)
ALL_AVAILABLE=$(echo "$ENV_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["all_available"])')
REASON=$(echo "$ENV_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["reason"])')
# 前端目录：probe JSON 已带 frontend_dir 字段（probe 自己从 harness-project-config.yaml 读，
# 缺省 console-web）——不要在本文件硬编码目录名
FRONTEND_DIR=$(echo "$ENV_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["frontend_dir"])')
# e2e spec 子目录（相对 $FRONTEND_DIR）：probe JSON 不含该字段，从 config 读
# （与 eval_test_stage_triggers.sh / harness-commit.py 的 e2e spec 白名单同源口径）
source .claude/harness/scripts/read_harness_config.sh
E2E_SUBDIR=$(read_harness_config_field e2e_test_subdir 'tests/e2e')
echo "ALL_AVAILABLE=$ALL_AVAILABLE REASON=$REASON"
echo "FRONTEND_DIR=$FRONTEND_DIR E2E_SUBDIR=$E2E_SUBDIR"
```

把 `FRONTEND_DIR` / `E2E_SUBDIR` 绑定到对话上下文——§−1 产出表、§1 T3 prompt、§1 T4 执行块的
e2e spec 路径全部以这两个值为准（默认 `console-web` + `tests/e2e`）。

**三条分支**（v0.1.19 A 档加入 no-e2e clean skip 分流）：

- `ALL_AVAILABLE == True` → 进 §1 stage T1/T3/T4 全跑
- `ALL_AVAILABLE == False` AND `REASON == "no_e2e_configured"` → 进 **§4.5 no-e2e clean skip**（项目自报 `e2e_framework: 'none'` — 跳过 T1/T3/T4，**不**写 skipped report、**不**写 deferred FU-Test-*-sandbox、**不** commit；worktree 保持干净，run-sprint stage 5.5 sanity gate 自然 STATUS=skip 通过）
- `ALL_AVAILABLE == False` AND `REASON` 其它（含 `probe_not_implemented_for_<X>` / `real_probe; missing: ...`）→ 进 §4 sandbox graceful skip（写 skipped report + FU-Test-<key>-sandbox + exit 0）

### 0.2 dry-run 分支

`DRY_RUN == 1` → 输出"本次预期跑 stage T1/T3/T4 + 各自产出路径" 后**直接退出**（不调 testarch skill / 不跑 pnpm）。

---

## 1. 单 story 测试流水线（T1 / T3 / T4）

### Stage T1：Test design（epic-level，幂等）

**触发条件**：`T1_TRIG=true`（来自 §0.0.5 eval JSON — once_per_project 语义：`EPIC` 非空 + `_bmad-output/implementation-artifacts/test_artifacts/epic-${EPIC}-test-design.md` 不存在）。
若 `T1_TRIG=false` → **skip**（test-design 是 epic 级别一次性产出，不重跑）。

**执行**：

```
Agent({
  subagent_type: "general-purpose",
  description: "Test design epic-${EPIC}",
  prompt: <以下 prompt>
})
```

prompt 核心：

> 请直接调用 /bmad-testarch-test-design，目标 epic 编号 = ${EPIC}。这是 epic 级别 test design，必须以 non-interactive 模式运行（任何 <ask> 节点都不要发问，按 `.claude/harness/answer-policy.md` 自决）。
>
> 产出文件：`_bmad-output/implementation-artifacts/test_artifacts/epic-${EPIC}-test-design.md`，含 risk-based 测试计划（哪些 AC 必须 e2e / 哪些 unit / 哪些 sandbox-bound）。完成后停止，不要做任何 git 操作。

**验收**：`test -f _bmad-output/implementation-artifacts/test_artifacts/epic-${EPIC}-test-design.md` 且非空。

**Commit T1**：`python3 .claude/harness/scripts/harness-commit.py T1 $KEY --epic $EPIC` → STATUS=ok 用 SUGGEST_COMMIT_MSG 提交。

### Stage T3：ATDD 红相（per-story）

**触发条件**：`T3_TRIG=true`（来自 §0.0.5 eval JSON — per_story 语义：每次都跑，testarch-atdd 内部幂等）。
若 `T3_TRIG=false` → **skip**（理论上 per_story 永远 true；false 仅在 yaml 改 trigger 后出现）。

**执行**：

```
Agent({
  subagent_type: "general-purpose",
  description: "ATDD red-phase $KEY",
  prompt: <以下 prompt>
})
```

prompt 核心：

> 请直接调用 /bmad-testarch-atdd，目标 story key = $KEY。Story spec 路径：`_bmad-output/implementation-artifacts/$KEY.md`。
>
> 产出文件：
>   `_bmad-output/implementation-artifacts/test_artifacts/$KEY.atdd-checklist.md`
>   `$FRONTEND_DIR/$E2E_SUBDIR/$KEY.spec.ts`
>
> spec.ts 是**红相 scaffold**（实施前先写测试），断言期望故事 spec ## Acceptance Criteria 段每条对应一个 e2e assertion；Playwright API 用 `@playwright/test` 标准 import；不依赖任何 fixtures（首次接通保持简单）。
>
> 必须以 non-interactive 模式运行，按 `.claude/harness/answer-policy.md` 自决。完成后停止，不要做任何 git 操作。

调度前主 agent 把 prompt 里的 `$FRONTEND_DIR` / `$E2E_SUBDIR` 替换为 §0.1 解析出的真实值——子 agent 拿到的必须是字面路径，不要把占位符原样发出去。

**验收**：两个文件齐备（spec.ts 在 `$FRONTEND_DIR/$E2E_SUBDIR/` 下）+ spec.ts 含 `import { test, expect } from '@playwright/test'`。

**Commit T3**：`python3 .claude/harness/scripts/harness-commit.py T3 $KEY` → STATUS=ok 用 SUGGEST_COMMIT_MSG 提交。

### Stage T4：E2E 实跑（per-story）

**触发条件**：`T4_TRIG=true`（来自 §0.0.5 eval JSON — per_story 语义）。
若 `T4_TRIG=false` → **skip**（仅在 yaml 改 trigger 后出现）。

**前置 sanity**：再次确认 `all_available=true`（防 stage T3 之后环境变化）；false → 走 §4 graceful skip 但不回退 T1/T3 的 commit。

**执行**：

```bash
cd "$FRONTEND_DIR"
pnpm e2e --grep "$KEY" 2>&1 | tee "/tmp/harness-test-sprint-$KEY.log"
E2E_RC=${PIPESTATUS[0]}   # pnpm 自身的退出码——直接取 $? 拿到的是 pipeline 末端 tee 的退出码（恒 0）
cd ..
echo "E2E_RC=$E2E_RC"
```

> **RC 口径**：`E2E_RC` 必须经 `${PIPESTATUS[0]}`（bash 3.2 可用）取 `pnpm e2e` 进程本身的退出码；若本块在 zsh 下执行，等价写法是 `${pipestatus[1]}`。下表的 red / error 行依赖真实 RC——取 tee 的 `$?` 会让两行永远不可达、失败被误判。

**结果分类**（按 `pnpm e2e` 退出码 + 解析 log）：

| Verdict | 触发条件 | 写到 test-result.json |
|---|---|---|
| `green`   | E2E_RC=0 + 全部断言 pass | `{"verdict": "green", "atdd": "green", "passed": N, "failed": 0}` |
| `red`     | E2E_RC≠0 + 至少一个断言 fail（**预期**：atdd 红相未实施） | `{"verdict": "red", "atdd": "red", "passed": N, "failed": M}` + 写 deferred-work `FU-Test-<key>-failing` |
| `error`   | E2E_RC≠0 + log 含 "Error: " / browser launch failure | `{"verdict": "error", "atdd": "skipped", "error_kind": "<...>"}` + 写 deferred-work `FU-Test-<key>-runtime-error` |

**写产物**：

- `_bmad-output/implementation-artifacts/test_artifacts/$KEY-test-result.json` — 包含 verdict / passed / failed / e2e_last_run 时间戳
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — 在 `test_status:` 段下加（或更新）`$KEY:` entry
- `_bmad-output/implementation-artifacts/deferred-work.md` — verdict=red/error 时追加 FU-Test 项（不阻流）

**Commit T4**：`python3 .claude/harness/scripts/harness-commit.py T4 $KEY` → STATUS=ok 用 SUGGEST_COMMIT_MSG（commit message 模板含 "(run-sprint stage 5.5)" 后缀，让 grep "stage 5.5" 能稳定找；任一调用路径下都用同一后缀，独立调用时仍带——chore-harness-epic-4-orchestration-observations T2.2 决策）提交。

**测试 fail 不 halt**：T4 verdict=red 是产品行为问题不是 harness 故障；继续走 §2 主循环出口（commit 仍正常落，verdict 写进 test-result.json + deferred-work）。

---

## 2. 主循环

v1 单 story 模式：T1 (skip if exists) → T3 → T4 → 退出。批量 / multi-story 留 v0.2+。

退出条件：T4 commit 完成（无论 verdict）→ 把 TaskCreate 任务标 `completed` → 退出。

---

## 3. 死循环 / 失控防护

下面 5 条**任一命中**立即 halt + 用户介入（与 `/harness-zh:run` §3 同款模板）：

1. testarch skill 子 agent 返回但产物缺失 / 非空校验失败
2. testarch skill 子 agent 提问回来超过 2 次（重发 "按 answer-policy.md 自决" 不解决）
3. `pnpm e2e` 命令本身报"command not found" / "module not found" 等环境问题（非测试断言失败）
4. `harness-commit.py` 返回 STATUS=halt（任一 stage T1/T3/T4）
5. runtime quota 信号（`hit your limit` / `rate limit` / `usage limit` / `quota` / `reset` 时间）

**fail-open 路径**（**不**halt — 与上面 5 条 halt 准则区分）：

- `eval_test_stage_triggers.sh` exit ≠ 0 / yaml 损坏 / `EVAL_REASON=fail_open_default` → 主 agent 用 defaults JSON（t1/t3/t4=true, 其余 false）继续 + stderr WARN，**不**阻流（与 stage 5.5 graceful skip 同款 — harness 自动化的"完成开发"承诺不被工具失败反噬）

**Halt 模板**（与 `/harness-zh:run` §3 一致）：

> stage 失败：T<N> in /harness-zh:run-test --story $KEY
> 现场：[一两句话讲发生了什么]
> 违反规则：[贴 harness-commit.py 的 BLACKLIST/CROSS_STORY/UNEXPECTED_ARTIFACT/UNSTAGED 行 verbatim]
> 已落 commit：[git log --oneline harness/$KEY/start..HEAD]
> 待用户决断：是否 [选项 1] 撤回 / [选项 2] 修复后续作 / [选项 3] 跳过本次 test sprint / [选项 4] 怀疑 plugin 缺陷 → /harness-zh:report-issue（自动收集 halt 现场 + gh CLI 直提 + 附临时绕过方案）

---

## 4. Sandbox graceful skip 路径

**触发**：`check_test_harness_env.sh` 输出 `all_available=false` **且 `reason` 不为 `"no_e2e_configured"`**（即真探测失败 — 缺 chromium / framework / pnpm / version_check 等；或 e2e_framework 是 Cypress/WebdriverIO/Selenium 等未实现栈）。

> v0.1.19 A 档分流：`reason="no_e2e_configured"`（项目自报无 e2e）走 §4.5 clean skip，不再走本节 sandbox-skip 路径。`reason="probe_not_implemented_for_<X>"`（非 Playwright 栈）仍走本节 — 因为 plugin 现有 T3/T4 实现是 Playwright 限定，非 Playwright 栈实质上无法实跑。

**步骤**：

1. 写 `_bmad-output/implementation-artifacts/test_artifacts/skipped-${KEY}-$(date +%Y-%m-%d).md`，内容：
   - 时间戳（ISO-8601）
   - 完整 env JSON（哪个维度 false → 解锁条件提示）
   - 调用上下文（独立 `/harness-zh:run-test --story` 还是 run-sprint stage 5.5）
   - 解锁后补跑命令：`/harness-zh:run-test --story ${KEY}`

2. 在 `_bmad-output/implementation-artifacts/deferred-work.md` 顶部 sandbox-bound section 追加一行：
   ```
   - [ ] FU-Test-${KEY}-sandbox — atdd/e2e 在 sandbox 受限环境跳过（缺 X/Y），solo-dev 解锁后跑 `/harness-zh:run-test --story ${KEY}`（生成 ${KEY}-test-result.json + 移除本 FU 项）
   ```

3. 更新 `sprint-status.yaml` 的 `test_status:` 段：
   ```yaml
   test_status:
     ${KEY}:
       atdd: skipped
       e2e_last_run: null
       sandbox_bound: true
   ```

4. **commit 5-fallback 风格**：跑 `python3 .claude/harness/scripts/harness-commit.py T4 $KEY`（脚本 T4 路径白名单含 skipped-* + sprint-status + deferred-work；commit msg 是统一模板 `test(<key>): atdd + e2e (run-sprint stage 5.5)`——**无** sandbox 专用分支，sandbox 路径也用同一后缀）。STATUS=ok → 用 SUGGEST_COMMIT_MSG 提交。

5. **退出码 0**：不阻调用方（独立调用退出 0；run-sprint stage 5.5 调用时 main agent 继续走 stage 6）。

**幂等性**：solo-dev 解锁后跑 `/harness-zh:run-test --story $KEY` → check_env all_available=true → 走 §1 流水线 → T4 commit 时 deferred-work.md 的 `FU-Test-${KEY}-sandbox` 行被本次 patch 移除（test_status entry 也覆写为 atdd=red/green）。

---

## 4.5 No-e2e clean skip 路径（v0.1.19 A 档）

**触发**：`check_test_harness_env.sh` 输出 `all_available=false` 且 `reason="no_e2e_configured"`（即项目 `harness-project-config.yaml` 顶层 `e2e_framework: 'none'`，自报无 e2e 测试需求）。

**与 §4 sandbox-skip 的关键差异**：

| | §4 sandbox-skip | §4.5 no-e2e clean skip |
|---|---|---|
| 触发原因 | 环境探测真失败（缺 chromium / framework / pnpm 等） | 项目主动声明无 e2e |
| 写 `skipped-${KEY}-*.md` 标记 | ✅ 写 | ❌ 不写 |
| 写 deferred-work `FU-Test-${KEY}-sandbox` | ✅ 写（待 solo-dev 解锁后清） | ❌ 不写 |
| 改 sprint-status `test_status` 段 | ✅ 写 `sandbox_bound: true` | ❌ 不动 |
| commit T4 | ✅ 跑 T4 commit（统一 commit msg 模板，无 sandbox 专用分支） | ❌ 不 commit（worktree 保持干净） |
| 调用方影响 | run-sprint 5.5 sanity gate 看 worktree 已被清干净 → STATUS=skip | run-sprint 5.5 sanity gate 看 worktree 一开始就干净 → STATUS=skip |
| 幂等性 | solo-dev 装好 env 后重跑 → 翻 sandbox=true→false | 项目从 'none' 改成 'Playwright' 后重跑 → 自动走 §1/§4 |

**步骤**：

1. **echo banner**（stdout — 让调用方与 solo-dev 都明确这是声明式 skip 不是 bug）：

   ```
   ⏸ /harness-zh:run-test --story ${KEY} → no-e2e clean skip
     原因：harness-project-config.yaml 声明 e2e_framework='none'
     行为：跳过 T1/T3/T4；不写 skipped report；不污染 deferred-work
     如要恢复 e2e 流水线，把 e2e_framework 改为 'Playwright'（含装相应运行时）
   ```

2. **退出码 0**：不阻调用方。**不调** `harness-commit.py`（无产物可 commit）。worktree 保持调用前状态（如有 dev 阶段未提交的代码，本节不动它们）。

**为什么不也跑 T1（test-design）**：T1 产物是 `epic-${EPIC}-test-design.md`（risk-based 测试计划），对纯后端 / 无 e2e 项目仍有价值（unit test 设计建议）。但当前 BMad testarch-test-design skill 默认 e2e 取向，对无 e2e 项目产出可能错位 / 噪声。保守起见 v0.1.19 A 档**统一跳 T1+T3+T4**；后续如有诉求再分开（issue 待提）。

---

## 5. 参数

| 参数 | 必传 | 说明 |
|---|---|---|
| `--story <key>` | ✅ | 目标 story key |
| `--epic <num>` | — | override `epic-of <key>` 解析；v1 仅 T1 epic-test-design 路径用 |
| `--dry-run` | — | 仅打印计划不实跑 |

**v0.2+ 留口**（chore C-bootstrap 第一版**不**实现，调用时返回 `not yet implemented`）：
- `--epic <num>` 单独触发批量：T5 nfr-per-epic / T6 trace-per-epic
- `--all`：跨 epic 批量补跑
- T2 framework-check：每次启动校验 framework 装载完整性（含 lock）

---

## 引用

- run-sprint 主流程：[`run.md`](run.md) — stage 5.5 嵌入由 chore C-bootstrap Phase C 落地
- 代答政策（通用决策原则；项目语境由 harness-prompt-suffix.py 注入）：[`answer-policy.md`](../harness/answer-policy.md)
- harness-commit T1/T3/T4 stage 路径白名单：[`harness-commit.py`](../harness/scripts/harness-commit.py)
- env probe：[`.claude/harness/scripts/check_test_harness_env.sh`](../../.claude/harness/scripts/check_test_harness_env.sh)
- bootstrap orchestrator：[`.claude/harness/scripts/bootstrap_test_harness.sh`](../../.claude/harness/scripts/bootstrap_test_harness.sh)
- 4 份 chore 元设计：[`architecture.md`](../harness/architecture.md) §二 / §五

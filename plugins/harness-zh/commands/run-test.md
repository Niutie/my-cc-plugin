---
description: 测试 harness 单 story 入口（atdd 红相 + e2e 实跑 + sandbox graceful skip）；可独立触发或由 run-sprint stage 5.5 自动调用
argument-hint: '--story <key>'
---

# Test Sprint Loop（chore C-bootstrap 第一版）

你是测试 harness 的**主 orchestrator**。当用户触发 `/harness-zh:run-test --story <key>`，或当 `/harness-zh:run` 阶段 ⑤.5 自动调用，你必须按以下手册顺序执行 stage T1 / T3 / T4。

**与 `/harness-zh:run` 共享的行为契约**：

- **代答政策**：每个用 `Agent` / `SendMessage` 调度的 testarch 子 agent，prompt 末尾必须含"按 `.claude/harness/answer-policy.md` 自决，不要发问"。代答政策项目语境见 [`/answer-policy.md`](../answer-policy.md)。
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
| `T3` | `_bmad-output/implementation-artifacts/test_artifacts/<key>.atdd-checklist.md` + `console-web/tests/e2e/<key>.spec.ts` + `sprint-status.yaml` | `test(<key>): atdd red-phase scaffold` |
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

> **5-5 commit 由本 subagent 内部 T4 stage 完成（chore-harness-epic-4-orchestration-observations T2.2，2026-05-04）**：当本 subagent 由 `/harness-zh:run` stage 5.5 自动调起时，run-sprint 主 agent **不会再调用** `harness-commit.py 5-5` 当 commit 路径——只会跑 5-5 命令做 sanity gate（期待 STATUS=skip 验证 worktree 已被 T3+T4 commit 清干净）。本 subagent 必须负责跑完整 T1/T3/T4 + 各自 commit；T4 commit message 含 "(run-sprint stage 5.5)" 后缀让 grep 稳定找。详 [`run-sprint.md`](run-sprint.md) §1 阶段 ⑤.5。

### 0.1 环境探测

```bash
ENV_JSON=$(bash .claude/harness/scripts/check_test_harness_env.sh)
ALL_AVAILABLE=$(echo "$ENV_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["all_available"])')
```

**两条分支**：

- `ALL_AVAILABLE == True` → 进 §1 stage T1/T3/T4 全跑
- `ALL_AVAILABLE == False` → 进 §4 sandbox graceful skip（写 skipped report + FU-Test-<key>-sandbox + exit 0）

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
>   `console-web/tests/e2e/$KEY.spec.ts`
>
> spec.ts 是**红相 scaffold**（实施前先写测试），断言期望故事 spec ## Acceptance Criteria 段每条对应一个 e2e assertion；Playwright API 用 `@playwright/test` 标准 import；不依赖任何 fixtures（首次接通保持简单）。
>
> 必须以 non-interactive 模式运行，按 `.claude/harness/answer-policy.md` 自决。完成后停止，不要做任何 git 操作。

**验收**：两个文件齐备 + spec.ts 含 `import { test, expect } from '@playwright/test'`。

**Commit T3**：`python3 .claude/harness/scripts/harness-commit.py T3 $KEY` → STATUS=ok 用 SUGGEST_COMMIT_MSG 提交。

### Stage T4：E2E 实跑（per-story）

**触发条件**：`T4_TRIG=true`（来自 §0.0.5 eval JSON — per_story 语义）。
若 `T4_TRIG=false` → **skip**（仅在 yaml 改 trigger 后出现）。

**前置 sanity**：再次确认 `all_available=true`（防 stage T3 之后环境变化）；false → 走 §4 graceful skip 但不回退 T1/T3 的 commit。

**执行**：

```bash
cd console-web
pnpm e2e --grep "$KEY" 2>&1 | tee /tmp/harness-test-sprint-$KEY.log
E2E_RC=$?
cd ..
```

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
> 待用户决断：是否 [选项 1] 撤回 / [选项 2] 修复后续作 / [选项 3] 跳过本次 test sprint

---

## 4. Sandbox graceful skip 路径

**触发**：`check_test_harness_env.sh` 输出 `all_available=false`（任一维度 false：docker / pnpm / node / playwright）。

**步骤**：

1. 写 `_bmad-output/implementation-artifacts/test_artifacts/skipped-${KEY}-$(date +%Y-%m-%d).md`，内容：
   - 时间戳（ISO-8601）
   - 完整 env JSON（哪个维度 false → 解锁条件提示）
   - 调用上下文（独立 `/harness-zh:run-test --story` 还是 run-sprint stage 5.5）
   - 解锁后补跑命令：`just test-sprint STORY=${KEY}`

2. 在 `_bmad-output/implementation-artifacts/deferred-work.md` 顶部 sandbox-bound section 追加一行：
   ```
   - [ ] FU-Test-${KEY}-sandbox — atdd/e2e 在 sandbox 受限环境跳过（缺 X/Y），solo-dev 解锁后跑 `just test-sprint STORY=${KEY}`（生成 ${KEY}-test-result.json + 移除本 FU 项）
   ```

3. 更新 `sprint-status.yaml` 的 `test_status:` 段：
   ```yaml
   test_status:
     ${KEY}:
       atdd: skipped
       e2e_last_run: null
       sandbox_bound: true
   ```

4. **commit 5-fallback 风格**：跑 `python3 .claude/harness/scripts/harness-commit.py T4 $KEY`（脚本路径白名单含 skipped-* + sprint-status + deferred-work；commit msg 模板有 sandbox 分支）。STATUS=ok → 用 SUGGEST_COMMIT_MSG 提交。

5. **退出码 0**：不阻调用方（独立调用退出 0；run-sprint stage 5.5 调用时 main agent 继续走 stage 6）。

**幂等性**：solo-dev 解锁后跑 `just test-sprint STORY=$KEY` → check_env all_available=true → 走 §1 流水线 → T4 commit 时 deferred-work.md 的 `FU-Test-${KEY}-sandbox` 行被本次 patch 移除（test_status entry 也覆写为 atdd=red/green）。

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

- run-sprint 主流程：[`run-sprint.md`](run-sprint.md) — stage 5.5 嵌入由 chore C-bootstrap Phase C 落地
- 代答政策：[`/answer-policy.md`](../answer-policy.md)
- harness-commit T1/T3/T4 stage 路径白名单：[`/scripts/harness-commit.py`](../scripts/harness-commit.py)
- env probe：[`.claude/harness/scripts/check_test_harness_env.sh`](../../.claude/harness/scripts/check_test_harness_env.sh)
- bootstrap orchestrator：[`.claude/harness/scripts/bootstrap_test_harness.sh`](../../.claude/harness/scripts/bootstrap_test_harness.sh)
- 4 份 chore 元设计：[`harness-architecture.md`](../harness-architecture.md) §二 / §五

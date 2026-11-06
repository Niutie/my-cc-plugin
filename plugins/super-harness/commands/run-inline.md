---
description: 单路、在当前会话里直接跑 sprint：主 agent 按 pipeline.md 一条一条推进 backlog story（bmad-build-auto 规划+实现+review → 外部 codex review/fix（按需）→ follow-up review（按需）→ build-sync → epic retro），每一步都在当前会话可见，适合调试和优化流水线
argument-hint: '[--story [<key>] | --epic [<num>] | --continue | --dry-run]'
allowed-tools: Bash, Read, Edit, Write, Agent, Task, AskUserQuestion
---

# Sprint 单路循环（inline 模式）

你是这个循环的**主 orchestrator**。当用户触发 `/super-harness:run-inline`，你在当前会话里按顺序推进 story，直到 `sprint-status.yaml` 中再无 `backlog` story（或达到参数限定的范围）为止。**禁止并行**多条 story；同一时刻最多一条 story 在流水线里。需要并行时用 `/super-harness:run`。

**先 Read `.claude/harness/pipeline.md`**。单条 story 的每一步（B0 到 B4、⑥、⑥.5、verdict 门）、行为契约、halt 规则都写在那里，你按其中「inline 模式」的做法执行。本文件只管启动、选 story 和主循环。

引用约定：带 `P` 前缀的章节（`P§−1`、`P§0.A.0`、`P§0.B`、`P§1 B1`、`P§3`）指 pipeline.md，不带前缀的指本文件。

> **流水线背景（BMad 6.11+）**：BMad 6.11 把 `bmad-create-story` / `bmad-dev-story` 合并成 `bmad-build` / `bmad-build-auto`，6.12 默认不再安装旧 skill。现在每条 story 的「规划 → 实现 → 多层对抗 review → commit」由**一次** `bmad-build-auto` 跑完（P§1 B1），harness 负责它前后的事：事前清 retro 阻塞、注入 deferred 待办，事后审计 commit 区间、补外部 codex（项目没把 codex 挂进 build 时）、按需追加一轮 follow-up review、同步 sprint-status 与 deferred ledger，然后做 epic retro 和 retro 残余处理。测试由 bmad-build-auto 在实现阶段跑，流水线没有单独的测试阶段（P§1「测试由谁负责」）。旧流水线启动、尚未完成的 story 见 P§1.L。

---

## 0. 启动前置

### 0.0 目标范围解析（先做这一步，不可省略）

按 §5 参数表把参数映射到 `LOOP_SCOPE`，并绑定到主 agent 的对话上下文（每条 story 回报、§2 退出条件、P§3 halt 模板都会读）：

- `LOOP_SCOPE`：`all` / `single-story` / `single-epic` / `continue-single` / `dry-run`
- `TARGET_KEY`（`single-story` / `continue-single`）
- `TARGET_EPIC`（`single-epic`）

| 参数 | LOOP_SCOPE | 目标解析 | 前置分支 |
|---|---|---|---|
| 无参数 | `all` | — | §0.A |
| `--story` | `single-story` | `TARGET_KEY = $(python3 .claude/harness/scripts/sprint-status.py next)`；退出码 1 → halt | §0.A |
| `--story <key>` | `single-story` | `TARGET_KEY = <key>`；`git rev-parse --verify --quiet harness/<key>/start` 成功 → §0.B 续作；否则 §0.A | §0.A / §0.B |
| `--epic` | `single-epic` | 先 `sprint-status.py next`：退出码 0 → `TARGET_EPIC = $(sprint-status.py epic-of <next>)`，§0.A；退出码 1 → 按 yaml 顺序找最早一个 `epic-N-retrospective` 非 `done` 的 epic，`TARGET_EPIC = N`，再跑 `epic-all-done N`：0 → §0.C；非 0 → halt（文案见 §2「epic 未全终态 halt」）；都没有 → 回报"sprint 已全部完成"退出 | §0.A / §0.C / 退出 |
| `--epic <num>` | `single-epic` | `TARGET_EPIC = <num>`。`epic-all-done` + `epic-retro-status` 判断：仍有非终态 story → §0.A；全终态且 retro != done → §0.C；全终态且 retro = done → 回报"该 epic 已完成"退出 | §0.A / §0.C / 退出 |
| `--continue` 或 `--continue 继续完成当前这个story` | `continue-single` | `python3 .claude/harness/scripts/harness-state.py --in-flight`（harness 打了 start tag、没有 done tag、sprint-status 也不是 done / wont-do / cancelled 的 story）：恰好 1 条 → `TARGET_KEY`；多条 → 用 AskUserQuestion 让用户选；为空 → halt | §0.B |
| `--dry-run` | `dry-run` | — | §2 dry-run 分支 |

> `--continue` 以前用 `sprint-status.py find-by-status review` 找目标。BMad 6.11+ 项目里 `review` 也表示"交互式 bmad-build 做完、等合并"，跟中断的 harness 运行无关，所以改用 harness 自己的 tag 判断。

### 0.A 全新启动

依次跑：

0. **运行条件探测**：
   ```bash
   bash .claude/harness/scripts/check_bmad_runtime.sh
   ```
   `STATUS=fail` → halt，把每行 `REMEDIATION=` 原样给用户（典型：没装 `uv`；BMad 低于 6.11；嵌套子 agent 被关）。`STATUS=ok` → 记下 `CODEX_IN_BUILD=`（非 `none` 表示 codex 已作为 review layer 挂进 bmad-build-auto，B2 外部 codex 不跑）。
1. `python3 .claude/harness/scripts/sprint-status.py count` — 输出 `<剩余>/<总数>`；文件缺失 → halt，提示先跑 `bmad-sprint-planning`。
1.5. **retro_action_items 写法检查**：`python3 .claude/harness/scripts/sprint-status.py migrate-retro-items --check`。退出码 3 = 还有 harness-zh ≤ 0.1.39 的标量写法（`A1: pending` + 过缩进子键，不是合法 YAML；BMad 6.12 的 retro / sprint-planning 脚本整文件按 YAML 解析，会直接失败）→ 工作区干净时跑 `python3 .claude/harness/scripts/sprint-status.py migrate-retro-items`，再 `python3 .claude/harness/scripts/harness-commit.py retro-migrate -` 按 P§−1.d commit（位参 key 用 `-` 占位）。工作区不干净时先按第 2 步处理，迁移留到下次启动。
1.6. **依赖写法检查**：`python3 .claude/harness/scripts/sprint-status.py flatten-deps --check`。退出码 3 = `development_status` 里还有多行块写法（`key:` 下面嵌套 `status:` / `depends_on:`）。BMad 6.12.4 的 retrospective `detect-epic` 会把这种块里已经 done 的 story 算成未完成，retro 因此判 `rejected`，`sprint_plan.py` 也会直接报错（issue #14）。工作区干净时跑 `python3 .claude/harness/scripts/sprint-status.py flatten-deps`，再 `python3 .claude/harness/scripts/harness-commit.py deps-migrate -` 按 P§−1.d commit，并告诉用户一行：依赖已挪到 sprint-status 顶层的 `story_dependencies`。退出码 4 = 块里有别的字段，脚本没动文件，把 stderr 的 `PROBLEM=` 行转告用户，不 halt。工作区不干净时留到下次启动。
2. `git status --porcelain` — **必须为空**（bmad-build-auto 在脏工作区上直接 HALT）。不为空时：
   - `python3 .claude/harness/scripts/harness-state.py --in-flight` 恰好 1 行 → 作为 `<KEY>` 自动切 §0.B，并告诉用户一行："worktree 不干净 + 检测到 harness 在跑的 `<KEY>` → 自动切续作"。**先把这条 story 跑完**：按 §0.B 从它的切入点一直跑到 B4（含触发的 ⑥ / ⑥.5 / verdict 门）。它在 sprint-status 里还是 `backlog`，不先跑完的话，主循环的 `sprint-status.py next` 会把它当新 story 再挑出来，B0 也会撞上脏工作区。跑完之后：
     - `LOOP_SCOPE = all` / `single-epic` → 回到本节第 3 步接着做，然后进 §2 主循环；
     - `LOOP_SCOPE = single-story` 且 `<KEY>` 就是 `TARGET_KEY` → 回报并退出；不是 → 回到本节第 3 步，再跑 `TARGET_KEY`。
   - 多行 → halt，把列表给用户，请用 `--story <key>` 指定要续作的那条（无法从脏工作区判断改动属于哪条）。
   - 无输出 → halt：工作区有不属于任何 harness 运行的改动，需要用户清理或说明。刚跑完 `/super-harness:init` 或 `update` 时，脏文件通常是 `.gitignore`、`.claude/harness/harness-project-config.yaml`、`.claude/harness/parallel.yaml` 和新建的 `deferred-work.md`：提示用户按 init §5 把它们提交（仓库还没有任何 commit 时先做一次初始提交），不要替用户提交。
3. 并行调度残留检查：`python3 .claude/harness/scripts/superh.py board --json`，数一下 `stage` 不是 `done` / `abandoned` 的条目。非 0 → 提醒用户一行：`/super-harness:run` 还有 N 路 lane 没收口（列出 key），在同一个 sprint 分支上 inline 推进会和它们的合流互相干扰，`--continue` 也可能挑中某个 lane 的 story；建议先用 `/super-harness:run` 收完，或用 `superh.py abandon <KEY> --yes` 放弃。不 halt，用户坚持就继续。
4. TaskCreate 按 `LOOP_SCOPE` 建任务（标题 `Sprint: <story_key>`，初始 `pending`）：`all` → 每条 backlog；`single-story` → `TARGET_KEY`；`single-epic` → 该 epic 的每条 backlog。
5. 执行 P§0.A.0（retro DEV 项兑现 gate）。

用一条简短消息告诉用户整体计划：LOOP_SCOPE、预计 story 数、第一条 key、`CODEX_IN_BUILD` 取值。

### 0.B 续作

worktree **可以**不干净。

1. 确定 `<KEY>`（`--story <key>` 给定，或 `--continue` / §0.A 自动切入时按 §0.0 / §0.A 规则从 `--in-flight` 取得）。
2. 先跑 §0.A 第 0 步运行条件探测（失败 → halt）。
3. 按 P§0.B 切入表，用 `harness-state.py <KEY>` 的 `next_action_code` 决定从哪一步接着跑。`done` → 不该续作：`--story <key>` / `--continue` 指定的就是这条，回报"`<KEY>` 已完成"后退出，不去跑别的 story；`not-started` → 按 §0.A 进 P§1 B0。
4. TaskCreate 建一个任务跟踪本 story。

告诉用户一行切入计划：从哪一步续作 `<KEY>`。

### 0.C Retro-only 启动（`single-epic` 且该 epic 全终态但 retro 未 done）

跳过 P§1 B0-B4，直接进阶段 ⑥：

1. `EPIC = $TARGET_EPIC`。
2. `KEY` 按 P§1 阶段 ⑥ 的「retro 用的 `KEY`」规则取。
3. 无条件执行阶段 ⑥（含格式契约段，不要因为是 retro-only 就省略），然后 ⑥.5 和 verdict 门。

完成后回到 §2：`single-epic` + retro 已 done → 退出。

---

## 2. 主循环

```
# 顶层 dry-run 分支
if LOOP_SCOPE == "dry-run":
  跑 check_bmad_runtime.sh 并显示结果
  按目标范围枚举每条预期会跑的 story，每条输出一行：B1 → [B2 若 CODEX_IN_BUILD=none] → [B3 按需] → B4 → [⑥]
  不调任何子 agent、不 commit
  退出

if LOOP_SCOPE == "single-epic" and 已走 §0.C: 退出   # §0.C 已跑完 ⑥、⑥.5 和 verdict 门，不要再跑
if LOOP_SCOPE == "continue-single": 按 P§0.B 切入点跑 $TARGET_KEY 剩余步骤（含触发的 ⑥）；退出
if LOOP_SCOPE == "single-story": 跑 $TARGET_KEY 的 B0…B4（含触发的 ⑥）；退出

# 默认循环（all 或 single-epic 且该 epic 仍有 backlog）
loop:
  if LOOP_SCOPE == "single-epic":
    next_key = `sprint-status.py next-in-epic $TARGET_EPIC`   # 不要用全局 next
    if 退出码 1 且 stderr 有 `waiting=` 行: halt，把 waiting= 原样贴给用户（backlog 都在等依赖或外部条件，见下方说明）
    if 该 epic 无 backlog:
      if `epic-retro-status $TARGET_EPIC` != "done":
        if `epic-all-done $TARGET_EPIC` 退出码 0: 走 §0.C 触发 retro
        else: halt（见下方「epic 未全终态 halt」）
      break
  else:
    next_key = `sprint-status.py next`
    if 退出码 1 且 stderr 有 `waiting=` 行: halt，把 waiting= 原样贴给用户（见下方说明）
    if 无 backlog: break      # all 模式先做下面的「all 模式收尾检查」，再报完成

  if next_key 属于一个新 epic（与上一条不同）: 重跑 P§0.A.0（新 epic 起跑前清 retro dev 阻塞）
  跑 P§1 的 B0…B4
  跑 ⑥ / ⑥.5（仅当它是该 epic 最后一条且 retro 未 done）
  if RETRO_VERDICT == "rejected" and EPIC_WONT_DO == "none" and EPIC_PARKED == "none" and LOOP_SCOPE == "all": halt（见 P§1「verdict 门」）
  回报一行进度（"M/N 完成 (LOOP_SCOPE=<value>)"）
goto loop

if LOOP_SCOPE == "all": 做「all 模式收尾检查」（见下）；需要 halt 就 halt，不报完成
report "🎉 完成 (LOOP_SCOPE=<value>, target=<key 或 epic 或 —>)"
执行 P§2 收尾提醒（codex-skipped 通知框 + report-issue 提示）
```

每次回到循环顶部都重新检查 LOOP_SCOPE。

**选 story 的顺序和依赖**：`next` / `next-in-epic` 按 sprint-status 文件顺序取第一条 `backlog`，但会跳过声明了依赖、依赖还没满足的 story。依赖来源和 `/super-harness:run` 一样：`parallel.yaml` 的 `deps_overrides`，然后是 sprint-status 顶层的 `story_dependencies`，最后是多行块里的 `depends_on`。`ext-` 开头的项是外部条件（例如 `ext-contract-signoff`），一直算没满足，条件满足后由用户从依赖里删掉。没声明依赖的 story 不受影响，照文件顺序跑。所有 backlog 都在等时退出码 1，stderr 打一行 `waiting=<key>(<没满足的依赖>);...`，这时 halt，把这一行转告用户：要么先完成上游 story，要么删掉已经满足的 `ext-` 条件。`--story <key>` 明确指定的 story 不做这项检查。

**all 模式收尾检查**：`sprint-status.py next` 只返回 `backlog`。停在 ready-for-dev / in-progress / review 的 story（比如 halt 后用户没处理完就跳到了下一条）永远不会被主循环挑中，它所在 epic 的 retro 也就一直不跑。所以 `all` 模式在报完成之前跑一次：

```bash
python3 .claude/harness/scripts/sprint-status.py open-epics
```

每行 `<epic>\t<retro 状态>\t<all-done|active|parked>`，列的是 retro 还不是 done 的 epic。`parked` 表示这个 epic 一条 done 都没有，其余全是挂起（`parked_statuses`）或放弃的 story，没有可回顾的内容。

- 有 `active` 行 → halt。对每个这样的 epic 跑 `sprint-status.py epic-all-done <N>`，按下面「epic 未全终态 halt」的文案给建议，和 `single-epic` 模式一样。
- 没有 `active` 行时，`all-done` 行 → 不 halt，在完成回报里列出这些 epic，提示用 `/super-harness:run-inline --epic <N>` 补跑 retro（这些 epic 可能是在 harness 之外完成的，要不要补 retro 由用户决定）。
- `parked` 行 → 不 halt，在完成回报里列出这些 epic 和它们的挂起 story（`sprint-status.py epic-stories <N>`），说明它们等挂起解除后再开发。
- 无输出 → 正常报完成。

**epic 未全终态 halt**：epic 已无 backlog、retro 未 done、`epic-all-done` 却非 0 时，把它的 stderr 原样贴给用户，再按 `active=` / `unrecognized=` 两行给建议：

- `active=` 非 none：有 story 停在中途（ready-for-dev / in-progress / review）。提示先 `/super-harness:run-inline --continue`；`harness-state.py --in-flight` 为空时说明这些 story 不是 harness 推进的，请用户手工收尾。
- 只有 `unrecognized=`：这些 story 的状态不在 BMad 标准状态里，也不在终态里（常见于规划期作废的 story 用了别的写法）。`--continue` 续不了，不要建议它。提示用户：已作废的改成 `cancelled` 或 `wont-do`，已交付的改成 `done`，改完重跑 `/super-harness:run-inline --epic <N>`。

---

## 4. 用户中断点

用户随时可以打断你。每条 story **完成后**（B4 之后、回到循环顶部之前）给用户一行进度回报，这是天然的中断窗口。

---

## 5. 参数

| 参数 | LOOP_SCOPE | 语义 | 何时停 |
|---|---|---|---|
| 无参数 | `all` | 跑完所有 backlog story（每个 epic 完成时自动 retro） | 无 backlog 且收尾检查通过，或某 epic retro verdict = rejected，或收尾检查发现有 story 停在中途 |
| `--story` | `single-story` | 跑下一条 backlog story 然后停 | 该 story 走完（含触发的 ⑥） |
| `--story <key>` | `single-story` | 指定 key。已有 `harness/<key>/start` tag → §0.B 续作；没有但已存在手工 bmad-build 的 spec → B1 以续跑模式接手 | 同上 |
| `--epic` | `single-epic` | 跑当前 epic 剩余 backlog（含 retro）。"当前 epic" = 下一条 backlog 所属的 epic | 该 epic backlog 清空 + retro done |
| `--epic <num>` | `single-epic` | 跑指定 epic。已全终态但 retro 未做 → §0.C；retro 也 done → 直接退出 | 同上 |
| `--continue` | `continue-single` | 续作 harness 上次中断的 story（`harness-state.py --in-flight` 恰好一条时直接续作；多条时用 AskUserQuestion 让用户选）。worktree 可以不干净 | 续作的那一条跑完就停 |
| `--continue 继续完成当前这个story` | `continue-single` | 自然语言版 | 同上 |
| `--dry-run` | `dry-run` | 不调子 agent、不 commit，只打印运行条件探测结果和每条 story 的步骤计划 | — |

没有参数时按 §0.A + §2（LOOP_SCOPE=`all`）跑到底。

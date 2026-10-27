---
description: 自动按 sprint-status 跑完所有 backlog story（主 agent 编排：bmad-build-auto 规划+实现+review → 外部 codex review/fix（按需）→ follow-up review（按需）→ build-sync → 测试 → epic retro）
argument-hint: '[--story [<key>] | --epic [<num>] | --continue | --dry-run]'
allowed-tools: Bash, Read, Edit, Write, Agent, Task, AskUserQuestion
---

# Sprint 自动开发循环

你是这个循环的**主 orchestrator**。当用户触发 `/harness-zh:run`，你必须按以下手册顺序执行，直到 `sprint-status.yaml` 中再无 `backlog` story 为止。**禁止并行**多条 story；同一时刻最多一条 story 在流水线里。

> **v0.2.0 流水线变更（BMad 6.11+）**：BMad 6.11 把 `bmad-create-story` / `bmad-dev-story` 合并成 `bmad-build` / `bmad-build-auto`，6.12 默认不再安装旧 skill。现在每条 story 的「规划 → 实现 → 多层对抗 review → commit」由**一次** `bmad-build-auto` 跑完（§1 B1），harness 负责它前后的事：事前清 retro 阻塞、注入 deferred 待办，事后审计 commit 区间、补外部 codex（项目没把 codex 挂进 build 时）、按需追加一轮 follow-up review、同步 sprint-status 与 deferred ledger，然后照旧跑测试、epic retro、retro 残余处理。旧流水线启动、尚未完成的 story 见 §1.L。

---

## −1. 主 agent 行为契约（贯穿全流程）

**(a) 监控信号**：你用 `Agent` / `SendMessage` 调度子 agent 时是同步等待的——子 agent 返回的那条消息就是"完成信号"。每次调用后做两件事：
1. **看产物 / 跑审计**：每个阶段都列了"验收"项（B1/B3 是 `harness-commit.py build-verify`）。失败 → halt。
2. **看状态**：`python3 .claude/harness/scripts/harness-state.py $KEY --plain` 只读核对。发现与预期不符**不要**手工 `set`：sprint-status 推进只发生在 B4 `build-sync`（以及 retro 阶段），由 `harness-commit.py` 统一完成。

**结构化校验优先，不做文本扫描**：主 agent 不在子 agent 返回文本里搜 `error` / `failed` 之类的词判断成败（误报极高）。真正的失败一定能被结构化校验抓到：build-verify 的 `SPEC_STATUS_NOT_DONE=` / `DIRTY_WORKTREE=` / `CROSS_STORY=`，`harness-commit.py` 的退出码 1。

**例外：配额耗尽**。runtime quota 信号在结构化层不可见，**仍然要扫文本**：`hit your limit` / `rate limit` / `usage limit` / `quota` / `reset` 时间提示 → halt + 用 §3 配额模板（选项 5）。**B2 codex 例外**：codex subagent 的 quota/auth 命中**不 halt**，走 §B2.1 skip+marker 路径。

> **关于 git index**：bmad-build-auto 自己 commit；harness 自己的 commit（B2 的 3/4、B4、测试、retro）一律经 `harness-commit.py` 预先 stage。主 agent 任何时候都不自己 `git add`。

**(b) 代答政策**：用户授权你在循环中替他回答所有 BMad / Codex 子 agent 的问询。通用决策原则在 `.claude/harness/answer-policy.md`，项目语境由 `harness-prompt-suffix.py` 从 harness-project-config.yaml 读出并内联进 prompt 后缀。

1. **每一个** subagent prompt 末尾都必须附带 prompt 后缀，**不要手贴**，改用：
   ```bash
   python3 .claude/harness/scripts/harness-prompt-suffix.py <stage>
   ```
   stage 取值：`build`（B1/B3）/ `3`（B2 codex）/ `4`（B2 fix）/ `6`（retro）/ `chore`（§0.A.0 retro-fulfill）。`implement` 由 bmad-build-auto 的实现子 agent 自己拉取，主 agent 不用。`1` / `2` / `5` 只给 §1.L 旧流水线 story 用。
2. bmad-build-auto 本身无人值守、不提问；intent 不清会 HALT `blocked`。其它子 agent 若仍提问回来（罕见），用 `SendMessage` 重发一次"按 `.claude/harness/answer-policy.md` 自决"，**不要**转给用户。
3. 真正必须 halt 的只有 §3 列出的硬错误。"我需要你确认 X / Y" 不属于硬错误。

**(c) 进度可视化**：用 TaskCreate 在启动时为每条要跑的 story 建一个任务，进入流水线时 `in_progress`，完成时 `completed`。

**(d) Commit 协议**：

| 谁 commit | 哪些阶段 | 主 agent 怎么守门 |
|---|---|---|
| bmad-build-auto 自己（Finalize 步骤） | B1 build、B3 follow-up | 事后跑 `harness-commit.py build-verify $KEY`：审计 `harness/$KEY/start..HEAD` 区间的每个路径（凭据黑名单 / `_bmad-output` 越界 / 跨 story 隔离）+ spec 终态 + 工作区干净 |
| 主 agent 经 `harness-commit.py` | B2 `3` / `4`、B4 `build-sync`、⑤.5 `5-5`、⑥ `6` / `6-5` / `6-done`、§0.A.0 `retro-fulfill` | 脚本列变更 → 黑名单 → 跨 story 隔离 → 按 stage 预期产出分类 → `git add --` → sanity check；主 agent 只按退出码 commit |

`harness-commit.py` 退出码：
- **0（STATUS=ok）**：脚本已 stage 好，输出 `SUGGEST_COMMIT_MSG=`（和可能的 `SUGGEST_TAG=`）。主 agent 用 HEREDOC + `Co-Authored-By:` 行 `git commit`，用脚本建议的 message；有 `SUGGEST_TAG` 就**立即** `git tag`。
- **1（STATUS=halt）**：拒绝 commit。按 §3 halt 模板把脚本完整 stdout 贴给用户。
- **2（STATUS=skip）**：没有可提交的变更。跳过 commit；如输出里仍有 `SUGGEST_TAG=`（`build-sync`），照样打 tag。

`build-verify` 退出码：0 = 审计通过；1 = halt（commit 已经存在，主 agent **不撤**，交用户决定）。

**绝对禁止**：
- 主 agent 自己写 `git add` / `git add -A` / `git add .`。
- 主 agent 自己"修复"脚本拒绝的路径（`git checkout -- file`、reset、revert 等）。halt = 用户介入。
- 在 bmad-build-auto 运行前改工作区（它要求干净工作区，否则 HALT）。B1 之前唯一允许的写操作是 `git tag`。

---

## 0. 启动前置

### 0.0 目标范围解析（先做这一步，不可省略）

按 §5 参数表把参数映射到 `LOOP_SCOPE`，并绑定到主 agent 的对话上下文（每条 story 回报、§2 退出条件、§3 halt 模板都会读）：

- `LOOP_SCOPE`：`all` / `single-story` / `single-epic` / `continue-single` / `dry-run`
- `TARGET_KEY`（`single-story` / `continue-single`）
- `TARGET_EPIC`（`single-epic`）

| 参数 | LOOP_SCOPE | 目标解析 | 前置分支 |
|---|---|---|---|
| 无参数 | `all` | — | §0.A |
| `--story` | `single-story` | `TARGET_KEY = $(python3 .claude/harness/scripts/sprint-status.py next)`；退出码 1 → halt | §0.A |
| `--story <key>` | `single-story` | `TARGET_KEY = <key>`；`git rev-parse --verify --quiet harness/<key>/start` 成功 → §0.B 续作；否则 §0.A | §0.A / §0.B |
| `--epic` | `single-epic` | 先 `sprint-status.py next`：退出码 0 → `TARGET_EPIC = $(sprint-status.py epic-of <next>)`，§0.A；退出码 1 → 按 yaml 顺序找最早一个 `epic-N-retrospective` 非 `done` 的 epic，`TARGET_EPIC = N`，再跑 `epic-all-done N`：0 → §0.C；非 0 → halt（提示先 `--continue` 续作中断 story）；都没有 → 回报"sprint 已全部完成"退出 | §0.A / §0.C / 退出 |
| `--epic <num>` | `single-epic` | `TARGET_EPIC = <num>`。`epic-all-done` + `epic-retro-status` 判断：仍有非终态 story → §0.A；全终态且 retro != done → §0.C；全终态且 retro = done → 回报"该 epic 已完成"退出 | §0.A / §0.C / 退出 |
| `--continue` 或 `--continue 继续完成当前这个story` | `continue-single` | `python3 .claude/harness/scripts/harness-state.py --in-flight`（harness 打了 start tag、没有 done tag、sprint-status 也不是 done / wont-do 的 story）：恰好 1 条 → `TARGET_KEY`；多条 → 用 AskUserQuestion 让用户选；为空 → halt | §0.B |
| `--dry-run` | `dry-run` | — | §2 dry-run 分支 |

> `--continue` 以前用 `sprint-status.py find-by-status review` 找目标。BMad 6.11+ 项目里 `review` 也表示"交互式 bmad-build 做完、等合并"，跟中断的 harness 运行无关，所以改用 harness 自己的 tag 判断。

### 0.A 全新启动

依次跑：

0. **运行条件探测**（v0.2.0）：
   ```bash
   bash .claude/harness/scripts/check_bmad_runtime.sh
   ```
   `STATUS=fail` → halt，把每行 `REMEDIATION=` 原样给用户（典型：没装 `uv`；BMad 低于 6.11；嵌套子 agent 被关）。`STATUS=ok` → 记下 `CODEX_IN_BUILD=`（非 `none` 表示 codex 已作为 review layer 挂进 bmad-build-auto，B2 外部 codex 不跑）。
1. `python3 .claude/harness/scripts/sprint-status.py count` — 输出 `<剩余>/<总数>`；文件缺失 → halt，提示先跑 `bmad-sprint-planning`。
2. `git status --porcelain` — **必须为空**（bmad-build-auto 在脏工作区上直接 HALT）。不为空时：
   - `python3 .claude/harness/scripts/harness-state.py --in-flight` 恰好 1 行 → 作为 `<KEY>` 自动切 §0.B，并告诉用户一行："worktree 不干净 + 检测到 harness 在跑的 `<KEY>` → 自动切续作"。
   - 多行 → halt，把列表给用户，请用 `--story <key>` 指定要续作的那条（无法从脏工作区判断改动属于哪条）。
   - 无输出 → halt：工作区有不属于任何 harness 运行的改动，需要用户清理或说明。
3. TaskCreate 按 `LOOP_SCOPE` 建任务（标题 `Sprint: <story_key>`，初始 `pending`）：`all` → 每条 backlog；`single-story` → `TARGET_KEY`；`single-epic` → 该 epic 的每条 backlog。

用一条简短消息告诉用户整体计划：LOOP_SCOPE、预计 story 数、第一条 key、`CODEX_IN_BUILD` 取值。

### 0.A.0 retro DEV items 兑现前置 gate（issue #3；v0.2.0 起对任意 epic 生效）

**动机**：pre-commit gate ① 在有未兑现 `category: dev` retro action item 时拒绝新 story spec 的 commit。bmad-build-auto 在**最后**才 commit，被 hook 拦下时整条 story 的 token 已经花完，而且它会 HALT `finalization left repository dirty`。所以在 dispatch B1 **之前**把这些 dev 项清掉；清不掉就不 dispatch。

本步在 §0.A 末尾、进入 §1 之前执行，每次跨 epic 进入新 epic 的第一条 story 前也再执行一次（见 §2）。

**检测**：

```bash
bash .claude/harness/scripts/grep_pending_dev_retro_items.sh
```

stdout 每个待兑现 dev 项一行 `ITEM<TAB><epic-N-retro><TAB><CODE><TAB><status><TAB><chore_spec|->`，末尾 `_PENDING_DEV_:<N>` / `_WITH_SPEC_:<M>` / `_NO_SPEC_:<K>`。

- `_PENDING_DEV_:0` → 跳过，进 §1。
- `N>0` → 告诉用户：检测到 N 条未兑现 dev retro 项（M 条有 chore_spec 可自动兑现 / K 条缺 spec），先清掉再起跑。

**兑现循环**（对每个有 chore_spec 的 ITEM，逐项串行）：设 `CODE` / `EPIC`（取自 `epic-${EPIC}-retro`）/ `SPEC`（`_bmad-output/implementation-artifacts/$SPEC`）。

1. **实现**：spawn 一个 fresh general-purpose subagent，prompt = `$SPEC` 全文 + "按本 chore spec 的 Tasks & Acceptance 段实现项目代码；这是一次性 chore 兑现，**不走** bmad-build-auto / codex / review 循环；完成后在 spec 的 Tasks checkbox 打勾。只动 spec 描述范围内的项目代码，不碰其它 story 的 artifacts；spec frontmatter 若声明了 `planning_artifacts:` 白名单（issue #9），按 spec 要求回写那些文件也在范围内。不要做任何 git 操作。" + `python3 .claude/harness/scripts/harness-prompt-suffix.py chore` 的 stdout。
2. **翻状态**（两本账都翻）：
   - 用 Edit 把 `sprint-status.yaml` 里 `retro_action_items.epic-${EPIC}-retro.${CODE}` 的 status 翻成 `done`（只动这一行）。
   - 原生 `action_items`：先查有没有这一项 `python3 .claude/harness/scripts/sprint-status.py action-status epic-${EPIC}-retro-${CODE}`（退出码 1 = 没有，旧 retro 或当时缺 uv，跳过）。有的话用上游脚本翻（BMad 规定这是唯一支持的改法）：
     ```bash
     uv run --no-cache .claude/skills/bmad-retrospective/scripts/sprint_status.py update \
       --file "_bmad-output/implementation-artifacts/sprint-status.yaml" --epic ${EPIC} \
       --set-action-status '[{"id":"epic-'"${EPIC}"'-retro-'"${CODE}"'","status":"done"}]'
     ```
     输出 `ok: false` → 原样报告用户，不要手改；上游脚本路径不存在时退回 `sprint-status.py action-status <id> done`（只改那一行 status）。
3. **收口 commit**：`python3 .claude/harness/scripts/harness-commit.py retro-fulfill <CODE> --epic <EPIC>`。`STATUS=ok` → 用 `SUGGEST_COMMIT_MSG` commit；`STATUS=halt` → §3 halt。
4. 全部兑现后重跑 `grep_pending_dev_retro_items.sh` 确认。

**缺 spec 兜底（`_NO_SPEC_` > 0）**：这类 dev 项还没有 stage ⑥.5 落地的 chore spec。主 agent **不**臆造实现，**也不 dispatch B1**——直接 halt（§3 模板），列出这 K 条，给两条路：① `bash .claude/harness/scripts/process_retro_residue.sh --epic <EPIC>` 补 chore spec 后重跑本命令；② solo-dev 评估后手工兑现，或把该项 category 改为 `harness`（在 yaml 行注释里留痕）。

### 0.B 续作

worktree **可以**不干净。

1. 确定 `<KEY>`（`--story <key>` 给定，或 `--continue` / §0.A 自动切入时按 §0.0 / §0.A 规则从 `--in-flight` 取得）。
2. 先跑 §0.A 第 0 步运行条件探测（失败 → halt）。
3. `python3 .claude/harness/scripts/harness-state.py <KEY>` 拿状态 JSON（**必须用脚本**，不要自己 grep git log 推断）。
4. 按 `next_action_code` 切入：

   | code | 动作 |
   |---|---|
   | `build` | §1 B1（spec 已存在时 intent 指向 spec 文件，bmad-build-auto 按 spec status 自己续跑） |
   | `build-verify` | §1 B1 的"验收"一步 |
   | `codex` / `codex-fix` | §1 B2 对应子步 |
   | `followup` | §1 B3（`followup-start` tag 已存在时不要重打，直接 dispatch，bmad-build-auto 按 spec status 续跑） |
   | `followup-verify` | §1 B3 的"验收"一步（follow-up 已经跑完，**不要**再 dispatch B3） |
   | `sync` | §1 B4 |
   | `tag-only` | `git tag harness/<KEY>/done`，进 ⑤.5 / ⑥ 判断 |
   | `blocked` | halt：bmad-build-auto 已 HALT blocked，把 spec `## Auto Run Result`（或还没有 spec 时的 `bmad-build-auto-result-*.md`）里的 Status / blocking condition 贴给用户 |
   | `blocked-dirty` | 按 `next_action` 文本：B2 的 3/4 产物已落地 → 验收 + commit 后再切入 |
   | `done` | 不该续作；按 §0.A 跑下一条 |
   | `not-started` | 按 §0.A 进 §1 B0 |
   | `legacy-*` | 旧流水线 story，见 §1.L |

5. TaskCreate 建一个任务跟踪本 story。
6. B2 fix 续作时 prompt 头部拼 `python3 .claude/harness/scripts/harness-state.py <KEY> --resume-prompt --stage 4` 的输出（codex finding 数 vs 已处理行数），**禁止**主 agent 凭推理自己写"前情提要"。B1 / B3 续作不需要：bmad-build-auto 以 spec 文件为状态源，自己知道从哪一步接。

告诉用户一行切入计划：从哪一步续作 `<KEY>`。

### 0.C Retro-only 启动（`single-epic` 且该 epic 全终态但 retro 未 done）

跳过 §1 B0-B4，直接进阶段 ⑥：

1. `EPIC = $TARGET_EPIC`。
2. `KEY` 取该 epic **最后一条 done story 的 key**（Read `sprint-status.yaml` 的 `development_status:`，在 `${EPIC}-` 开头的 key 里按 yaml 顺序取最后一条 status=done 的），再用 `sprint-status.py epic-of $KEY` 验证 = `$EPIC`。**禁止**传空串或编造 key（`harness-commit.py` 的 key 位参必填）。
3. 无条件执行阶段 ⑥（含格式契约段，不要因为是 retro-only 就省略），然后 ⑥.5。

完成后回到 §2：`single-epic` + retro 已 done → 退出。

---

## 0.5 路径预期产出表

`harness-commit.py` / `build-verify` 内置规则的可读版。主 agent 看它是为了理解"为什么"，不是为了按表手工 `git add`。路径前缀 `_bmad-output/implementation-artifacts/` 省略。

| 阶段 | 谁 commit | 允许的路径 |
|---|---|---|
| B1 build / B3 follow-up | bmad-build-auto | 项目代码 + `spec-$KEY.md`（或 `spec-$KEY-<n>.md`）+ `epic-<N>-context.md` + `deferred-work.md`（spec Tasks 要求翻转既有 FU 时）+ spec frontmatter `cross_story_artifacts:` / `planning_artifacts:` 声明的路径。build-verify 事后审计，越界即 halt |
| B2 `3` `story($KEY): codex adversarial review report` | 主 agent | **仅** `$KEY.codex-review.md`（catchup 时另含 `$KEY.codex-skipped.resolved.json`） |
| B2 `4` `story($KEY): apply codex review fixes` | 主 agent | 项目代码 + spec（`### Codex Review Handling (Stage 3)` 段）+ `deferred-work.md` |
| B4 `build-sync` `story($KEY): sync sprint status & deferred ledger` | 主 agent | `sprint-status.yaml`（$KEY → done；epic backlog → in-progress）+ `deferred-work.md`（spec `deferred:` 导入的 `FU-<X.Y>.B<n>`）+ `$KEY.codex-skipped.json`（如有）。无变更 → STATUS=skip，仍打 done tag |
| ⑤.5 `5-5` / 测试 T1/T3/T4 | 主 agent / run-test 子 agent | `test_artifacts/$KEY-test-result.json` 或 `test_artifacts/skipped-$KEY-*.md` + `<frontend_dir>/<e2e_test_subdir>/$KEY*.spec.ts` + `sprint-status.yaml` + `deferred-work.md`（详 [`run-test.md`](run-test.md)） |
| ⑥ `6` `epic($EPIC): retrospective` | 主 agent | `epic-${EPIC}-retro-*.md` + `sprint-status.yaml` + `deferred-work.md` |
| ⑥.5 `6-5` `chore(retro-c$EPIC): process residue → N chore specs` | 主 agent | `chore-retro-c${EPIC}-<code>-<slug>.md` × N + `sprint-status.yaml`（仅 retro_action_items 子段） |
| ⑥ `6-done` `epic($EPIC): mark done` | 主 agent | **仅** `sprint-status.yaml` |
| §0.A.0 `retro-fulfill <CODE> --epic <EPIC>` | 主 agent | 项目代码 + `sprint-status.yaml` + `deferred-work.md` + `chore-retro-c${EPIC}-<CODE>-*.md` |

**halt 类条件**（两种守门方式共用）：凭据黑名单（`.env*` / `*.pem` / `_bmad/**` / `.claude/**` 子集）；跨 story 隔离（`<other-key>.*` / 别的 story 的 spec）；`_bmad-output/` 下 implementation-artifacts 以外的路径（`planning_artifacts:` 白名单除外）；预期外 artifact；禁止项目代码的 stage 出现项目代码。

**spec frontmatter 白名单**：`cross_story_artifacts:`（bare basename，`.md`）和 `planning_artifacts:`（完整路径，限 `planning-artifacts/` 子树，`.md`）。写法与约束见 `.claude/harness/prompt-suffixes/bmad-build-auto-suffix.md` §4/§5。

**自动剔除（不 halt）**：仓库根的 Go 构建二进制（`AUTO_FIXED=binary-blob`）、子 agent 多产的 `<KEY>.bmad-code-review.md` 等额外 .md（`AUTO_FIXED=unexpected-md`）、`<KEY>.maven-skipped.json` 等过程 marker（`AUTO_FIXED=process-marker`）。只作用于 harness 自己 commit 的阶段。

---

## 1. 单条 story 流水线（严格顺序）

设当前 story key = `$KEY`，short id = `<epic>.<seq>`（`3-2-digest-delivery` → `3.2`），`EPIC = $(python3 .claude/harness/scripts/sprint-status.py epic-of $KEY)`。spec 路径一律用 `python3 .claude/harness/scripts/harness-state.py $KEY --story-md` 取，或用 build-verify 输出的 `SPEC_FILE=`。bmad-build-auto 不一定照 `spec-$KEY.md` 命名（中文 key 常被转写成英文 slug），harness 按 `spec-<epic>-<seq>-*.md` 的编号前缀识别，所以不要自己拼路径。

### B0：起跑

- TaskCreate 任务标 `in_progress`。
- **工作区必须干净**（每条 story 都查，不只启动时）：`git status --porcelain` 非空 → halt。上一条 story 的 ⑤.5 / ⑥ 残留、用户在两条 story 之间的改动都会让 bmad-build-auto 在 step-01 直接 HALT。
- **打 start tag**（撤回点，必须在 dispatch 之前）：`git tag harness/$KEY/start`
  - 任何阶段想整条撤回：`git reset --hard harness/$KEY/start`。
  - **tag 已存在**（续作场景没走 `--continue`）→ 不 halt：调 `harness-state.py $KEY`，按 §0.B 表切入。只有 `next_action_code == "done"` 才 halt（sprint-status 有脏数据）。
- **Deferred-work 注入（C11）**：

  ```bash
  DEFERRED_INJECT=$(bash .claude/harness/scripts/grep_pending_deferred_for_story.sh "$KEY" 2>&1)
  GREP_EXIT=$?
  [ "$GREP_EXIT" -ne 0 ] && { echo "halt: deferred-work grep 失败 exit=$GREP_EXIT"; exit 1; }
  ```
- **epic 第一个 story（key 匹配 `^[0-9]+-1-` 且 epic > 1）**：另跑 `bash .claude/harness/scripts/grep_prev_retro_action_items.sh $EPIC`，输出作为继承段（C7）的参考上下文一起放进 intent。

### B1：Build（独立 general-purpose subagent 内跑 bmad-build-auto）

```
Agent({
  subagent_type: "general-purpose",
  description: "Build story <KEY>",
  prompt: <Build intent> + "\n\n---\n\n" + <`harness-prompt-suffix.py build` 的 stdout>
})
```

**同步等待**，不要 `run_in_background`。

`<Build intent>` 按 `harness-state.py $KEY` 的 `spec_status` 选：

- `spec_status` 是 `done` 或 `blocked`（harness 之外已经有人跑过 bmad-build）→ **不 dispatch**，halt：done 的说明该 story 已在 harness 之外完成，请用户确认后自己推进 sprint-status（或删掉 spec 重跑）；blocked 的贴出 spec `## Auto Run Result`。
- 为空 → 下面的「首次」；draft / ready-for-dev / in-progress / in-review → 「续跑」。

- **首次**：

  > ## Build intent
  >
  > 实现 sprint-status.yaml 里的 epic story `<KEY>`（Story <short id>，Epic <EPIC>）。需求以 planning artifacts 中 epics 文件里该 story 的定义为准。spec 文件名用 `spec-<KEY>.md`（key 含中文时也照抄，不要转写）。
  >
  > 当前分支 `<git branch --show-current 的结果>` 是 solo-dev 为本轮 sprint 指定的工作分支，会连续承载多个 epic 的 story；分支名与本 story 不对应不算 branch mismatch。
  >
  > ## Deferred-work 待消化提示（auto-injected by C11）
  >
  > <`$DEFERRED_INJECT` 原样>
  >
  > （epic 第一个 story 时再加）## 前置 retro action items 状态
  >
  > <`grep_prev_retro_action_items.sh` 输出原样>

- **续跑**（spec 已存在，status 为 draft / ready-for-dev / in-progress / in-review）：

  > ## Build intent
  >
  > 继续 spec 文件 `<spec 路径>`（story `<KEY>`）。按该 spec frontmatter 的 status 从对应步骤续跑。

跑 bmad-build-auto 的 subagent 本身会再起 reviewer / 实现子 agent（嵌套，Claude Code 默认允许 3 层），这是预期行为。

**验收**：

```bash
python3 .claude/harness/scripts/harness-commit.py build-verify $KEY
```

- **STATUS=ok** → `git tag harness/$KEY/built`。记下输出里的 `SPEC_FILE=`（后续所有"spec 路径"都用它）、`FOLLOWUP_RECOMMENDED=` 与 `CODEX_LAYER_SKIPPED=`。
  - `CODEX_LAYER_SKIPPED=true`（codex 挂在 build 里但这一轮被跳过，常见原因是超时 / 额度）→ 现在只显示 §B2.1 b) 的通知框；marker 文件推迟到 B4 第 0 步再写（B3 可能还要跑 bmad-build-auto，它要求干净工作区）。
- **STATUS=halt**，按诊断行处理（都走 §3 halt 模板，commit 已存在、主 agent 不撤）：
  - `SPEC_STATUS_NOT_DONE=blocked` + `AUTO_RUN_RESULT=` 行：bmad-build-auto 自己 HALT 了（intent gap、spec 不达标、验证失败、review 修复循环 > 5 轮不收敛等）。把 blocking condition 贴给用户。
  - `BUILD_AUTO_RESULT=` + `AUTO_RUN_RESULT=` 行：bmad-build-auto 还没建 spec 就 HALT 了（脏工作区、分支不符、intent 不清、缺前序 story 连续性决定、uv 失败等）。贴给用户，不要重新 dispatch——同样的条件会让它再 HALT 一次。
  - `SPEC_STATUS_NOT_DONE=<其它>` 或 `SPEC_MISSING=`：subagent 中途退出。先看返回文本有没有配额信号（有 → 配额模板）；没有 → 普通 halt。
  - `DIRTY_WORKTREE=`：跑完留下未提交文件。
  - `BLACKLIST=` / `CROSS_STORY=` / `OUT_OF_SCOPE_BMAD=`：区间里出现越界路径。
  - `NO_CODE_CHANGE=`：spec 标 done，但区间里除了 implementation-artifacts 下的文件什么都没改（可疑的"空实现"）。

### B2（条件触发）：外部 codex 对抗 review + 修复

**触发条件**：`CODEX_IN_BUILD=none`（codex 没挂进 bmad-build-auto）。挂了就整段跳过——codex 已经在 B1 的 review 层里跑过，重复跑等于每条 story 付两次 codex 费用。

review base：`BASE = build-verify 输出的 BASELINE_REVISION`（spec frontmatter `baseline_revision`，即 bmad-build-auto 开始改代码前的 HEAD）；没有就用 `git rev-parse harness/$KEY/start`。

#### B2.0 Pre-flight

```bash
CODEX_PROBE_JSON="$(bash .claude/harness/scripts/check_codex_availability.sh)"
CODEX_AVAILABLE="$(printf '%s' "$CODEX_PROBE_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["available"])')"
```

`CODEX_AVAILABLE = False` → §B2.1；否则 §B2.2。

#### B2.1 Skip 路径（codex 不可用时显式跳过）

> codex-in-cc 不可用是预期内的情况（额度、未登录、未装、网络）。允许跳过，但**绝不静默**：必须写 marker + 显式通知，供事后 `/harness-zh:codex-catchup` 补跑。

触发来源：B2.0 pre-flight 命中；B2.2 codex subagent 返回文本含 `hit your limit` / `rate limit` / `usage limit` / `quota` / `not logged in` / `unauthorized` / `auth required` / `please log in`；B1 验收 `CODEX_LAYER_SKIPPED=true`。

##### a) 写 marker `<KEY>.codex-skipped.json`

```bash
TS_ISO="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
cat > "_bmad-output/implementation-artifacts/${KEY}.codex-skipped.json" <<EOF
{
  "key": "${KEY}",
  "reason": "<reason>",
  "skipped_at": "${TS_ISO}",
  "skipped_at_stage": 3,
  "stage2_base_sha": "<BASE>",
  "remediation": "<remediation 文本>",
  "catchup_command": "/harness-zh:codex-catchup --story ${KEY}"
}
EOF
```

`<reason>`：`not_installed`（pre-flight）/ `quota_exhausted` / `auth_failed` / `unknown`（in-flight）/ `in_build_layer_skipped`（B1 验收）。字段名 `stage2_base_sha` 沿用旧 schema，值填本节的 `BASE`。

##### b) 显式通知用户（不退出）

```
┌──────────────────────────────────────────────────────────────────┐
│ ⚠️  codex-in-cc 不可用 — codex review 已跳过 <KEY>               │
│                                                                  │
│   reason       : <reason>                                        │
│   remediation  : <pre-flight 取 probe JSON.remediation；其它来源 │
│                  给一句"等额度恢复 / 登录后重跑">                 │
│                                                                  │
│ Story 继续往下走（B3 按需 → B4 → done）。marker 已写：           │
│   _bmad-output/implementation-artifacts/<KEY>.codex-skipped.json │
│                                                                  │
│ 待 codex 恢复后跑：/harness-zh:codex-catchup --story <KEY>       │
│ 或 /harness-zh:codex-catchup 一次性补跑所有 skip 的 story。      │
└──────────────────────────────────────────────────────────────────┘
```

##### c) 跳过 B2 余下部分

不跑 `harness-commit.py 3` / `4`。a) 的 marker 文件**推迟到 B4 第 0 步写**（同一个 reason），由 `build-sync` 一起入库——B3 若还要跑，bmad-build-auto 需要干净工作区。

#### B2.2 codex review（独立 general-purpose subagent）

```
Agent({
  subagent_type: "general-purpose",
  description: "Codex adversarial review <KEY>",
  prompt: <以下 prompt> + <`harness-prompt-suffix.py 3` 的 stdout>
})
```

prompt 核心：

> 请按两步执行，不要做任何 git 操作（add / commit / push / branch / tag / amend / mv / rm / restore --staged / stash 都不要）：
>
> **第 1 步：跑 codex 对抗式审查**
>
> **不要试 Skill tool 调用 `/codex:adversarial-review`**——它的 frontmatter 是 `disable-model-invocation: true`，Skill 调用会被拒。直接用 Bash 跑：
>
> ```bash
> node "<CODEX_COMPANION_PATH>" adversarial-review --wait --base <BASE> "review focus: story <KEY> 的代码实现（spec 在 <spec 路径>，作为验收标准上下文，review 对象是代码 diff）"
> ```
>
> **第 2 步：把 codex 返回的报告写到固定路径**
>
> 用 Write 把 codex stdout 完整写入 `_bmad-output/implementation-artifacts/<KEY>.codex-review.md`，前面加 frontmatter：
>
> ```
> ---
> story: <KEY>
> base: <BASE>
> head: <git rev-parse HEAD 的结果>
> reviewer: codex-adversarial
> ---
> ```
>
> 然后**逐字粘贴** codex 的完整 stdout（不总结、不润色、不重排；codex 没分级就不要自己强行分级）。两步做完后停止。

调用前主 agent 替换占位符：
- `<BASE>`、`<spec 路径>`（见上）。
- `<CODEX_COMPANION_PATH>`：
  ```bash
  CODEX_COMPANION_PATH="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts/codex-companion.mjs}"
  [ -z "$CODEX_COMPANION_PATH" ] || [ ! -f "$CODEX_COMPANION_PATH" ] && \
    CODEX_COMPANION_PATH=$(ls ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)
  ```
  两条都为空 → 走 §B2.1（reason `not_installed`）。

等待返回。返回文本含 codex 不可用关键词 → §B2.1。

**验收**：`<KEY>.codex-review.md` 存在且 ≥ 200 字节，含 `base: <BASE>` 行；否则 halt。

**commit**：`python3 .claude/harness/scripts/harness-commit.py 3 $KEY`。

#### B2.3 codex 修复（fresh general-purpose subagent，有意不走 BMad 工作流）

本步是 B1 实现的延续：codex 的每条 finding 都是 B1 没做好或漏掉的部分。没有契合"按外部 review 反馈修已完成代码"的 BMad 工作流，所以直接 freelance + 断点续作约定。统一 spawn fresh agent（跨会话 agentId 无效），让它从产物文件重建上下文。

```
Agent({
  subagent_type: "general-purpose",
  description: "Dev fix codex findings <KEY>",
  prompt: <以下 prompt> + <`harness-prompt-suffix.py 4` 的 stdout>
})
```

prompt 核心：

> 你是续作 dev agent。story <KEY> 已由 bmad-build-auto 实现并 commit，codex 对抗式 review 已写到固定路径。现在逐条处理 codex 的 finding。
>
> **先做的事（按顺序）**：
> 1. Read spec `<spec 路径>`（`<intent-contract>` 内只读）。
> 2. Read `_bmad-output/implementation-artifacts/<KEY>.codex-review.md`（主体 + 附录）。
> 3. 如果 spec 末尾已有 `### Codex Review Handling (Stage 3)` 段并记录了部分处理，按断点续作约定跳过已处理项。
>
> **处理顺序**：codex 自带分级就从重到轻；没有就按列出顺序。附录里的 finding 同样处理。
>
> **每条 finding 三选一**：
> - **fixed**：改源码，列出改了哪些文件 + 简述
> - **wontfix**：给出能追溯到 `.claude/harness/answer-policy.md` 项目语境的理由
> - **deferred**：按 schema v1 在 `deferred-work.md` 立 FU（`[source:codex-review-of-<short id>]`），处理记录里引用 FU id
>
> 每处理完一条，**立即**在 spec 文件末尾的 `### Codex Review Handling (Stage 3)` 段（没有就新建，放在 `<intent-contract>` 之外）追加一行：`- [F-1 high] <短描述> — fixed: 改了 <files>` / `- [F-2 medium] <...> — deferred: FU-x.y.z`。这是断点续作的 progress 来源。
>
> 结束条件：所有 finding 各有一条处理记录。然后停止，不要做任何 git 操作。修源码直接用 Edit。

**验收**：spec 的 `### Codex Review Handling (Stage 3)` 段行数 = codex finding 数。

**commit**：`python3 .claude/harness/scripts/harness-commit.py 4 $KEY`。B2.3 commit 之后 **B3 必跑**（修复代码还没被 review 过）。

### B3（条件触发）：follow-up review（bmad-build-auto 对 done spec 再跑一轮 review）

**触发条件**（任一）：B2.3 commit 了修复；B1 验收 `FOLLOWUP_RECOMMENDED=true`。都不满足 → 跳过。**每条 story 最多一轮**。

dispatch 之前先 `git tag harness/$KEY/followup-start`（续作时据此区分"还没跑"和"跑完待验收"，避免重复跑第二轮）。

```
Agent({
  subagent_type: "general-purpose",
  description: "Follow-up review <KEY>",
  prompt: "## Build intent\n\n对已完成的 spec `<spec 路径>`（story `<KEY>`）做一轮 follow-up review：直接把这个 spec 文件路径交给 bmad-build-auto（status done 的 spec 会进入新一轮 review pass，审查 baseline 以来的全部改动，包括 codex 修复）。\n\n---\n\n" + <`harness-prompt-suffix.py build` 的 stdout>
})
```

**验收**：再跑 `python3 .claude/harness/scripts/harness-commit.py build-verify $KEY`。STATUS=ok → `git tag harness/$KEY/followup`；halt 处理同 B1。

这一轮之后 `FOLLOWUP_RECOMMENDED` 仍为 `true` → 不再循环，在本 story 回报里写一行"bmad-build-auto 仍建议再 review：<spec `## Auto Run Result` 里点名的风险>"，交给用户决定。

### B4：build-sync（harness 自己的收口 commit）

**第 0 步：补写 codex-skipped marker**。本 story 在 B1 验收看到 `CODEX_LAYER_SKIPPED=true`，或 B2 走了 §B2.1 skip → 现在按 §B2.1 a) 写 `<KEY>.codex-skipped.json`（reason 分别为 `in_build_layer_skipped` / pre-flight 或 in-flight 的 reason）。续作场景记不清时：`harness-state.py $KEY` 的 `codex_layer_skipped: true` 即前者；后者会被 harness-state 路由回 `codex` 重新探测，不会走到这里。

```bash
python3 .claude/harness/scripts/harness-commit.py build-sync $KEY
```

脚本内部：把 spec frontmatter `deferred:` 里尚未导入的条目追加进 `deferred-work.md`（schema v1，`FU-<short id>.B<n>`，`[source:build-auto-of-<short id>]`）；`sprint-status.yaml` 里 `$KEY → done`，所属 epic `backlog → in-progress`；连同 `<KEY>.codex-skipped.json`（如有）一起 stage。

- STATUS=ok → 用 `SUGGEST_COMMIT_MSG` commit，然后 `git tag harness/$KEY/done`（`SUGGEST_TAG`）。`SPRINT_STATUS_AUTO_SYNC=import-deferred key=FU-...` 行是信息。
- STATUS=skip → 不 commit，照样 `git tag harness/$KEY/done`。
- STATUS=halt → §3。

**deferred-work 趋势输出**（不阻流）：

```bash
SHORT=$(echo "$KEY" | awk -F- '{print $1"."$2}')
if STATUS_OUT=$(bash .claude/harness/scripts/grep_deferred_status.sh "$KEY" 2>/dev/null); then
    SUMMARY=$(echo "$STATUS_OUT" | grep -E '^Story ' || true)
    echo "deferred-work（story $SHORT）：${SUMMARY:-无命中条目}"
else
    echo "deferred-work（story $SHORT）：报告生成失败"
fi
```

`git log --oneline harness/$KEY/start..harness/$KEY/done` 即本 story 完整提交序列。TaskCreate 任务标 `completed`。

### 阶段 ⑤.5（条件触发）：Test Harness Invocation

B4 完成（sprint-status `$KEY` = done）后、阶段 ⑥ 判断之前，自动调用 `/harness-zh:run-test` 跑本 story 的 atdd + e2e。触发评估在 run-test 内部完成（`eval_test_stage_triggers.sh` 读 `test-stage-triggers.yaml` + `harness-project-config.yaml`），本阶段只负责调用 + sanity gate。

1. spawn：

   ```
   Agent({
     subagent_type: "general-purpose",
     description: "Test sprint <KEY>",
     prompt: <以下 prompt>
   })
   ```

   > 请直接调用 /harness-zh:run-test --story $KEY。这是 run-sprint stage 5.5 自动触发，必须以 non-interactive 模式运行（任何 <ask> 节点都不要发问，按 `.claude/harness/answer-policy.md` 自决）。
   >
   > subagent 内部走 T3 + T4 双 commit（commit message 含 "(run-sprint stage 5.5)" 后缀）；sandbox graceful skip 路径内部写 skipped-*.md + 跑 T4 commit。完成后停止，主 agent 只会跑 5-5 做 sanity gate（期待 STATUS=skip）。
   >
   > **任务追踪工具禁令（issue #9）**：禁止调用 TaskCreate / TaskUpdate / TaskList 等任务管理工具——sprint 任务清单由 run-sprint 主 orchestrator 独占维护。你的进度只通过最终返回 message 汇报。

2. **验收**：`test_artifacts/$KEY-test-result.json` 或 `test_artifacts/skipped-$KEY-*.md` 至少一个存在；都没有 → halt。
3. **5-5 sanity gate**：`python3 .claude/harness/scripts/harness-commit.py 5-5 $KEY`：期望 STATUS=skip；STATUS=ok（中断遗留的旧路径）→ 用 SUGGEST_COMMIT_MSG commit；STATUS=halt → §3。

测试失败 ≠ halt：verdict=red 只写 deferred-work `FU-Test-$KEY-failing` + result.json，阶段 ⑥ 照常触发。

### 阶段 ⑥（条件触发）：Epic Retrospective

```bash
EPIC=$(python3 .claude/harness/scripts/sprint-status.py epic-of $KEY)
if python3 .claude/harness/scripts/sprint-status.py epic-all-done $EPIC; then
    RETRO_STATUS=$(python3 .claude/harness/scripts/sprint-status.py epic-retro-status $EPIC || echo missing)
    # 只有 RETRO_STATUS != done 才跑
fi
```

（`epic-all-done` 把 `done` 与 `wont-do` 都算终态。）

```
Agent({
  subagent_type: "general-purpose",
  description: "Retrospective epic <EPIC>",
  prompt: <以下 prompt> + <`harness-prompt-suffix.py 6` 的 stdout>
})
```

prompt 核心：

> 用 Skill 工具调用 `bmad-retrospective`，参数 `-H <EPIC>`（BMad 6.12 的无人值守接口：不提问、不开 team discussion、verdict 只看证据，所有替用户做的假设记进文档 Assumptions 段）。
>
> **格式契约（强制，先做）**：先 Read `.claude/harness/prompt-suffixes/bmad-retrospective-suffix.md` 并全程遵守。要点：
> 1. Phase 1 Gather 之后、Phase 2 Analyze 之前先跑 `bash .claude/harness/scripts/run_retro_self_audit.sh <EPIC-1>`（失败不阻断，§2 表格手工填）。
> 2. Action items 段**必须**按其 Form 1 书写（每条一个 H3：`### <code> — <标题>`），每条声明 `**Category**: dev` 或 `**Category**: harness`，owner 写 `solo-dev`。
> 3. Phase 5 的 `--add-action` JSON 每条显式给 `id: "epic-<EPIC>-retro-<CODE>"`（与 H3 code 一致），不要传 `--set-action-status`。
> 4. retro 文档 frontmatter 必须有 `verdict`。
>
> 不合规形态（编号列表 / 表格）会让 stage 6 commit 的 parser 全 0 命中 → fail-loud halt。
>
> 完成后停止，不要做任何 git 操作。

等待返回。
- **瞬态 API 错误重试（issue #9 finding 4）**：retro subagent 死于瞬态 infra 错误（如 `API Error: Overloaded`，**不是**配额信号）且 `git status --porcelain` 干净 → 重新 dispatch 一次，不 halt；仍失败 → §3 halt。worktree 不干净 → 不重试，§3 halt。

**验收**：至少一份新的 `epic-${EPIC}-retro-*.md`，非空。

**commit row 6**：`python3 .claude/harness/scripts/harness-commit.py 6 $KEY --epic $EPIC`。脚本内部把 `epic-${EPIC}-retrospective` / `epic-${EPIC}` 翻 done（retro 的 sprint_status.py 已翻过则 no-op），从 retro md 解析 Form 1 H3 条目 seed `retro_action_items.epic-${EPIC}-retro`。STATUS=ok 输出含 `RETRO_VERDICT=<accepted|accepted-with-open-items|rejected|missing>`，**记下它**。

**commit row 6-done**：`python3 .claude/harness/scripts/harness-commit.py 6-done $KEY --epic $EPIC`（通常 STATUS=skip）。

当前 story 不是该 epic 最后一条 → 跳过本阶段。

### 阶段 ⑥.5（条件触发）：Retro Residue Processing（Chore C10）

阶段 ⑥ commit 完成后触发，把 retro 里 pending / partial / in-progress 的 action items 转成可执行的 `chore-retro-c${EPIC}-<code>-<slug>.md` spec。

1. `bash .claude/harness/scripts/process_retro_residue.sh --epic $EPIC`：退出码 0 → stdout 含 fresh agent prompt + retro 全文 + 待处理列表；2 → "no residue to process"，跳过本阶段；1 → halt。
2. 把 stdout 交给 fresh general-purpose agent（`description: "Process retro residue epic-<EPIC>"`）。
3. agent 返回多个 `=== FILE: chore-retro-c${EPIC}-<code>-<slug>.md ===` / `=== END FILE ===` 块 + 一个 `=== MANIFEST === / <code>: <dev|harness> / === END MANIFEST ===` 块 + ≤ 200 字总结（详 [`.claude/harness/architecture.md`](../harness/architecture.md) §六 Q4）。
4. 逐个 FILE block 用 Write 写到 `_bmad-output/implementation-artifacts/<filename>`。
5. 解析 MANIFEST：缺失 / 行数不一致 / 取值非法的项一律默认 `harness`，输出一行 `MANIFEST_FALLBACK=<reason>`，**不** halt。
6. 用 Edit 在 `retro_action_items.epic-${EPIC}-retro.<code>` 下追加 `chore_spec: '<filename>'` 与 `category: <dev|harness>`。**不**加 `chore-retro-cN-residue:` 段，**不**动 `development_status:`。
7. **sanity check**：
   - `grep -E "chore-retro-c[0-9]+-residue:" .../sprint-status.yaml` 必须为空
   - `git diff sprint-status.yaml` 只触及 retro_action_items 子段
   - `ls .../chore-retro-c${EPIC}-*.md | wc -l` ≥ 待处理数
   - 每个新 spec 都含 `frozen-after-approval` / `Tasks & Acceptance` / `Code Map`
   - 新 spec 不含"自动生成 / fresh agent / auto-generated"字样
   - `bash .claude/harness/scripts/check_retro_action_items.sh` 仅看 stderr 有无新增 WARN（信息性）
8. **commit row 6-5**：`python3 .claude/harness/scripts/harness-commit.py 6-5 $KEY --epic $EPIC`。

halt 触发：agent 输出非法（缺 FILE marker / 结构破损 / 含禁用字样）→ 不写文件 + halt；spec 命名冲突 → halt；sanity check 前 5 项任一失败 → halt；6-5 STATUS=halt → §3。⑥.5 halt 不影响 epic retro 已 done 的事实。

### 阶段 ⑥ 之后：verdict 门

verdict 取自 commit row 6 或 6-done 输出的 `RETRO_VERDICT=`（两处都会打印；续作只跑到 6-done 时也能拿到），同时看 `EPIC_WONT_DO=`。

`RETRO_VERDICT=rejected` → 本 epic 被 retro 判为不通过（上游语义：有非 `done` 的 story，或 acceptance criteria 不满足）。⑥.5 / 6-done 照常做完，然后：
- `EPIC_WONT_DO=none` 且 `LOOP_SCOPE = all` → **halt**（§3 模板），不进入下一个 epic；把 retro 文档的 Acceptance verdict 段和 Open questions 段要点贴给用户。
- `EPIC_WONT_DO=<keys>`：上游把 `wont-do` 也算未完成，会强制判 `rejected`，这类 epic 每次都会是 rejected。不 halt，在回报里醒目写一行"verdict=rejected，可能只是 wont-do 的 <keys> 触发；请看 retro 文档 Acceptance verdict 段确认是否还有其它原因"，然后继续。
- 其它 scope → 在最终回报里醒目标注。

`accepted-with-open-items` → 回报里列出 open items 所在段落，不阻流。`missing`（旧格式 retro）→ 不判断。

### 1.L 旧流水线 story（plugin ≤ 0.1.39 启动、未完成）

`harness-state.py` 的 `pipeline = legacy`（有 `story(<KEY>): create story spec` commit、没有 `spec-<KEY>.md`）。BMad 6.11+ 里 `bmad-create-story` / `bmad-dev-story` 不再安装，所以：

| code | 处理 |
|---|---|
| `legacy-stage2` | 无法续作。halt，告诉用户：`git reset --hard harness/<KEY>/start` 后删掉 `<KEY>.md`，再 `/harness-zh:run --story <KEY>` 走新流水线 |
| `legacy-stage3` / `legacy-stage4` | 按 B2.2 / B2.3 执行，`BASE` 用 `harness-state.py` 的 `stage2_base_sha`，spec 路径是 `<KEY>.md` |
| `legacy-stage5` | 调 `bmad-code-review`：review target = commit range `<stage2_base_sha>..HEAD`（diff 用 `git diff <range> -- . ':!.claude'`），spec_file = `<KEY>.md`，所有 HALT / CHECKPOINT 按 answer-policy 自决、patch 选 "Apply every patch"；另写 `<KEY>.review-findings.json`（`unresolved` / `resolved` / `final_story_status`）。验收后 `harness-commit.py 5 $KEY` + `git tag harness/<KEY>/done`。prompt 后缀用 `harness-prompt-suffix.py 5` |

旧流水线的完整说明在 `.claude/harness/changelog.md` v0.1.39 及更早条目。

---

## 2. 主循环

```
# 顶层 dry-run 分支
if LOOP_SCOPE == "dry-run":
  跑 check_bmad_runtime.sh 并显示结果
  按目标范围枚举每条预期会跑的 story，每条输出一行：B1 → [B2 若 CODEX_IN_BUILD=none] → [B3 按需] → B4 → ⑤.5 → [⑥]
  不调任何子 agent、不 commit
  退出

if LOOP_SCOPE == "single-epic" and 已走 §0.C: 跑阶段 ⑥ + ⑥.5；退出
if LOOP_SCOPE == "continue-single": 按 §0.B 切入点跑 $TARGET_KEY 剩余步骤（含触发的 ⑤.5 / ⑥）；退出
if LOOP_SCOPE == "single-story": 跑 $TARGET_KEY 的 B0…B4（含触发的 ⑤.5 / ⑥）；退出

# 默认循环（all 或 single-epic 且该 epic 仍有 backlog）
loop:
  if LOOP_SCOPE == "single-epic":
    next_key = `sprint-status.py next-in-epic $TARGET_EPIC`   # 不要用全局 next
    if 该 epic 无 backlog:
      if `epic-retro-status $TARGET_EPIC` != "done":
        if `epic-all-done $TARGET_EPIC` 退出码 0: 走 §0.C 触发 retro
        else: halt（该 epic 有 story 停在中途；提示先 --continue）
      break
  else:
    next_key = `sprint-status.py next`
    if 无 backlog: break

  if next_key 属于一个新 epic（与上一条不同）: 重跑 §0.A.0（新 epic 起跑前清 retro dev 阻塞）
  跑 B0…B4、⑤.5
  跑 ⑥ / ⑥.5（仅当它是该 epic 最后一条且 retro 未 done）
  if RETRO_VERDICT == "rejected" and EPIC_WONT_DO == "none" and LOOP_SCOPE == "all": halt（见 "verdict 门"）
  回报一行进度（"M/N 完成 (LOOP_SCOPE=<value>)"）
goto loop

report "🎉 完成 (LOOP_SCOPE=<value>, target=<key 或 epic 或 —>)"

# Codex-skipped 提醒
SKIPPED_COUNT=$(ls _bmad-output/implementation-artifacts/*.codex-skipped.json 2>/dev/null | wc -l | tr -d ' ')
if SKIPPED_COUNT > 0:
    打印醒目通知：
        ┌──────────────────────────────────────────────────────────────────┐
        │ ⚠️  Codex review pending — 仍有 N 条 story 没做 codex review     │
        │                                                                  │
        │ Marker 文件：                                                    │
        │   <每个 *.codex-skipped.json basename + reason>                  │
        │                                                                  │
        │ 待 codex 恢复后跑：/harness-zh:codex-catchup                     │
        └──────────────────────────────────────────────────────────────────┘

report "💡 这一轮如果有 plugin 行为不顺手 / 文档误导 — 跑 /harness-zh:report-issue（自动收集上下文，一键提到 Niutie/my-cc-plugin）"
```

SKIPPED_COUNT 必须用 Bash 实跑，> 0 时必须完整打印通知框。每次回到循环顶部都重新检查 LOOP_SCOPE。

---

## 3. 死循环 / 失控防护（**必须严格遵守**）

任何一项触发都立即 halt，不要尝试自愈。子 agent 提问 / 请求确认不在此列（按 §−1.b 处理）。

| 触发条件 | 处理 |
|---|---|
| §0.A 第 0 步 `check_bmad_runtime.sh` STATUS=fail | halt，贴 `REMEDIATION=` 行 |
| 子 agent 返回含配额耗尽信号（`hit your limit` / `rate limit` / `usage limit` / `quota` / `reset` 时间） | halt + 配额模板（选项 5）。**B2 codex 例外**：走 §B2.1 skip+marker |
| `build-verify` STATUS=halt（`SPEC_STATUS_NOT_DONE=` / `SPEC_MISSING=` / `BUILD_AUTO_RESULT=` / `AUTO_RUN_RESULT_MISSING=` / `DIRTY_WORKTREE=` / `BLACKLIST=` / `CROSS_STORY=` / `OUT_OF_SCOPE_BMAD=` / `NO_CODE_CHANGE=`） | halt，贴脚本完整 stdout。commit 已存在，**不撤** |
| B0 工作区不干净 | halt |
| `harness-commit.py` 退出码 1 | halt，贴脚本完整 stdout（`BLACKLIST=` / `CROSS_STORY=` / `UNEXPECTED_ARTIFACT=` / `FORBIDDEN=` / `UNSTAGED=` 等） |
| 预期产物缺失或为空（各阶段"验收"项） | halt。⑥ 瞬态 infra 错误 + 干净工作区允许重试一次（见阶段 ⑥） |
| §0.A.0 仍有 `_NO_SPEC_` dev retro 项 | halt，不 dispatch B1 |
| §0.A 工作区不干净且没有 in-flight story | halt |
| 子 agent 返回缺 `git status --porcelain` 自报段 | 不 halt，主 agent 自己跑一次交叉核对；发现子 agent 改了它没声称改过的文件 → halt |
| `RETRO_VERDICT=rejected` 且 `EPIC_WONT_DO=none` 且 `LOOP_SCOPE=all` | halt，不进下一个 epic |
| 单条 story 主步骤（B1 / B2.2 / B2.3 / B3）累计 dispatch > 5 个子 agent（4 个 + 至多 1 次中断重启）。⑤.5 / ⑥ / ⑥.5 / §0.A.0 不计入，各有上限：⑤.5 每 story 1 个；⑥ / ⑥.5 每 epic 各 1 个（另允许至多 1 次额外重启，配额重启与 ⑥ 瞬态重试合计）；§0.A.0 每个 dev 项 1 个 | halt |
| 想第二次进入"B2 修复 → B3 review"循环 | halt（每条 story 只有一次外部修复 + 一轮 follow-up） |
| 同一 subagent 连续 2 次发问 | halt |

**绝对禁止**的逃逸路径：
- 跳过任何阶段（B2 / B3 的条件跳过按本手册规则执行，不算跳过）
- 把失败的子 agent 重新拉一次（代答政策重发、⑥ 瞬态重试、B1 续跑已存在的 spec 不算）
- 自动决定"小问题忽略"继续推进
- 把 story 从 done 改回早期状态再跑一遍
- 用户授权了"代答最优方案"，**不等于**授权跳过失败
- **任何**自动 git 撤回 / reset / revert / tag 删除 / branch 切换

### Halt 时主 agent 必须做的事（不可省略）

```
🛑 已 halt。当前 story: $KEY，halt 触发条件：<原因>。

可选操作（你来决定，主 agent 不会自动做任何一种）：
  0. （配额耗尽 halt 优先看这项）跑 harness-state 看真实进度：
       python3 .claude/harness/scripts/harness-state.py $KEY --plain
     next_action_code = build-verify → bmad-build-auto 其实已经跑完，直接从 B1 验收继续
     next_action_code = build（spec 已存在）→ 重启 B1 会按 spec status 续跑，不从零开始
  1. 整条撤回本 story（含 bmad-build-auto 与 harness 的全部 commit）：
       git reset --hard harness/$KEY/start
  2. 撤销当前未提交的 worktree 变更，保留已有 commit：
       git restore --source=HEAD --staged --worktree -- .
  3. 不撤回，进现场调查：
       git log --oneline harness/$KEY/start..HEAD
       git diff
       （bmad-build-auto blocked 时看 spec 的 `## Auto Run Result` 和 `## Review Triage Log`）
  4. 修完之后继续：
       /harness-zh:run --continue     （续作本 story）
       /harness-zh:run                （跳到下一条 backlog；本 $KEY 应已 done 或被人为推进）
  5. （仅配额耗尽）等到 reset 时间，告诉我"重启 <B1|B2|B3|⑥>"，我会重新调度该步
  6. 怀疑是 plugin 缺陷？跑 /harness-zh:report-issue（自动收集上下文，gh CLI 直提，附临时绕过方案）

子 agent 完整返回 / 脚本完整 stdout 如下：
<逐字粘贴>
```

任何场景都打印这段，不要简化，不要替用户选。

---

## 4. 用户中断点

用户随时可以打断你。每条 story **完成后**（B4 之后、回到循环顶部之前）给用户一行进度回报，这是天然的中断窗口。

---

## 5. 参数

| 参数 | LOOP_SCOPE | 语义 | 何时停 |
|---|---|---|---|
| 无参数 | `all` | 跑完所有 backlog story（每个 epic 完成时自动 retro） | 无 backlog，或某 epic retro verdict = rejected |
| `--story` | `single-story` | 跑下一条 backlog story 然后停 | 该 story 走完（含触发的 ⑥） |
| `--story <key>` | `single-story` | 指定 key。已有 `harness/<key>/start` tag → §0.B 续作；没有但已存在手工 bmad-build 的 spec → B1 以续跑模式接手 | 同上 |
| `--epic` | `single-epic` | 跑当前 epic 剩余 backlog（含 retro）。"当前 epic" = 下一条 backlog 所属的 epic | 该 epic backlog 清空 + retro done |
| `--epic <num>` | `single-epic` | 跑指定 epic。已全终态但 retro 未做 → §0.C；retro 也 done → 直接退出 | 同上 |
| `--continue` | `continue-single` | 续作 harness 上次中断的 story（`harness-state.py --in-flight` 最后一条）。worktree 可以不干净 | 续作的那一条跑完就停 |
| `--continue 继续完成当前这个story` | `continue-single` | 自然语言版 | 同上 |
| `--dry-run` | `dry-run` | 不调子 agent、不 commit，只打印运行条件探测结果和每条 story 的步骤计划 | — |

**`--one` 已废弃**，等价语义用 `--story`（无 key）。没有参数时按 §0.A + §2（LOOP_SCOPE=`all`）跑到底。

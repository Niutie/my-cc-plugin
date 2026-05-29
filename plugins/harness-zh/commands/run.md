---
description: 自动按 sprint-status 跑完所有 backlog story（主 agent 编排：create → dev → codex adversarial review → dev fix → bmad code review）
argument-hint: '[--story [<key>] | --epic [<num>] | --continue | --dry-run]'
allowed-tools: Bash, Read, Edit, Write, Task, AskUserQuestion
---

# Sprint 自动开发循环

你是这个循环的**主 orchestrator**。当用户触发 `/harness-zh:run`，你必须按以下手册顺序执行，直到 `sprint-status.yaml` 中再无 `backlog` story 为止。**禁止并行**多条 story；同一时刻最多一条 story 在流水线里。

---

## −1. 主 agent 行为契约（贯穿全流程）

**(a) 监控信号**：你用 `Agent` / `SendMessage` 调度子 agent 时是同步等待的——子 agent 返回的那条消息就是"完成信号"。每次调用必须做这套：

**调用后**做两件事：
1. **看产物**：用 Read / Bash 验证预期文件存在且非空（每阶段都列了"验收"项）。失败 → halt。
2. **看状态**：用 `python3 .claude/harness/scripts/sprint-status.py status <key>` 检查 sprint-status 是否按预期推进；如果 skill 漏同步，主 agent 调 `set` 兜底（见 §1 各阶段）。

**关于结构化校验 vs 文本扫描**：早期版本还要在子 agent 返回文本里搜"广义错误词"（`error` / `failed` / `cannot` / `无法`）触发 halt。实测 false positive 极高（"我加了 error handling"/"测试没 fail"等正常完成描述都会命中），且**真正的失败一定能被结构化校验抓到**：产物缺失 → 验收 halt；schema 不合规 → `harness-commit.py` 退出码 1；漏 stage 推进 → sprint-status 兜底 set 暴露不一致；patch 没改对 → bmad/codex review 这一轮就会发现。所以从 §K（2026-05-01）起，**主 agent 不再做广义错误词文本扫描**——信任结构化校验链。

**例外：配额耗尽**。runtime quota 信号在结构化层不可见（agent 退出时只是返回一段 "hit your limit ... reset at HH:MM" 的英文）。这一类**仍然要扫文本** → 命中即 halt + 用 §3 配额专属模板（选项 5：等到 reset 时间再让用户决定是否重启 stage）。匹配关键词：`hit your limit` / `rate limit` / `usage limit` / `quota` / `reset` 时间提示。

两件事都过 → 进入下一阶段。

> **关于 git index 污染**：早期版本每阶段做 `INDEX_HASH_BEFORE/AFTER` 对比。本轮回顾发现 5 次比对全部 OK、命中率 0——子 agent 用 Edit / Write 工具不会动 index。新协议把这道关收成"每条 story 一次"：阶段 ① `git tag start` 时记一次 hash，阶段 ⑤ commit 之前再比一次（详见对应阶段说明）。中间阶段相信 `git status --porcelain` + §−1.d step 5 的 `git diff --cached --stat` 兜底就够了。

**(b) 代答政策（重要）**：用户授权你在循环中替他回答所有 BMad / Codex 子 agent 的问询。代答政策的全文在 `.claude/harness/answer-policy.md`（项目语境 + 决策原则）。

1. **每一个** subagent prompt 末尾都必须附带"代答政策附带段"。**不要**手贴文本——一处漏粘就让子 agent 走偏。改用：
   ```bash
   python3 .claude/harness/scripts/harness-prompt-suffix.py <stage>
   ```
   把 stdout 拼到 prompt 末尾即可。脚本对 stage 2/4/5 还会自动加上 §1.x「断点续作约定」段。stage 取值：1 / 2 / 3 / 4 / 5 / 6。
   下面的 reference 文本保留只是为了让你（主 agent）知道脚本输出长什么样，**不要再自己粘贴**：
   > **代答政策**：本次任务以非交互模式运行。请先 Read `.claude/harness/answer-policy.md`，按其中的项目语境和决策原则自决，不要发问。每个非显然的选择都要把理由写进你最终交付的产物里。

2. 如果子 agent 仍然提问回来（罕见），用 `SendMessage` 把"按 `.claude/harness/answer-policy.md` 自决"重发一次，**不要**把问题转给用户。

3. 真正必须 halt 的只有 §3 死循环防护表里列的"硬错误"。"我需要你确认 X / Y" 不属于硬错误。

**(c) 进度可视化**：用 TaskCreate 在启动时为每条 backlog story 建一个任务，每条 story 进入流水线时 `in_progress`，完成时 `completed`。用户随时可以用任务清单看到当前进度。

**(d) Commit 协议（每次 commit 调用 `harness-commit.py` 收口，不允许 `git add -A`）**：

`git add -A` 会把任何路径下的变更都卷进本 story 的提交历史——子 agent 跑偏写到无关位置（secrets / 配置文件 / harness 自身 / 其它 story 的产物）都会被静默吞掉。

为了把"5 步协议"压成一条命令，主 agent 每次 commit 都**只调用** `python3 .claude/harness/scripts/harness-commit.py <stage> <key> [--epic <num>]`。脚本封装了：

1. 列变更（`git status --porcelain`）
2. 全局黑名单扫描（凭据 / `.claude/commands/**` / `.claude/skills/**` / `.claude/harness/scripts/**` / `.claude/harness/answer-policy.md` / `.claude/settings*` / `_bmad/**` / 临时垃圾）
3. 跨 story 隔离扫描（implementation-artifacts/* 必须以当前 `$KEY` 开头，或为 `sprint-status.yaml` / `deferred-work.md`，或 stage ⑥ 的 `epic-${EPIC}-retro-*.md`）
4. 按 stage 把通过校验的路径自动 `git add --` 进 index（拒绝兜底之外的路径；不动 commit）
5. sanity check（`git diff --cached --stat` + `git status --porcelain` 不能有未 staged 残余）

**主 agent 怎么用**：

```bash
python3 .claude/harness/scripts/harness-commit.py <stage> <key> [--epic <num>]
```

stage 取值：`1` / `2` / `3` / `4` / `5` / `5-fallback` / `6` / `6-5` / `6-done`。

按退出码处理：
- **0（STATUS=ok）**：脚本已经 stage 好所有路径，输出含 `SUGGEST_COMMIT_MSG=<message>` 和（stage 1/5）`SUGGEST_TAG=<tag-name>`。主 agent 用 HEREDOC + `Co-Authored-By:` 行调 `git commit -m`，message 用脚本建议的字符串。**主 agent 不再自己 `git add`。** commit 完成后**立即**跑 `git tag <SUGGEST_TAG>`（如有）。
- **1（STATUS=halt）**：脚本拒绝 commit。主 agent 按 §3 halt 模板把脚本完整 stdout 贴给用户——脚本输出里的 `BLACKLIST=` / `CROSS_STORY=` / `UNEXPECTED_ARTIFACT=` / `FORBIDDEN=` / `UNSTAGED=` / `DEV_RESULT_*=` / `REVIEW_FINDINGS_*=` 行已经按"违反规则"格式列好。
- **2（STATUS=skip）**：当前 stage 没有变更（典型：`5-fallback` 在 bmad-code-review 已原生同步 sprint-status 时，或 `6-done` 在 retrospective 已写状态时）。跳过本步 commit，直接进下一步。

**机器可读完成门已吸进脚本**：stage 2 commit 时脚本自动校验 `<KEY>.dev-result.json`（schema、`final_story_status` 一致性）；stage 5 commit 时脚本自动校验 `<KEY>.review-findings.json`（unresolved.critical+high+medium=0、`final_story_status` 一致性）。**主 agent 不再需要后置 python 一行命令兜底**——失败由脚本 STATUS=halt 直接报出。详见 §1 各阶段。

**项目代码处理**：stage 2/4/5 允许项目代码路径，脚本一律放行 stage（不再做"白名单 / 标记"区分）。真正的安全门是 BLACKLIST_PATTERNS（凭据 / `.claude/**` / `_bmad/**`）+ cross-story 隔离 + schema gate——这些 halt 才需要主 agent 用 §3 模板介入。详见 harness-changelog 2026-05-01 §J。

**Build artifact 自动剔除**：stage 2/4/5 commit 前，脚本自动检测仓库根的 untracked / 新增 binary blob（条件 all-AND：root 路径 + `[a-z][a-z0-9-]+` 命名 + executable bit + ≥1MB + git 视为 binary），匹配则自动 unstage + rm + 加 `.gitignore`，输出 `AUTO_FIXED=binary-blob ...` 行。这针对 dev sub-agent 跑 `go build` 留下的 cmd binary 残留——主 agent 不需要 halt 让用户决策（详 harness-changelog 2026-05-01 §I）。

**绝对禁止**：
- 主 agent 自己写 `git add` / `git add -A` / `git add .`。一律走脚本。
- 主 agent 自己尝试"修复"脚本拒绝的路径（比如 `git checkout -- file` 来甩开违规改动）。脚本 halt = 用户介入，跟 §3 防护表一致。

---

## 0. 启动前置

第一步是把用户参数解析成 `LOOP_SCOPE` + 目标 story / epic（§0.0），再按对应分支跑前置检查。

### 0.0 目标范围解析（先做这一步，不可省略）

按 §5 参数表把参数映射到 `LOOP_SCOPE`。把以下值绑定到主 agent 的对话上下文中（每条 story commit 后回报 + §2 主循环退出条件 + §3 halt 模板都会读这些值）：

- `LOOP_SCOPE`：`all` / `single-story` / `single-epic` / `continue-single` / `dry-run` 之一
- `TARGET_KEY`（仅 `single-story` / `continue-single` 模式）：要跑/续作的 story key
- `TARGET_EPIC`（仅 `single-epic` 模式）：要跑完的 epic 编号

| 参数 | LOOP_SCOPE | 目标解析 | 走哪条前置分支 |
|---|---|---|---|
| 无参数 | `all` | — | §0.A |
| `--story` | `single-story` | `TARGET_KEY = $(python3 .claude/harness/scripts/sprint-status.py next)`；退出码 1（无 backlog）→ halt | §0.A |
| `--story <key>` | `single-story` | `TARGET_KEY = <key>`；如果 `git rev-parse --verify --quiet harness/<key>/start` 退出码 0 → 切 §0.B 续作；否则 §0.A | §0.A 或 §0.B |
| `--epic` | `single-epic` | 先跑 `python3 .claude/harness/scripts/sprint-status.py next` 拿下一条 backlog：退出码 0 → `TARGET_EPIC = $(python3 .claude/harness/scripts/sprint-status.py epic-of <next>)`，走 §0.A；退出码 1（无 backlog）→ 扫所有 epic（按 yaml 出现顺序），找最早一个 `epic-N-retrospective` 状态非 `done` 的 epic，`TARGET_EPIC = N`，走 §0.C retro-only；都没找到 → 直接退出回报"sprint 已全部完成" | §0.A 或 §0.C 或直接退出 |
| `--epic <num>` | `single-epic` | `TARGET_EPIC = <num>`。用 `epic-all-done <num>` + `epic-retro-status <num>` 判断：该 epic 仍有非 done story → §0.A；epic 全 done 且 retro 状态 != `done` → §0.C retro-only；epic 全 done 且 retro = `done` → 直接退出回报"该 epic 已完成" | §0.A 或 §0.C 或直接退出 |
| `--continue` 或 `--continue 继续完成当前这个story` | `continue-single` | `TARGET_KEY = $(python3 .claude/harness/scripts/sprint-status.py find-by-status review)`；退出码 1（无 review 状态 story）→ halt（让用户检查是否真有中断的 story） | §0.B |
| `--dry-run` | `dry-run` | — | §2 主循环顶层有 dry-run 分支，不需要 §0 前置；只读 `next` / TaskCreate 不调度任何子 agent |

把 `LOOP_SCOPE` / `TARGET_KEY` / `TARGET_EPIC`（适用的字段）记到主 agent 的工作记忆。后续每个阶段失败 halt 时这几个值也要带在 §3 halt 模板的现场信息里。

### 0.A 全新启动（LOOP_SCOPE 为 `all` / `single-story` / `single-epic` 且对应目标仍有 backlog）

依次跑这几个 Bash 检查：

1. `python3 .claude/harness/scripts/sprint-status.py count` — 应该输出 `<剩余>/<总数>`；若文件缺失则 halt 并提示用户先 `/bmad-sprint-planning`。这是真正的硬错误，无法自决。
2. `git status --porcelain` — 工作区**不必**为空。如果不为空，主 agent 自决处理（不 halt）：
   - 跑 `python3 .claude/harness/scripts/sprint-status.py find-by-status review`。
   - 退出码 0（找到一条 review 状态的 story `<KEY>`）→ 自动切到 §0.B 续作流程，用 `<KEY>` 作为续作目标。给用户一行说明："worktree 不干净 + 检测到 `<KEY>` 处于 review 状态 → 自动切续作模式"。
   - 退出码 1（无 review 状态 story）→ halt：worktree 有未知工作、不属于任何在跑的 story，需要用户介入清理或解释。
3. 用 TaskCreate 按 `LOOP_SCOPE` 限定范围建任务，标题形如 `Sprint: <story_key>`，初始 status `pending`：
   - `all` → 给每条 backlog story 建一个任务
   - `single-story` → 仅为 `TARGET_KEY` 那条建任务
   - `single-epic` → 给该 epic（`TARGET_EPIC`）下所有 backlog story 各建一个任务

   这是死循环监控 + 用户进度可视化的主依据。

把"整体计划"用一条简短消息告诉用户：本轮 LOOP_SCOPE=`<value>`，预计跑 N 条 story，第一条 `<key>`（如适用）。

### 0.A.0 retro DEV items 兑现前置 gate（issue #3，v0.1.33+）

**动机**：新 epic 4-6 story 的 stage ① 会创建 `<KEY>.md`（命中 pre-commit gate ① 触发模式 `[4-6]-*.md`）。若此时还有未兑现的 `category: dev` retro action item（上个 epic retro 落地的 D 类项），commit 会被 hook 拦——但**那时 stage ① subagent 的 token 已经烧掉了**。本前置在 spawn stage ① 之前先把这些 dev 项清掉，避免 token 浪费 + halt。

**只在"会创建新 [4-6] spec"时跑**：本步在 §0.A（全新启动）末尾、进入 §1 主流程**之前**执行。先判断本轮第一条要起跑的 story key 是否命中 gate ① 触发模式：

1. 取本轮第一条 backlog story key（`all` / `single-epic`：`python3 .claude/harness/scripts/sprint-status.py next`；`single-story`：`TARGET_KEY`）。
2. 如果该 key **不**匹配 `^[4-6]-` → gate ① 不会触发，**跳过本节**直接进 §1。
3. 如果匹配 → 跑下面的检测 + 兑现循环。

**检测**：

```bash
bash .claude/harness/scripts/grep_pending_dev_retro_items.sh
```

stdout 每个待兑现 dev 项一行（TAB 分隔 5 列）`ITEM<TAB><epic-N-retro><TAB><CODE><TAB><status><TAB><chore_spec|->`，末尾三行汇总 `_PENDING_DEV_:<N>` / `_WITH_SPEC_:<M>` / `_NO_SPEC_:<K>`（这是 gate ① 的同口径计数——与 `check_retro_action_items.sh` 一致）。

- `_PENDING_DEV_:0` → 无阻塞项，跳过兑现，进 §1。
- `_PENDING_DEV_:N`（N>0）→ 进入兑现循环。先用一条简短消息告诉用户：检测到 N 条未兑现 dev retro 项（M 条有 chore_spec 可自动兑现 / K 条缺 spec），将在 stage ① 之前先清掉。

**兑现循环**（对每个 `_WITH_SPEC_` 的 ITEM 行，逐项串行；`chore_spec` = `-` 的项见末尾"缺 spec 兜底"）：

设当前项 `CODE` / `EPIC`（从 `epic-${EPIC}-retro` 取数字）/ `SPEC`（chore_spec 文件名，完整路径 `_bmad-output/implementation-artifacts/$SPEC`）。

1. **实现**：spawn 一个 fresh general-purpose subagent，prompt = `$SPEC` 全文 + 一句指令"按本 chore spec 的 Tasks & Acceptance 段实现项目代码；这是一次性 chore 兑现，**不走** atdd / codex / bmad review 循环；完成后在 spec 的 Tasks checkbox 打勾。只动 spec 描述范围内的项目代码，不碰其它 story 的 artifacts。" 末尾附 `python3 .claude/harness/scripts/harness-prompt-suffix.py 2`（代答政策段；用 stage 2 的 dev 口径）。
2. **翻状态**：subagent 完成后，主 agent 用 Edit 工具把 `sprint-status.yaml` 里 `retro_action_items.epic-${EPIC}-retro.${CODE}` 的 status 从 `pending` / `in-progress` 翻成 `done`（只动这一行；retro_action_items 没有 `sprint-status.py` setter，必须 Edit）。
3. **收口 commit**（脚本是单一可信源，主 agent 不自己 `git add`）：

   ```bash
   python3 .claude/harness/scripts/harness-commit.py retro-fulfill <CODE> --epic <EPIC>
   ```

   `STATUS=ok` → 按 §−1.d 用脚本 `SUGGEST_COMMIT_MSG`（`chore(retro-c<EPIC>-<CODE>): fulfill retro dev item`）HEREDOC commit；本 stage 无 `SUGGEST_TAG`。`STATUS=halt`（典型：cross-story 隔离 / blacklist）→ 按 §3 halt 模板停，交 solo-dev。

4. 下一项。全部 `_WITH_SPEC_` 项兑现完后，重跑 `grep_pending_dev_retro_items.sh` 确认 `_PENDING_DEV_` 已降到只剩 `_NO_SPEC_` 项（或 0）；再进 §1。

**缺 spec 兜底（`chore_spec` = `-`）**：这类 dev 项还没 stage 6.5 落地的 chore spec（多半是 retro residue 没处理完）。主 agent **不**自动臆造实现——把这 K 条列给用户，给两条路：① 先跑 `bash .claude/harness/scripts/process_retro_residue.sh --epic <EPIC>` 补 chore spec 再重跑本命令；② solo-dev 评估后手工兑现 / `git commit --no-verify` 显式跳过（须在该项 yaml 行加注释留痕）。在缺 spec 项未清掉前，stage ① commit 仍会被 gate ① 拦——据实告诉用户，不要假装已清零。

> **范围说明**：本前置只覆盖**启动那一刻**的 gate ① 阻塞。`all` 模式跑到 epic 边界时，上个 epic 的 stage ⑥ retro 会**新 seed** 一批 dev 项，下个 epic 的 stage ① 仍可能被拦——那属于 mid-run epic 切换，沿用既有 stage 6.5 → 手工兑现路径，不在本前置范围内。

### 0.B 续作（LOOP_SCOPE = `continue-single`，或 `single-story` 且 `harness/<TARGET_KEY>/start` tag 已存在）

worktree **可以**不干净（这是续作的合法状态）。改跑这套：

1. 确定 `<KEY>`：`--story <key>` 显式给定，或 `--continue` 时从 `python3 .claude/harness/scripts/sprint-status.py find-by-status review`（取最近一条 `review` 状态的 story；按 yaml 出现顺序的最后一条）。
2. 调 `python3 .claude/harness/scripts/harness-state.py <KEY>` 拿到状态 JSON。**必须用脚本**，不要自己 grep git log + 推断阶段——这是单一可信源。
3. 读 `next_action_code` 决定切入点：
   - `stage1` / `stage2` / `stage3` / `stage4` / `stage5` — 跳到 §1 对应阶段调度
   - `tag-only` — 跑 `git tag harness/<KEY>/done`，进 §1 阶段 ⑥ 触发判断
   - `done` — 不该走 `--continue`；按 §0.A 跑下一条 backlog
   - `blocked-dirty` — worktree 有中段产出，先按 `next_action` 文本提示完成"验收 + commit"再切入下一阶段
   - `not-started` — 该 story 还没起跑，按 §0.A 流程进 §1 阶段 ①
4. 用 TaskCreate 建一个任务跟踪本 story，metadata 里存 `stage2_base_sha`（从脚本 JSON 取）。
5. **续作 prompt 自动生成**（重要：harness-changelog 2026-05-03 §D）：spawn fresh subagent 时**不要**自己手工拼"前情提要 / 已落地清单"段。改用：

   ```bash
   python3 .claude/harness/scripts/harness-state.py <KEY> --resume-prompt --stage <N>
   ```

   stage 取值 = `next_action_code` 数字部分（`stage2` → 2，`stage4` → 4，`stage5` → 5）。脚本输出含：worktree 改动按目录分组计数 / story md Status 段当前值 / Tasks checkbox 进度 / dev-result.json 是否存在（stage 2）/ codex finding 数 vs Codex Review Handling 行数缺口（stage 4）/ review-progress.json findings 状态分布（stage 5）/ 续作动作清单。

   把脚本 stdout 拼到 fresh subagent 的 prompt 头部（连同原 stage prompt 模板 + `harness-prompt-suffix.py <stage>` 的代答政策附带段）。fresh agent 拿到的就是 deterministic"中断位置 + 已落地 + 待做"三段。**禁止主 agent 凭推理自己写"前情提要"**——这件事本轮已被脚本接管。

   stage 1 / 3 / 6 通常没产生大量 worktree 中间状态，配额耗尽后直接重跑成本可接受；这些 stage `--resume-prompt` 不输出 micro-progress（脚本会 fall through 给 generic 提示）。

把"切入计划"用一条简短消息告诉用户：从 stage <N> 续作 `<KEY>`，已读 stage2_base_sha=`<sha>`。

### 0.C Retro-only 启动（LOOP_SCOPE = `single-epic` 且该 epic 全 done 但 retro 未 done）

跳过 §1 主流程（阶段 ①-⑤），直接进入阶段 ⑥。准备工作：

1. 设 `EPIC = $TARGET_EPIC`（§0.0 解析得到的 epic 编号）。
2. 用 TaskCreate 建一个任务，标题 `Sprint: epic-${EPIC}-retrospective`，初始 status `in_progress`。
3. 跳过 §1 阶段 ①-⑤，直接执行 §1 阶段 ⑥ 的所有动作（条件触发判断改为"无条件触发"——本路径已在 §0.0 预先验证过 epic 全 done + retro 未 done）。

阶段 ⑥ 完成后回到 §2 主循环：LOOP_SCOPE=`single-epic` + retro 已 done → 退出。

把"切入计划"用一条简短消息告诉用户：仅触发 epic-${EPIC}-retrospective（该 epic story 全 done 但 retro 未做）。

---

## 0.5 路径预期产出表（每次 commit 时按 §−1.d step 4 / 5 引用）

本表是 `harness-commit.py` 内置的硬编码规则的 reader-friendly 版本——主 agent 不再需要肉眼对照本表去 `git add`，脚本会按这些规则自动 stage 通过校验的路径。**主 agent 看本表是为了搞懂"为什么"，不是为了"按表执行"**。

**Skill 同步状态字段的可靠性历史教训**：早期版本默认 dev-story 和 bmad-code-review skill 会原生同步 `sprint-status.yaml` 里本 story 的状态字段，但实测中 dev-story 经常漏同步。**现协议**（chore-harness-epic-4-orchestration-observations T1，2026-05-04）把 sync 责任完全压在 `harness-commit.py` — commit 前自动按 stage 推进 yaml 状态（stage 2 → review / stage 5 → done / stage 6 → epic-${N}-retrospective + epic-${N} done / stage 6-5 → 不动状态）。主 agent **不再调用** `sprint-status.py set` 兜底；如果 sprint-status 已是预期值则脚本内 sync 路径是 no-op，如果漏了则由 harness-commit 自动补上。

| 阶段 commit | 预期产出路径（脚本内置规则） |
|---|---|
| 阶段 ① `story($KEY): create story spec` | `$KEY.md` + `sprint-status.yaml` |
| 阶段 ② `story($KEY): initial implementation` | 项目代码（除去 §−1.d 黑名单）+ `$KEY.md`（dev 改 status 段）+ `$KEY.dev-result.json`（机器可读完成门）+ `deferred-work.md`（dev 阶段实现中遇到的沙箱延后项 / FU-* 条目）+ `sprint-status.yaml`（主 agent 兜底 set review） |
| 阶段 ③ `story($KEY): codex adversarial review report` | **仅** `$KEY.codex-review.md` |
| 阶段 ④ `story($KEY): apply codex review fixes` | 项目代码 + `$KEY.md`（Codex Review Handling 段，stage ④ 续作的 progress 记录） |
| 阶段 ⑤ `story($KEY): final review fixes & done` | 项目代码 + `$KEY.md`（含 Status / Review Findings 段）+ `$KEY.review-findings.json`（机器可读完成门）+ `$KEY.review-progress.json`（断点续作 progress 文件，可选）+ `deferred-work.md` + `sprint-status.yaml`（主 agent 兜底 set done） |
| 阶段 ⑤ `sprint($KEY): mark done` | **仅** `sprint-status.yaml`。一般情况兜底 set 已经在 stage 5 commit 中带走，本步 STATUS=skip 跳过即可。 |
| 阶段 ⑤.5 `test($KEY): atdd + e2e (run-sprint stage 5.5)` | `test_artifacts/$KEY-test-result.json` OR `test_artifacts/skipped-$KEY-*.md`（sandbox graceful skip 路径）+ `console-web/tests/e2e/$KEY*.spec.ts`（如 atdd 改动）+ `sprint-status.yaml`（test_status 段更新）+ `deferred-work.md`（FU-Test-* 项追加）。环境受限 / 测试 fail 都不阻 stage ⑥；test_artifacts/ 全无产出时 STATUS=skip。 |
| 阶段 ⑥ `epic($EPIC): retrospective` | `epic-${EPIC}-retro-*.md` + `sprint-status.yaml` + `deferred-work.md`（retro 期间发现的 epic 级别延后项可写入此处） |
| 阶段 ⑥.5 `chore(retro-c$EPIC): process residue → N chore specs` | `chore-retro-c${EPIC}-<code>-<slug>.md` × N（NEW，由 fresh agent 生成）+ `sprint-status.yaml`（仅 retro_action_items.epic-${EPIC}-retro 子段加 `chore_spec` + `category` 两字段，category 值取自 fresh agent MANIFEST）。无残余时 STATUS=skip。 |
| 阶段 ⑥ `epic($EPIC): mark done` | **仅** `sprint-status.yaml`（同时翻 `epic-${EPIC}-retrospective: done` 和 `epic-${EPIC}: done`）。如果两个 key 都已是 done 则 STATUS=skip。 |
| 前置 `retro-fulfill <CODE> --epic <EPIC>`（§0.A.0，issue #3）`chore(retro-c$EPIC-<CODE>): fulfill retro dev item` | 项目代码 + `sprint-status.yaml`（主 agent Edit 翻 `retro_action_items.epic-${EPIC}-retro.<CODE>` status → done）+ `deferred-work.md`（实现中遇到的延后项）+ `chore-retro-c${EPIC}-<CODE>-*.md`（dev 勾 Tasks checkbox；chore_retro 通道豁免）。位参是 retro item 的 `<CODE>`（非 story key）。 |

**测试 harness 独立 stage**（由 `/harness-zh:run-test` 触发，与 run-sprint 5-stage 命名空间隔离；详见 [`run-test.md`](run-test.md)）：

| 阶段 commit | 预期产出路径（脚本内置规则） |
|---|---|
| `T1` `test(epic-$EPIC): test-design` | `test_artifacts/epic-${EPIC}-test-design.md` + `sprint-status.yaml`（必传 `--epic`；epic-test-design 已存在则 STATUS=skip） |
| `T3` `test($KEY): atdd red-phase scaffold` | `test_artifacts/$KEY.atdd-checklist.md` + `console-web/tests/e2e/$KEY*.spec.ts` + `sprint-status.yaml` |
| `T4` `test($KEY): atdd + e2e` | `test_artifacts/$KEY-test-result.json` OR `test_artifacts/skipped-$KEY-*.md` + `sprint-status.yaml` + `deferred-work.md`（verdict=red/sandbox 时） |

（路径前缀 `_bmad-output/implementation-artifacts/` 上面的路径都省略，下面同。）

**"项目代码"是什么**：脚本里凡是不匹配 `_bmad-output/implementation-artifacts/*.md` / `*.json` / `*.yaml` 的路径都被当作"项目代码"——典型如 `src/`、`apps/`、`packages/`、`tests/`、`pyproject.toml` / `package.json` / `Cargo.toml` / `go.mod` 等构建文件、`docs/`、`deploy/`、`.github/workflows/`、`config/` 等。stage ②/④/⑤/⑤.5/`retro-fulfill`/T1/T3/T4 允许这类路径，stage ①/③/`5-fallback`/⑥/`6-done` 拒绝。`test_artifacts/` 子目录路径（`_bmad-output/implementation-artifacts/test_artifacts/...`）也走"项目代码"通道——ARTIFACT_RE 限定无斜杠后缀，子目录天然不匹配 → 落到 project_code 桶（仅 stage ⑤.5/T1/T3/T4 允许）。

**预期外路径如何处理**：脚本不区分"已知模块 / 未知模块"——只要不在黑名单 / 跨 story / 预期外 artifact 这三个 halt 类里，项目代码一律 stage。harness-changelog 2026-05-01 §J 解释了为什么删掉之前的"白名单 + PROJECT_CODE 标记"双轨制（标记本身没改变过任何决策，只是 commit message 噪音）。

**halt 类条件**：
- 命中 BLACKLIST_PATTERNS（凭据 `.env*` / `*.pem` / `_bmad/**` / `.claude/**` 子集 / 临时垃圾）→ halt
- 跨 story 隔离破坏（`_bmad-output/implementation-artifacts/<other-key>.*` 出现在本 story 的 commit 里）→ halt
- `_bmad-output/implementation-artifacts/` 下出现 §0.5 表外的 artifact → halt
- stage ①/③/`5-fallback`/⑥/`6-done` 出现项目代码（这些 stage 本来就不应该改源码）→ halt
- schema gate fail（dev-result.json / review-findings.json）→ halt

**子 agent 偷 stage / 改坏文件怎么发现**：脚本的 sanity check（`git status --porcelain` 后 `xy[1] != " "` = unstaged 残余）触发 halt（输出 `UNSTAGED=`）。失控撤回是用户的特权（见 §3 末尾 halt 模板），主 agent 不要自己 stash / checkout / reset 来"清理"。

**Spec-driven cross-story 改动（harness-changelog 2026-05-03 §B）**：偶发 case：本 story 的 spec 显式约束要修改非本 story 的 implementation-artifacts（典型场景：跨 story bug fix、deferred-cleanup spec frontmatter 翻状态、其它 story md 的 typo 修正）。在 story md 头部 frontmatter 加 `cross_story_artifacts:` YAML list 声明：

```yaml
---
status: ready-for-dev
cross_story_artifacts:
  - 1-7-proxy-fork-addon-framework-unix-socket.md
  - spec-deferred-cleanup-2026-05-02-console-web-container-build.md
---
```

`harness-commit.py` 读到该字段会把列出的 basename（仅 `_bmad-output/implementation-artifacts/` 下，必须 .md 后缀，不能是 `<KEY>.*` 自身）从 cross-story 隔离里豁免。这避免了"双独立 chore commit"workaround。**约束**：仅声明真正必要的跨 story 路径——不是给"我顺手想改的文件"开后门。

**额外 .md artifacts 自动剔除（§A）**：subagent 偏离 schema 多产 `<KEY>.bmad-code-review.md` / `<KEY>.review-summary.md` / `<KEY>.dev-notes.md` / `<KEY>.review-report.md` 等额外 .md 时，harness-commit.py 自动 unstage + rm（仅对 untracked 路径触发；modified 文件永不自动删）。输出 `AUTO_FIXED=unexpected-md ...` 行作为信息。所有 review/dev 内容必须落进 `<KEY>.md` 的对应 section（`### Review Findings` / `### Codex Review Handling` / `## Dev Notes`）。

---

## 1. 单条 story 流水线（5 阶段 + 条件 ⑥，严格顺序）

对**每一条** backlog story，按以下顺序执行。每个阶段独立 Agent 调度；阶段间由你（主 agent）调 `harness-commit.py` 收口 commit。

设当前 story key = `$KEY`，story 文件路径 = `_bmad-output/implementation-artifacts/$KEY.md`，codex review 文件 = `_bmad-output/implementation-artifacts/$KEY.codex-review.md`。

> **提醒**：以下每一段 `Agent({ prompt: "..." })` 的 prompt 末尾都要附带"prompt 后缀"——**用脚本输出**而不是手贴：
>
> ```bash
> python3 .claude/harness/scripts/harness-prompt-suffix.py <stage>
> ```
>
> 脚本对 stage 1/3/6 输出代答政策段，对 stage 2/4/5 输出断点续作约定 + 代答政策段。把 stdout 拼到 prompt 字符串末尾即可。**禁止**主 agent 自己粘贴这两段——脚本是单一可信源。
>
> 下面 §1.x 保留的 reference 文本只是给你（主 agent）了解脚本输出长什么样，不要再自己粘贴到子 agent prompt 里。

### §1.x 断点续作约定（reference — 由 `harness-prompt-suffix.py` 自动输出，主 agent 不要手贴）

> **断点续作约定**：如果你启动时发现 worktree 已有变更（说明上一次本任务被中断、未由主 agent 清理）或本 story 文件 / progress JSON 里已有部分进度记录，**先读已有产物，跳过已完成项，从中断点续作**。每完成一项原子工作（例如修复一条 finding），立即把进度写入相应 progress 来源——这样下次中断也能续接：
> - **stage ②**: progress = story md 的 Tasks checkbox（dev-story skill 原生维护，逐 task 推进时即时更新）。
> - **stage ④**: progress = story md 的 `### Codex Review Handling` 段（每条 finding 一行 `fixed/wontfix/deferred` 标记，处理一条写一行）。
> - **stage ⑤**: progress = `_bmad-output/implementation-artifacts/$KEY.review-progress.json`（每完成一条 finding 决议 / patch 时增量更新；结构：`{"findings": {"F1": {"status": "patched", "files": [...], "ts": "..."}, ...}, "phase": "patching|done"}`）。
>
> 中断恢复 ≠ 重新发现已经发现的问题——已进度文件里出现的 finding 都视为"已处理"，不要重新 review / 重新决议。
>
> **stage ② 额外块（§L；schema v1 升级 2026-05-04 / 文本契约修正 2026-05-05）**：`harness-prompt-suffix.py 2` 还会输出一段 "Deferred-work 扫描约定" — 让 dev agent 启动时先扫 `deferred-work.md`，按 schema v1 `[target:Story <短格式>]` tag 识别命中条目；`[status:pending]` 项自然 scope 内能顺手 resolve 的就 resolve（翻 `[status:resolved]` + 加 `历史` 子段），scope creep 风险的跳过。**软提示，无结构化校验**——主 agent 不卡 commit。但 pre-commit hook gate ② 会真拒老 inline 后缀模式（`— Resolved by Story X.Y (date)`），所以 dev agent 必须按 schema v1 写。详见 harness-changelog 2026-05-01 §L + 2026-05-04 schema v1 + 2026-05-05 文本契约修正。

### 阶段 ①：Create story（独立匿名 agent）

- 把当前 TaskCreate 任务标记 `in_progress`。
- **打 start tag（撤回点，必须在 dispatch 子 agent 之前）**：`git tag harness/$KEY/start`
  - lightweight tag，零开销。任何阶段 halt 想整条撤回，用户用 `git reset --hard harness/$KEY/start` 就能回到本 story 还没动过的状态。
  - **如果该 tag 已经存在**（说明 sprint-status 漏推进 / 续作场景未通过 `--continue` 进入）→ 主 agent 自决（不 halt）：调 `python3 .claude/harness/scripts/harness-state.py $KEY` 拿状态 JSON，按 `next_action_code` 切到对应阶段（`stage1/2/3/4/5/tag-only/blocked-dirty`）。**只有** `next_action_code == "done"` 才 halt（story 早已完成，主循环不该把它当 backlog 拉出来——可能是 sprint-status.yaml 有脏数据）。给用户一行说明："$KEY start tag 已存在，按 harness-state.next_action_code=`<code>` 自动切续作"。
- **Deferred-work 注入（§O，C11）**：在调度 create-story 前主 agent 先跑：

  ```bash
  DEFERRED_INJECT=$(bash .claude/harness/scripts/grep_pending_deferred_for_story.sh "$KEY" 2>&1)
  GREP_EXIT=$?
  if [ "$GREP_EXIT" -ne 0 ]; then
      # halt 走 §3 模板：grep 脚本失败（脚本 bug / deferred-work.md 缺失 / key 形式异常）
      # 不让"静默无注入"发生
      echo "halt: deferred-work grep 失败 exit=$GREP_EXIT"; exit 1
  fi
  ```

  把 `$DEFERRED_INJECT` 作为 prompt 头部的"注入段"拼到子 agent prompt 中，紧贴在 `harness-prompt-suffix.py 1` 输出**之前**（位置选择详见 §1.x.O 注释）。注入段格式必须含显式分隔符：

  ```markdown
  ## Deferred-work 待消化提示（auto-injected by C11）

  <`grep_pending_deferred_for_story.sh $KEY` 的 stdout，原样粘贴>

  ---
  ```

  让 fresh subagent 明确知道这是**机器注入**而非人工 spec 内容（§O block 在 `harness-prompt-suffix.py 1` 输出里也提示了 subagent 如何处理）。
- 调度 create-story agent：`Agent({ subagent_type: "general-purpose", description: "Create story <KEY>", prompt: "## Deferred-work 待消化提示（auto-injected by C11）\n\n" + $DEFERRED_INJECT + "\n\n---\n\n请直接调用 /bmad-create-story 并把目标 story 设为 <KEY>。完成后退出，不要做任何 git 操作（add / commit / push / branch / tag / amend / mv / rm / restore --staged / stash 一律不要）。修改 / 写文件请直接用 Edit / Write 工具。\n\n" + <`harness-prompt-suffix.py 1` 的 stdout>})`
- 等待返回。
- **验收**：Read `_bmad-output/implementation-artifacts/$KEY.md` 必须存在且非空。否则 halt，把 agent 的返回贴给用户。
- **commit**：`python3 .claude/harness/scripts/harness-commit.py 1 $KEY`，按 §−1.d 退出码处理。
- **commit 完成后**：脚本输出含 `SUGGEST_TAG=harness/<KEY>/stage2-base`，**立即**跑 `git tag harness/$KEY/stage2-base`（指向刚 commit 的 stage 1 commit）。这个 tag 是 stage ③/⑤ 的 codex / bmad review base 单一可信源；跨会话续作 `harness-state.py` 也读它。

### 阶段 ②：Dev 实现（独立 general-purpose agent）

- **review 基线**：用 `harness-state.py` 拿 `stage2_base_sha`，必要时自动补打 tag：

  ```bash
  STAGE2_BASE=$(python3 .claude/harness/scripts/harness-state.py $KEY | python3 -c 'import json,sys; print(json.load(sys.stdin)["stage2_base_sha"] or "")')
  if [ -z "$STAGE2_BASE" ]; then
    echo "halt: harness-state.py 未能取到 stage2_base_sha（stage ① commit 不存在）"; exit 1
  fi
  if ! git rev-parse --verify --quiet "harness/$KEY/stage2-base" >/dev/null; then
    git tag "harness/$KEY/stage2-base" "$STAGE2_BASE"
  fi
  ```

  `harness-state.py` 的 `stage2_base_sha` 字段优先取 tag，tag 缺失时回退到 stage ① commit subject 匹配（见脚本 doc）。tag 缺失时主 agent 自动补打（不 halt）。**不要**手动 `git rev-parse HEAD` ——HEAD 在中间阶段会移动。

  > **边界情况：harness 元修改 commit 落在 stage ② 之后**：如果 stage ② → ⑤ 之间因为流水线 halt → 用户授权 harness 元修改 → 重新继续，期间插入了任何 `.claude/commands/run.md` / `.claude/harness/scripts/**` / `.claude/harness/answer-policy.md` 的元修改 commit——**绝对不要**前推 `harness/$KEY/stage2-base` tag。前推 tag 会让 stage ⑤ bmad review 把 stage ② 的所有代码（往往是 story 的主体实现，几千行）排除出 review window，造成"伪 review 通过"的静默失败（曾在 `1-5-console-web-scaffold-design-tokens-i18n-shadcn` 这条 story 上发生过：bmad 只看到了 290/9941 行，2.9% 覆盖率）。正确做法：**让 tag 留在原位（指向 stage ① commit），review prompt 用 git pathspec `:!.claude` 把 harness 路径的改动排除出 diff**。stage ③ codex 和 stage ⑤ bmad 的 prompt 模板里已经写好了这个 pathspec。
- 调度 dev：

  ```
  Agent({
    subagent_type: "general-purpose",
    description: "Dev story <KEY>",
    prompt: <以下 prompt> + <`harness-prompt-suffix.py 2` 的 stdout，自动包含断点续作约定 + 代答政策附带段>
  })
  ```

  prompt 核心：

  > 请直接调用 /bmad-dev-story 并把目标 story 文件设为 `_bmad-output/implementation-artifacts/<KEY>.md`。按 dev-story 工作流跑完，把 story 状态推进到 `review`。完成后停止，不要做任何 git 操作（add / commit / push / branch / tag / amend / mv / rm / restore --staged / stash 一律不要），稍后我会让你回来再修一轮。修改 / 写文件请直接用 Edit / Write 工具。
  >
  > **机器可读完成门（强制额外产出）**：除了 story 文件本身，还必须用 Write 工具产出 `_bmad-output/implementation-artifacts/<KEY>.dev-result.json`，**推荐 tri-state schema**：
  >
  > ```json
  > {
  >   "story_key": "<KEY>",
  >   "checks": {"tests": "pass", "vet": "pass", "build": "pass", "lint": "skip"},
  >   "checks_skip_reasons": {"lint": "golangci-lint binary not installed in sandbox; CI on linux/amd64 runs strict lint"},
  >   "files_changed_count": 33,
  >   "final_story_status": "review"
  > }
  > ```
  >
  > 字段定义：
  > - `checks.<name>`：取值 `"pass"` / `"fail"` / `"skip"`。`"fail"` 会让主 agent 调用的脚本直接 halt——只有真通过才填 `"pass"`，没跑的检查必须填 `"skip"` 而不是 `"pass"`。
  > - `checks_skip_reasons.<name>`：每个 `"skip"` 对应一条说明字符串。可选，但强烈建议。
  > - `files_changed_count`：本 story dev 阶段实际新增/修改的文件数（按 `git status --porcelain | wc -l` 估算）。
  > - `final_story_status`：你刚把 story md Status 段写成的字面值。预期是 `review`。
  >
  > 旧 boolean schema（`checks.<x>_passed: bool` + `checks_skipped: [...]`）仍兼容，但请优先用 tri-state——格式更清晰，不会因为 reason 字符串混进 key 列表而 halt（这正是 1-3 那次踩的坑，见 `.claude/harness/changelog.md` 2026-05-01 §C）。

- 等待返回。
- **验收**：
  1. story 文件中 Status 段应该已经是 `review`（用 Read 抽查）。否则 halt。
  2. **机器可读完成门已吸进 `harness-commit.py`**——主 agent 不再需要手动跑 python 一行命令。stage 2 commit 时脚本自动校验 dev-result.json schema、检查项三态、`final_story_status` 与 md 一致性；fail 时退出码 1 + 诊断行 `DEV_RESULT_*=`。
- **sprint-status sync**（chore-harness-epic-4-orchestration-observations T1.4，2026-05-04）：harness-commit.py stage 2 内部已自动跑 `_sync_sprint_status_for_stage("2", $KEY, ...)` → set $KEY review；主 agent **不再**手工跑兜底 set。漏 sync 由脚本兜住、commit 通过；脚本 IO 失败 → STATUS=halt + REASON=sprint-status auto-sync failed（按 §3 模板）。
- **commit**：`python3 .claude/harness/scripts/harness-commit.py 2 $KEY`，按 §−1.d 退出码处理。STATUS=halt 且 REASON 含 `machine-readable completion gate failed` → 把 `DEV_RESULT_*=` 行贴给用户（schema 不合格、check 是 fail、status 不一致都属此类）。STATUS=ok 时 stdout 含 `SPRINT_STATUS_AUTO_SYNC=set key=<KEY> value=review` 一行（如果 skill 漏 sync）— 仅信息，不需要主 agent 处理。
- 此时 `git log harness/$KEY/stage2-base..HEAD` 包含的就是阶段 ② 引入的代码改动，是阶段 ③/⑤ 的 review 对象。

### 阶段 ③：Codex 对抗式 Review（独立匿名 agent，review 对象是阶段 ② 的代码 diff）

> **重要**：`/codex:adversarial-review` 是 review-only，**不会自动写文件**——它把 review 报告作为 stdout 返回。所以"把 review 落到 `<KEY>.codex-review.md`"这一步是 subagent 在拿到 codex stdout 之后**手动写**的，不是 codex 原生行为。
>
> **另外**：`/codex:adversarial-review` 的 frontmatter 是 `disable-model-invocation: true`，**Skill tool 调不动它**——子 agent 必须直接跑底层 `node` 命令。下面 prompt 直接给出兜底命令，免得每个新 stage ③ 子 agent 都自己摸索一遍。

#### 阶段 ③.0：Pre-flight — codex 可用性探测（v0.1.27+）

在 spawn codex subagent **之前**先跑探测，避免"plugin 没装也去 spawn 一遍"的浪费：

```bash
CODEX_PROBE_JSON="$(bash .claude/harness/scripts/check_codex_availability.sh)"
CODEX_AVAILABLE="$(printf '%s' "$CODEX_PROBE_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["available"])')"
```

**若 `CODEX_AVAILABLE = False`** → 走 §③.1 跳过流程（**不**进 §③ 主体的 spawn 流程）。
否则按 §③ 主体（下面）spawn codex subagent 正常跑。

#### 阶段 ③.1：Skip 路径（codex 不可用时显式跳过 stage 3+4）

> **设计动机**：codex-in-cc 不可用是**预期可发生**的情况（额度耗尽、未登录、未装、网络
> 抖动等）。原协议是 halt，让用户处理；现协议（v0.1.27+）允许显式跳过 stage 3+4，story
> 走完 stage 5 → done，但留下 marker 供事后用 `/harness-zh:codex-catchup` 补跑。
>
> **绝不静默**：必须有清晰可视的通知（halt 模板风格），让用户当场知道"codex 这一档跳过了"
> 而不是默默吃掉。
>
> **绝不污染主流程状态机**：不动 `dev_status` 字段。stage 5 把 dev_status 翻 done 是正常的；
> codex-skipped 是正交的 audit-trail 关注点，由独立 marker 文件承担。

触发本路径的两条来源：
1. **§③.0 pre-flight 命中**：`CODEX_AVAILABLE = False`
2. **§③ 主体 in-flight 命中**：codex subagent 返回文本含 `hit your limit` / `rate limit` /
   `usage limit` / `quota` / `not logged in` / `unauthorized` / `auth required` / `please log in`
   等关键词（保留 `reset` 时间提示也走本路径——不再用旧 §3 配额专属 halt 模板，改 catchup-friendly skip）

两个来源都执行同一组操作：

##### a) 写 marker 文件 `<KEY>.codex-skipped.json`

```bash
TS_ISO="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
cat > "_bmad-output/implementation-artifacts/${KEY}.codex-skipped.json" <<EOF
{
  "key": "${KEY}",
  "reason": "<reason>",
  "skipped_at": "${TS_ISO}",
  "skipped_at_stage": 3,
  "stage2_base_sha": "<STAGE2_BASE>",
  "remediation": "<remediation 文本>",
  "catchup_command": "/harness-zh:codex-catchup --story ${KEY}"
}
EOF
```

`<reason>` 取值：
- `not_installed`（pre-flight 命中：plugin 没装；reason 字段直接复用 probe JSON）
- `quota_exhausted`（in-flight 命中：subagent 返回含 `hit your limit` / `rate limit` / `quota` / `usage limit` / `reset`）
- `auth_failed`（in-flight 命中：含 `not logged in` / `unauthorized` / `please log in` / `auth required`）
- `unknown`（in-flight 命中但匹配不到具体子类型）

##### b) 显式通知用户（halt 模板风格，但**不退出**——只是显示给用户）

```
┌──────────────────────────────────────────────────────────────────┐
│ ⚠️  codex-in-cc 不可用 — stage 3+4 已跳过 <KEY>                  │
│                                                                  │
│   reason       : <reason>                                        │
│   remediation  : <remediation 字段；pre-flight 来源直接拿 probe  │
│                  JSON.remediation；in-flight 来源给一句"等额度    │
│                  恢复 / gh auth login 后重跑"等具体引导>         │
│                                                                  │
│ Story 继续往下走 stage 5（bmad code review）+ done。             │
│ marker 文件已写：                                                │
│   _bmad-output/implementation-artifacts/<KEY>.codex-skipped.json │
│                                                                  │
│ 待 codex 恢复后跑：                                              │
│   /harness-zh:codex-catchup --story <KEY>                        │
│ 或 `/harness-zh:codex-catchup` 一次性补跑所有 skip 的 story。    │
└──────────────────────────────────────────────────────────────────┘
```

##### c) 跳到 stage 5

不跑 stage 3 commit、不跑 stage 4。直接进 §1 阶段 ⑤（bmad final review）。

注意：`harness-commit.py 3` 与 `4` 都**不跑**——marker 文件是状态记录而非 commit 路径
中间产物。stage 5 commit 时 `harness-commit.py 5` 会照常处理 sprint-status 里 dev_status
状态推进（review → done），不受 skip 影响。

> **Pre-flight pre-flight**：v0.1.27 之前已经有 `<CODEX_COMPANION_PATH>` 解析失败 → halt
> 的兜底（§③ 主体下面 §③.2）。现在 §③.0 探测脚本与该兜底逻辑完全等价但更显式 +
> 提供 catchup 路径——主 agent 默认走 §③.0；§③.2 路径 fallback 到一致的 marker 写入。

#### 阶段 ③.2：主体（codex 可用时正常跑）

- 调度 codex review：

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
  > **不要试 Skill tool 调用 `/codex:adversarial-review`**——它的 frontmatter 是 `disable-model-invocation: true`，Skill 调用会被拒。直接用 Bash 跑底层 node 命令：
  >
  > ```bash
  > node "<CODEX_COMPANION_PATH>" adversarial-review --wait --base <STAGE2_BASE> "review focus: 阶段 ② 引入的代码实现 (story spec 在 _bmad-output/implementation-artifacts/<KEY>.md，作为验收标准上下文，但 review 对象是代码 diff，不是 story md)"
  > ```
  >
  > `<CODEX_COMPANION_PATH>` 是主 agent 预先用 Bash 解析好的绝对路径——子 agent 直接拿来跑，不需要再摸索。`--wait` 让 codex 在前台跑完，stdout 即 review 报告。
  >
  > **第 2 步：把 codex 返回的报告写到固定路径**
  >
  > 用 Write 工具把 codex stdout 完整写入 `_bmad-output/implementation-artifacts/<KEY>.codex-review.md`，前面加一段 frontmatter：
  >
  > ```
  > ---
  > story: <KEY>
  > base: <STAGE2_BASE>
  > head: <实际的 HEAD SHA，用 git rev-parse HEAD 拿>
  > reviewer: codex-adversarial
  > ---
  > ```
  >
  > 然后**逐字粘贴** codex 的完整 stdout（不要总结、不要润色、不要重排）。如果 codex 自己输出已经有结构化分级，保留原样；如果没有，**不要**自己强行改成 Critical/High/Medium 分类——保留 codex 的原样最忠实。
  >
  > 两步都做完后停止。

  - 调用前主 agent 替换两个占位符：
    - `<STAGE2_BASE>` ← 用阶段 ② 介绍的 `harness-state.py + 自动补 tag` 流程拿到（同一 SHA 在阶段 ②/③/⑤ 复用；**不要**用 `git rev-parse HEAD`——HEAD 此时是 stage ② 的 commit）
    - `<CODEX_COMPANION_PATH>` ← 主 agent 用 Bash 解析的绝对路径，按以下优先级：
      ```bash
      CODEX_COMPANION_PATH="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/scripts/codex-companion.mjs}"
      [ -z "$CODEX_COMPANION_PATH" ] || [ ! -f "$CODEX_COMPANION_PATH" ] && \
        CODEX_COMPANION_PATH=$(ls ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)
      ```
      `${CLAUDE_PLUGIN_ROOT}` 在主 agent 自身环境里通常已被注入；但 spawn 的 sub-agent 子进程**不一定**继承——主 agent 在调度前预解析能消除这种不稳定。如果两条路径都为空 → halt（codex companion 不可用，stage ③ 无法继续）。
- 等待返回。
- **In-flight 检测（v0.1.27+）**：subagent 返回的文本若含 codex 不可用的关键词，路由到
  §③.1 skip 路径而非通用 §3 halt 模板。检测词：
    - 配额：`hit your limit` / `rate limit` / `usage limit` / `quota` / `reset` 时间提示
    - 认证：`not logged in` / `unauthorized` / `please log in` / `auth required`
  命中任一 → 跳到 §③.1，写 marker 文件，继续 stage 5。
  **本规则仅适用于 stage 3**——其它 stage（如 stage 5 bmad final review）的配额耗尽
  仍按 §3 通用 halt 模板处理（因为它们没有 codex-skip 的等价 marker / catchup 通道）。
- **验收**：
  - `_bmad-output/implementation-artifacts/$KEY.codex-review.md` 存在且非空（至少 200 字节）。
  - 文件包含 `base: <STAGE2_BASE>` frontmatter 行（说明 subagent 真的传了 `--base`）。
  - 任一不满足→halt。
- **commit**：`python3 .claude/harness/scripts/harness-commit.py 3 $KEY`，按 §−1.d 退出码处理。

### 阶段 ④：Dev 续作修复（独立 fresh general-purpose agent，**有意 freelance，不调 BMad 工作流**）

#### 阶段 ④.0：Skip 路径前置检查（v0.1.27+）

stage 4 入口先检查 `<KEY>.codex-skipped.json` 是否存在：

```bash
if [ -f "_bmad-output/implementation-artifacts/${KEY}.codex-skipped.json" ]; then
    echo "stage 4 skipped — codex review was unavailable for $KEY (see ${KEY}.codex-skipped.json)" >&2
    # 跳到 stage 5，不 spawn dev fix subagent
fi
```

如 marker 存在 → stage 4 整段**直接跳过**（包括 spawn / 验收 / commit）。理由：stage 4 的
工作就是修 codex finding，没 finding 等于无活可干。stage 5 在 §③.1 已被设为下一站。

如 marker 不存在（codex 正常跑过 stage 3）→ 按 §阶段 ④ 主体（下面）正常跑。

#### 阶段 ④.1：主体（codex review 已落地时正常跑）

**为什么本阶段不走 BMad skill 工作流**（这是有意设计，不要"修"）：本阶段本质是 **stage ② 的延续**——codex review 提出的每条 finding 都是"stage ② 没做好或漏掉的部分"，stage ④ 就是把这些缺口补上。

- `/bmad-dev-story` 工作流的状态机是"in-progress → review"，没有"已 review 后修反馈"的状态；强行调用反而打乱状态机。
- `/bmad-quick-dev` 是为"按用户意图实现新东西"设计的，不是为"按对抗式 review 反馈修旧东西"设计的，错位。
- 没有契合的现成工作流，那就直接 freelance + 用 prompt + 断点续作约定（`### Codex Review Handling (Stage 3)` 段每条一行）约束行为。这与 stage ②/⑤ 走 skill 工作流并不矛盾——后者是有清晰流程的工种，前者是"延续上一轮工作"。

**为什么 spawn fresh agent 而不是 SendMessage 复用 stage ② dev agent**：早期协议曾尝试"用 SendMessage + stage ② dev agent ID 复用上下文"。实测 agentId 是会话内有效，跨会话续作必废；同会话内 agent 完成 stage ② 后已 idle，SendMessage 也常常找不到。把"复用上下文"的设计幻想清除——本阶段统一 spawn fresh agent，让它从产物文件里重建上下文（story md + codex review + 实际代码）。

- 调度 dev fix：

  ```
  Agent({
    subagent_type: "general-purpose",
    description: "Dev fix codex findings <KEY>",
    prompt: <以下 prompt> + <`harness-prompt-suffix.py 4` 的 stdout，自动包含断点续作约定 + 代答政策附带段>
  })
  ```

  prompt 核心：

  > 你是续作 dev agent。之前的 dev 完成了 stage ② 实现，stage ③ 的 codex 对抗式 review 已写到固定路径。现在请逐条处理 codex 的 finding。
  >
  > **先做的事（必须按顺序）**：
  > 1. Read `_bmad-output/implementation-artifacts/<KEY>.md`（story spec + 当前 Tasks/Status/Dev Notes/Codex Review Handling 段）。
  > 2. Read `_bmad-output/implementation-artifacts/<KEY>.codex-review.md`（codex 报告主体 + 附录）。
  > 3. 如果 story md 已有 `### Codex Review Handling (Stage 3)` 段并已记录部分处理，按断点续作约定跳过已处理项。
  >
  > **处理顺序**：如果 codex 输出里自带严重程度分级（Critical / High / Blocker / Major / Medium / Low 等），按这个分级从重到轻处理；如果没有分级，就按 codex 列出的顺序处理。codex review 文件如果有附录（runs > 1 的额外 finding），同样纳入处理。
  >
  > **每条 finding 处理动作三选一**：
  > - **fixed**：改源码，列出改了哪些文件 + 简述改动
  > - **wontfix**：给明确理由（必须可追溯到 `.claude/harness/answer-policy.md` 的项目语境，比如"超出 MVP 范围"、"违反单人开发维护成本约束"）
  > - **deferred**：建 follow-up note 写到 story md 的 `## Follow-up Items` / `## Deferred Work` 段（如果不存在则新建），并在处理记录里引用 follow-up id
  >
  > 每处理完一条 finding，**立即**在 story md 的 `### Codex Review Handling (Stage 3)` 段追加一行记录（格式 `- [F-1 critical] <短描述> — fixed: 改了 <files>` / `- [F-2 high] <...> — deferred: FU-x.y.z`）。这是断点续作的 progress 来源。
  >
  > 任务结束条件：codex 主体 + 附录所有 finding 都各自有一条处理记录。然后停止，不要做任何 git 操作（add / commit / push / branch / tag / amend / mv / rm / restore --staged / stash 都不要）。修源码请直接用 Edit 工具。

- 等待返回。
- **验收**：story 文件 `### Codex Review Handling (Stage 3)` 段应当出现对每条 review 项的处理记录（行数应等于 codex review 文件里的 finding 数）。
- **commit**：`python3 .claude/harness/scripts/harness-commit.py 4 $KEY`，按 §−1.d 退出码处理。

### 阶段 ⑤：BMad 最终对抗 Review + 修复（独立匿名 agent）

> **bmad-code-review 实际接口要点**（写 prompt 前必须知道）：
> - review 对象是 **git diff**（基于 commit range / branch / working tree 选择），**不是 story md**。story md 作为 `{spec_file}` 即"验收上下文"传入，工作流最后会把 Review Findings 段追加回 story md 的 Tasks 下。
> - 工作流是 step-01 → 02 → 03 → 04 共 4 步骤，每步可能有 HALT 点：选 review target / 是否有 spec / 是否分块 / CHECKPOINT 总览 / decision-needed 逐条决议 / patch 处理方式三选一。
> - 选「Apply every patch」会让它直接改源码（step-04 §5）。
> - step-04 §6 它会**自己**把 story file Status 推进到 done。

- 进入前先准备：`STORY_FILE="_bmad-output/implementation-artifacts/$KEY.md"`；`STAGE2_BASE` 用阶段 ② 介绍的 `harness-state.py + 自动补 tag` 流程拿到（同一 SHA 在阶段 ②/③/⑤ 复用）。**tag 保持原位**——不要前推；如果 stage ② → ⑤ 之间有 `harness:` 元修改 commit 插入，bmad prompt 模板里的 pathspec `:!.claude` 会把它从 review diff 里排除（参考 §1 阶段 ② 边界情况）。
- 调度 review：

  ```
  Agent({
    subagent_type: "general-purpose",
    description: "BMad code review <KEY>",
    prompt: <以下 prompt> + <`harness-prompt-suffix.py 5` 的 stdout，自动包含断点续作约定 + 代答政策附带段>
  })
  ```

  prompt 核心：

  > 请直接调用 /bmad-code-review 对 story <KEY> 做最终对抗式 review。
  >
  > **review 配置（在 step-01 把这些当作 explicit argument，直接走 Tier 1，跳过 Tier 5 询问）**：
  > - review target = commit range `<STAGE2_BASE>..HEAD`（覆盖阶段 ②/③/④ 的全部提交，是本 story 的全部代码改动）。在 step-01 instruction 3 用 `git diff <STAGE2_BASE>..HEAD -- . ':!.claude'` 构造 `{diff_output}`——pathspec `:!.claude` 把 harness 元修改 commit（如 stage ② → ⑤ 之间用户授权的 `.claude/harness/scripts/**` / `.claude/commands/**` / `.claude/harness/answer-policy.md` 改动）从 review diff 里排除，避免 review 资源浪费在 harness 上；正确做法**不是**前推 `stage2-base` tag（前推会塌掉 stage ② 全部代码的 review 覆盖，曾导致 bmad 只看到 2.9% 的 diff 静默通过），而是让 tag 留在原位 + pathspec 排除。
  > - `{spec_file}` = `_bmad-output/implementation-artifacts/<KEY>.md`。
  > - `{review_mode}` = `"full"`。
  >
  > **碰到 HALT / CHECKPOINT 全部按以下默认值自决，不要等用户输入**：
  > - step-01 instruction 2 选 review target → 已给定（commit range），跳过本 HALT。
  > - step-01 instruction 4 是否有 spec → 已给定，跳过。
  > - step-01 instruction 6 diff > 3000 行是否分块 → **不分块**，按完整 diff 一次过。
  > - step-01 CHECKPOINT 总览确认 → **直接继续**。
  > - step-04 §4 decision-needed findings → **不要发问**，按 `.claude/harness/answer-policy.md` 自决，把决定+理由记录在 story file 的 Review Findings 段。每条决议后转化为 patch 或 defer。
  > - step-04 §5 patch 处理方式 → 选「**Apply every patch**」（即第 1 项），直接修复所有 patch findings。
  > - step-04 §6 后续任何选项 → 按 `.claude/harness/answer-policy.md` 默认值。
  >
  > **断点续作 progress（强制）**：每完成一条 finding 处理（patch / defer / dismiss / decision），立即增量更新 `_bmad-output/implementation-artifacts/<KEY>.review-progress.json`，结构：
  >
  > ```json
  > {
  >   "story_key": "<KEY>",
  >   "phase": "reviewing|patching|done",
  >   "findings": {
  >     "F1": {"status": "patched", "severity": "high", "files": ["..."], "ts": "<ISO>"},
  >     "F2": {"status": "deferred", "severity": "medium", "ts": "<ISO>"}
  >   }
  > }
  > ```
  >
  > 一旦中断重启，先 Read 这份 JSON，已在 `findings` 表里的条目**直接跳过**——不要重新发现 / 重新决议。
  >
  > **任务结束条件**：所有 decision-needed 和 patch findings 都 resolve、且没有未解决的 HIGH/MEDIUM/CRITICAL → 把 story file Status 段推进到 `done` + 把 review-progress.json 的 `phase` 设为 `done`。如果仍有未解决的 HIGH/MEDIUM/CRITICAL，**保持 status 为 review**——主 agent 会据此 halt。
  >
  > **机器可读完成门（强制额外产出）**：还必须用 Write 工具写出 `_bmad-output/implementation-artifacts/<KEY>.review-findings.json`：
  >
  > ```json
  > {
  >   "story_key": "<KEY>",
  >   "reviewer": "bmad-code-review",
  >   "unresolved": {"critical": 0, "high": 0, "medium": 0, "low": 0},
  >   "resolved": {"patches_applied": 0, "deferred": 0, "decision_needed_resolved": 0, "dismissed": 0},
  >   "final_story_status": "done | review"
  > }
  > ```
  >
  > 主 agent 会基于这个 JSON 做硬判定：`unresolved.critical + unresolved.high + unresolved.medium > 0` → halt。诚实填。
  >
  > **git 操作**：修源码请直接用 Edit 工具，但不要做任何 git add / commit / push / branch / tag / amend / mv / rm / restore --staged / stash。

  - 调用前主 agent 把 `<STAGE2_BASE>` / `<KEY>` 替换为真实值（`STAGE2_BASE` 用阶段 ② 介绍的 `harness-state.py + 自动补 tag` 流程拿到，同一 SHA 在阶段 ②/③/⑤ 复用）。
- 等待返回。
- **验收（独立校验，不只看子 agent 自报）**：
  1. story 文件 Status 必须已是 `done`。
  2. story 文件包含 `### Review Findings` 段（说明 review 真的走完了 step-04 §2）。
  3. **机器可读完成门已吸进 `harness-commit.py`**——主 agent 不再需要手动跑 python 一行命令。stage 5 commit 时脚本自动校验 review-findings.json schema、`unresolved.critical+high+medium == 0`、`final_story_status` 与 md 一致性；fail 时退出码 1 + 诊断行 `REVIEW_FINDINGS_*=`。
- **sprint-status sync**（chore-harness-epic-4-orchestration-observations T1.4，2026-05-04）：harness-commit.py stage 5 内部已自动跑 `_sync_sprint_status_for_stage("5", $KEY, ...)` → set $KEY done；主 agent **不再**手工跑兜底 set。漏 sync 由脚本兜住、commit 通过；脚本 IO 失败 → STATUS=halt + REASON=sprint-status auto-sync failed（按 §3 模板）。
- **commit row 5**：`python3 .claude/harness/scripts/harness-commit.py 5 $KEY`，按 §−1.d 退出码处理。STATUS=halt 且 REASON 含 `machine-readable completion gate failed` → 把 `REVIEW_FINDINGS_*=` 行贴给用户。STATUS=ok 时 stdout 含 `SPRINT_STATUS_AUTO_SYNC=set key=<KEY> value=done` 一行（如果 skill 漏 sync）— 仅信息，不需要主 agent 处理。
- **commit row 5 之后立即打 done tag**：脚本输出含 `SUGGEST_TAG=harness/<KEY>/done`，跑 `git tag harness/$KEY/done`。
- **commit row 5-fallback**：`python3 .claude/harness/scripts/harness-commit.py 5-fallback $KEY`。一般情况：上一步兜底已经把 sprint-status.yaml 带进 row 5 commit，此时 worktree 干净，脚本退出码 2（STATUS=skip），主 agent 跳过本步。仅当 row 5 commit 后 sprint-status.yaml 仍有变更时，脚本退出码 0，主 agent 跑 commit。
- **deferred-work 趋势输出（§L）**：commit 完成后跑下面这条 Bash 给用户一行可视化进度，零结构化卡点：

  ```bash
  DW=_bmad-output/implementation-artifacts/deferred-work.md
  SHORT=$(echo "$KEY" | awk -F- '{print $1"."$2}')   # 1-7-proxy-... → 1.7
  CLOSED_THIS=$(grep -cE "Resolved by Story $SHORT|Partial resolution by Story $SHORT" "$DW")
  TOTAL_RESOLVED=$(grep -cE "Resolved by Story|Partial resolution by Story" "$DW")
  TOTAL_ITEMS=$(grep -cE "^- \*\*" "$DW")
  echo "deferred-work: 本 story（$SHORT）关闭/部分关闭 $CLOSED_THIS 条；deferred-work.md 累计 resolved $TOTAL_RESOLVED / $TOTAL_ITEMS 条"

  # C11 扩展：再加一行按 story 维度的应消化 / 已消化 / 仍 pending 计数
  if STATUS_OUT=$(bash .claude/harness/scripts/grep_deferred_status.sh "$KEY" 2>/dev/null); then
      SUMMARY=$(echo "$STATUS_OUT" | grep -E '^Story ' || true)
      if [ -n "$SUMMARY" ]; then
          echo "deferred-work（按 story 维度）：$SUMMARY"
      fi
  else
      echo "deferred-work（按 story 维度）：报告生成失败"
  fi
  ```

  注意 `grep -c` 退出码非零时**仍会**把 `0` 写到 stdout，所以**不要**加 `|| echo 0`——否则会把两个 `0` 都拼进变量。

  作为本 story 进度回报的一部分输出给用户。不命中阈值、不 halt——纯趋势可视。`grep_deferred_status.sh` 失败也仅 echo "报告生成失败"，**不阻流**。
- 此后 `git log --oneline harness/$KEY/start..harness/$KEY/done` 即本 story 的完整提交序列。把当前 TaskCreate 任务标记 `completed`。

### 阶段 ⑤.5（条件触发）：Test Harness Invocation（chore C-bootstrap；review-only after T2.1）

阶段 ⑤ commit 完成（sprint-status `<KEY>` status=done）后、阶段 ⑥ 触发判断之前，自动调用 `/harness-zh:run-test` 跑本 story 的 atdd + e2e。设计意图：把测试纳入 run-sprint 主流水线，闭合"review 过仍出问题"的结构性 gap（详 chore-test-harness-bootstrap spec）。

> **2026-05-04 commit 路径统一（chore-harness-epic-4-orchestration-observations T2.1）**：本 stage 已改为 **review-only** —— `/harness-zh:run-test` subagent 内部走 T3 + T4 双 commit（颗粒度更细 + atdd 红相 vs e2e 绿相分阶段诊断）；run-sprint 主 agent 不再调用 5-5 commit 当 commit 路径，只做 (a) spawn → (b) 等返回 → (c) 验收产物 → (d) 跑 5-5 期待 STATUS=skip 用作 sanity gate。详 spec 段 Q3 RESOLVED 决策。
>
> **触发评估在 /harness-zh:run-test 内部完成**：`/harness-zh:run-test --story $KEY` 启动头部会调 `.claude/harness/scripts/eval_test_stage_triggers.sh` 读 `.claude/harness/test-stage-triggers.yaml` + `.claude/harness/harness-project-config.yaml` 自决跑哪些 stage（T1/T3/T4 + 进阶 T5/T6/CI/test-review）。run-sprint 主流程不传额外参数，也不预先解析触发条件——阶段 ⑤.5 仅负责调用入口 + 5-5 sanity gate。详 [`run-test.md`](run-test.md) §0.0.5。

**触发条件：** 阶段 ⑤ harness-commit 5 STATUS=ok 且 sprint-status `<KEY>` status=done。

**死循环 / 失控防护**：stage 5.5 任一异常路径**绝不阻** stage ⑥ 触发；测试失败 / runtime error / sandbox 受限都走 graceful 落地（subagent 内部 T4 commit 写 deferred-work + skipped report），主流水线继续推进。这与 §3 死循环防护表的核心理念对齐——harness 自动化的"完成开发"承诺不被测试结果反噬。

**步骤：**

1. **spawn run-test-sprint subagent**（subagent 内部跑 §0.1 env probe + §1 T1/T3/T4 + 各自 commit）：

   ```
   Agent({
     subagent_type: "general-purpose",
     description: "Test sprint <KEY>",
     prompt: <以下 prompt>
   })
   ```

   prompt 核心：

   > 请直接调用 /harness-zh:run-test --story $KEY。这是 run-sprint stage 5.5 自动触发，必须以 non-interactive 模式运行（任何 <ask> 节点都不要发问，按 `.claude/harness/answer-policy.md` 自决）。
   >
   > **重要**：subagent 内部走 T3 + T4 双 commit 路径（commit message 含 "(run-sprint stage 5.5)" 后缀）；sandbox graceful skip 路径 subagent 内部写 skipped-*.md + 跑 T4 commit。完成后停止，主 agent 不会再跑 5-5 commit；只会跑 5-5 命令做 sanity gate（期待 STATUS=skip）。

2. **等待返回。验收**：以下任一条件满足视为产物落地成功（worktree 应已被 subagent 内部 T3+T4 commit 干净；commit history 含 stage 5.5 后缀）：
   - `_bmad-output/implementation-artifacts/test_artifacts/$KEY-test-result.json` 存在（real e2e 路径）
   - `_bmad-output/implementation-artifacts/test_artifacts/skipped-$KEY-*.md` 存在（sandbox-bound graceful skip）

   产物 0 个（既无 result.json 也无 skipped-* report）→ halt（subagent 跑偏）。

3. **5-5 sanity gate**（chore-harness-epic-4-orchestration-observations T2.1 决策）：跑 `python3 .claude/harness/scripts/harness-commit.py 5-5 $KEY`：
   - **期望** STATUS=skip + REASON 含 "no worktree changes"（subagent 已通过 T3+T4 双 commit 落清 worktree） → 主 agent 跳过本 stage commit，继续走 stage ⑥
   - STATUS=ok（罕见 — back-compat 路径：例如外部 cron 直接跑老式 `just test-sprint`，subagent 没 commit）→ 主 agent 用 SUGGEST_COMMIT_MSG commit；这是 stage 5.5 single commit 旧路径的兼容兜底
   - STATUS=halt（worktree 仍有 unstage 残留，含 DIRTY_WORKTREE= 行）→ halt 走 §3 模板（subagent 漏 commit 或 worktree 污染）

**halt 触发**（与 §3 死循环防护表对齐）：

- run-test-sprint subagent 返回但 test_artifacts/ 产物 0 个 → halt（subagent 跑偏）
- 5-5 sanity gate STATUS=halt → 走 §3 模板（典型：worktree 有不属于 stage 5.5 期望产物的残留）
- runtime quota 信号（`hit your limit` / `rate limit` 等）→ halt（与其它 stage 同款）

**测试失败 ≠ stage halt：** verdict=red（atdd 红相未实施 / e2e 断言失败）只写 deferred-work `FU-Test-$KEY-failing` + result.json（subagent 内部 T4 commit 已落），**不**halt；stage ⑥ 自然触发，retro 阶段汇总 sandbox-skip + failing 列表，由 stage ⑥.5 (C10) 立成下个 epic 前置 chore（闭环）。

### 阶段 ⑥（条件触发）：Epic Retrospective

阶段 ⑤ commit 完成后，立刻判断当前 story 是否是其所属 epic 的最后一条 story：

```bash
EPIC=$(python3 .claude/harness/scripts/sprint-status.py epic-of $KEY)
if python3 .claude/harness/scripts/sprint-status.py epic-all-done $EPIC; then
    RETRO_STATUS=$(python3 .claude/harness/scripts/sprint-status.py epic-retro-status $EPIC || echo missing)
    # 只有 RETRO_STATUS != done 才跑
fi
```

如果 epic 全 done 且其 retrospective 状态不是 `done`：

- 调度 retrospective：

  ```
  Agent({
    subagent_type: "general-purpose",
    description: "Retrospective epic <EPIC>",
    prompt: <以下 prompt> + <`harness-prompt-suffix.py 6` 的 stdout>
  })
  ```

  prompt 核心：

  > 请直接调用 /bmad-retrospective，目标 epic 编号 = <EPIC>。这是 epic 完成后的回顾，必须以 non-interactive 模式运行（在工作流任何 <ask> 节点都不要发问，按 `.claude/harness/answer-policy.md` 自决）。
  >
  > 产出文件按工作流命名（一般是 `_bmad-output/implementation-artifacts/epic-<EPIC>-retro-*.md`），其中需要回答的回顾问题（What went well / What didn't / Action items / Next epic prep 等）请你以「单人 + AI 协作开发者」的视角自答，把所有 action item 都写入文件、并把每条标注 owner 为 'solo-dev'。如果出现需要选择的多选项，按 `.claude/harness/answer-policy.md` 的项目语境挑选并把理由写在文档里。
  >
  > 完成后停止，不要做任何 git 操作。

- 等待返回。
- **验收**：`ls _bmad-output/implementation-artifacts/epic-${EPIC}-retro-*.md` 应有至少一份新文件，且非空。
- **commit row 6**：`python3 .claude/harness/scripts/harness-commit.py 6 $KEY --epic $EPIC`，按 §−1.d 退出码处理。
- **sprint-status sync + retro_action_items seed**（chore-harness-epic-4-orchestration-observations T1.4，2026-05-04）：harness-commit.py stage 6 内部已自动跑 `_sync_sprint_status_for_stage("6", $KEY, $EPIC)` → set `epic-${EPIC}-retrospective done` + set `epic-${EPIC} done`，并自动 grep 最新 retro markdown §6 `^### {letter}[0-9]+` 提取 D items + seed `retro_action_items.epic-${EPIC}-retro` 块（idempotent — 已存在的 D item 不动；新增 D item 才追加）。主 agent **不再**手工跑兜底 set / 不再手工 Edit yaml seed。脚本 IO 失败 → STATUS=halt + REASON=（按 §3 模板）。
- **commit row 6-done**：`python3 .claude/harness/scripts/harness-commit.py 6-done $KEY --epic $EPIC`。stage 6 commit 中 sprint-status sync 已经把两个 epic 状态翻到 done + seed retro_action_items 块；如 stage 6 commit 后 yaml 还有变更（罕见 — 上一步 6 commit 通常已带走）→ 退出码 0 commit；否则退出码 2（skip）跳过本步。

如果 epic 还没全 done（即当前 story 不是该 epic 最后一条），跳过本阶段，直接进入下一条 story。

### 阶段 ⑥.5（条件触发）：Retro Residue Processing（Chore C10）

阶段 ⑥ retro commit 完成后、阶段 ⑥ "epic-${EPIC}: mark done" 翻 done 之前，触发 retro residue processing。这是把刚生成的 retro 中 pending / partial / in-progress action items 转为可执行 `chore-retro-c${EPIC}-<code>-<slug>.md` 前置 spec 的环节，让 solo-dev 后续按 [`CLAUDE.md`](../../CLAUDE.md) "自动续作约定" 路径 B 手工实施。

**触发条件：** 阶段 ⑥ retro 已 done 且 sprint-status.yaml 含 `retro_action_items.epic-${EPIC}-retro` 子段（C1 落地后自动满足）。

**步骤：**

1. 跑 `bash .claude/harness/scripts/process_retro_residue.sh --epic $EPIC`：
   - 退出码 0 → stdout 含 fresh agent prompt + retro markdown 全文 + 待 process 列表（≥ 1 项）
   - 退出码 2 → stdout/stderr 含 "no residue to process" → 跳过本阶段，直接进 ⑥ "mark done"
   - 退出码 1 → halt（脚本错误 / 文件缺失 / yaml 异常 — 走 §3 模板）

2. 把 stdout 拷给 fresh general-purpose agent：

   ```
   Agent({
     subagent_type: "general-purpose",
     description: "Process retro residue epic-<EPIC>",
     prompt: <process_retro_residue.sh stdout 全文>
   })
   ```

3. fresh agent 返回多个 `=== FILE: chore-retro-c${EPIC}-<code>-<slug>.md ===` / `=== END FILE ===` 块 + **一个 `=== MANIFEST === / <code>: <dev|harness> / === END MANIFEST ===` block**（每行 `<code>: <dev|harness>`）+ 末尾 ≤ 200 字总结。MANIFEST 是 2026-05-05 Q4 B 方案 category 分流的输出契约 — 详 [`.claude/harness/architecture.md`](../harness/architecture.md) §六 Q4。

4. 主 agent 解析每个 FILE block，逐个用 Write 工具写到 `_bmad-output/implementation-artifacts/<filename>`。

5. 主 agent 解析 MANIFEST block，得到 `<code> → <dev|harness>` 映射表。**MANIFEST 缺失 / 行数与 FILE 不一致 / 单条 category 不在 {dev,harness}** 一律 graceful fallback：缺的 / 非法的项默认归 `harness`（保守 — harness 类不阻 epic，错分代价 = solo-dev 起步约定看到 WARN 时手动改回 dev）+ 在主 agent 自报段输出一行 `MANIFEST_FALLBACK=<reason>`，**不**halt。这是 B 方案（2026-05-05 Q4）"harness 类不阻 epic"的延伸 — fresh agent 分类瑕疵不能升级成阻 epic。

6. 主 agent 用 Edit 工具修改 `sprint-status.yaml`：在 `retro_action_items.epic-${EPIC}-retro.<code>` 行下追加缩进更深的两个子字段（每个被 process 的项两行）：
   - `chore_spec: '<filename>'`
   - `category: <dev|harness>`（取自 MANIFEST；MANIFEST 缺该 code 时默认 `harness`）
   **不**加任何 `chore-retro-cN-residue:` 段；**不**动 `development_status:` 段。

7. **sanity check（主 agent 强制跑）**：
   - `grep -E "chore-retro-c[0-9]+-residue:" _bmad-output/implementation-artifacts/sprint-status.yaml` — 必须 empty（Q2 RESOLVED 边界）
   - `git diff sprint-status.yaml` 必须仅触及 retro_action_items 子段；不含 development_status 改动
   - `ls _bmad-output/implementation-artifacts/chore-retro-c${EPIC}-*.md | wc -l` ≥ 待 process 数
   - 每个新生成 spec：`grep -L "frozen-after-approval\|Tasks & Acceptance\|Code Map" <spec>` 必须 empty（每段都含）
   - `grep -l "自动生成\|fresh agent\|auto-generated" chore-retro-c${EPIC}-*.md` 必须 empty（spec 不得含此字样）
   - `bash .claude/harness/scripts/check_retro_action_items.sh` — 不要求退出码（dev pending 的存量本来就可能 ≠ 0）；仅看 stderr 是否新增 PENDING_NOCAT / WARN（信息性，不阻流）

8. **commit row 6-5**：`python3 .claude/harness/scripts/harness-commit.py 6-5 $KEY --epic $EPIC`：
   - STATUS=ok → 主 agent 用 SUGGEST_COMMIT_MSG（形如 `chore(retro-c$EPIC): process residue → N chore specs`）commit
   - STATUS=skip（worktree 干净）→ 跳过；不阻流（罕见 — 上一步若已写文件理应有 diff）
   - STATUS=halt → 走 §3 模板

**halt 触发**（仅"机器没法自决"的硬错误，与 §3 哲学一致 — category / MANIFEST 类瑕疵走 fallback 不 halt）：
- fresh agent 输出非法（缺 FILE marker / spec 段结构破损 / 含禁用字样"自动生成 / fresh agent / auto-generated"）→ 主 agent 不写文件 + halt
- spec 命名冲突（已存在同名磁盘文件）→ halt + 让 solo-dev 决断
- 上面 sanity check 的前 5 项任一失败 → halt（最后一项 checker 是信息性，不计入 halt）
- harness-commit.py 6-5 STATUS=halt → 走 §3 模板

**不阻 ⑥ "mark done" 翻转：** 阶段 ⑥.5 失败时，epic-${EPIC} retro 已 done 状态稳定；残留处理是**下个 epic 启动前**的 gate（C1 pre-commit hook 已 enforce），不是本 epic 的 gate。所以即使 ⑥.5 halt，主 agent 仍可走 ⑥ "mark done"（solo-dev 决断后人手再补）。但默认行为是：halt → 等 solo-dev 介入；不擅自跳过。


---

## 2. 主循环

LOOP_SCOPE 决定退出条件——不要把"还有没有 backlog"当作唯一退出依据。

```
# 顶层 dry-run 分支
if LOOP_SCOPE == "dry-run":
  按 §0.0 解析的目标范围（all / single-story / single-epic）枚举每条预期会跑的 story
  对每条 story 输出一行计划摘要（5 阶段路径 + 预期 commit subject）
  不调任何子 agent、不 commit
  退出

# 顶层 retro-only 分支（§0.C 已切到本路径）
if LOOP_SCOPE == "single-epic" and 已走 §0.C 路径:
  跑 §1 阶段 ⑥（无条件触发）
  退出

# 顶层 continue-single 分支
if LOOP_SCOPE == "continue-single":
  按 §0.B 切入点跑 $TARGET_KEY 的剩余阶段（含触发的阶段 ⑥）
  退出

# 顶层 single-story 分支
if LOOP_SCOPE == "single-story":
  跑 $TARGET_KEY 的 §1 阶段 ①…⑤（含触发的阶段 ⑥，如果它是该 epic 最后一条）
  退出

# 默认循环（LOOP_SCOPE == "all" 或 "single-epic" 且仍有该 epic 的 backlog）
loop:
  next_key = `python3 .claude/harness/scripts/sprint-status.py next`  # 退出码 1 = 无 backlog
  if 无 backlog:
    if LOOP_SCOPE == "single-epic" and `epic-retro-status $TARGET_EPIC` != "done":
      走 §0.C retro-only 路径触发 retrospective
    break

  if LOOP_SCOPE == "single-epic":
    epic_of_next = `python3 .claude/harness/scripts/sprint-status.py epic-of $next_key`
    if epic_of_next != $TARGET_EPIC:
      # 边界：next backlog 已跨到下一个 epic（target epic 在本轮内已跑完，retro 已在阶段 ⑥ 触发）
      break

  跑阶段 ①…⑤
  跑阶段 ⑥（仅当当前 story 是其 epic 最后一条且该 epic retrospective 还未 done）
  把进度（"M/N 完成 (LOOP_SCOPE=<value>)"）简短回报用户一行
goto loop

report "🎉 完成 (LOOP_SCOPE=<value>, target=<key 或 epic 或 -—>)"

# Codex-skipped 提醒（v0.1.27+）：本轮（或更早）有 codex 不可用导致 stage 3+4 跳过的 story?
SKIPPED_COUNT=$(ls _bmad-output/implementation-artifacts/*.codex-skipped.json 2>/dev/null | wc -l | tr -d ' ')
if SKIPPED_COUNT > 0:
    print loud notice 给用户:
        ┌──────────────────────────────────────────────────────────────────┐
        │ ⚠️  Codex review pending — 仍有 N 条 story 未做 stage 3+4         │
        │                                                                  │
        │ 这些 story 在 stage 3 时 codex-in-cc 不可用 → 显式跳过 + 留 marker │
        │ 现在 sprint 已跑完，但 codex 对抗 review 这一档**还没做**。       │
        │                                                                  │
        │ Marker 文件：                                                    │
        │   <列每个 *.codex-skipped.json basename + reason>                │
        │                                                                  │
        │ 待 codex 恢复后跑：                                              │
        │   /harness-zh:codex-catchup                                      │
        │                                                                  │
        │ 一次性补上所有 skipped story 的 stage 3+4。                      │
        └──────────────────────────────────────────────────────────────────┘

report "💡 这一轮跑下来如果有任何 plugin 行为不顺手 / 文档误导 / 教学缺口 — 跑 /harness-zh:report-issue（自动收集本轮 sprint 上下文 + 一键直提到 Niutie/my-cc-plugin）"
```

**主 agent 实操要点**：上面的 SKIPPED_COUNT 检查必须用 Bash + `ls | wc -l` 实跑（不是揣测），数字 > 0 时**必须**把 loud notice 完整打印给用户（不要悄悄省略 / 缩成一行）。这是 codex-skipped 显式可见性契约的最后一道——sprint 跑完前的最后机会，不让用户忘了 catchup（codex-review 2026-05-09 high #2 配套硬化）。

**主 agent 在每次回到循环顶部时必须重新检查 LOOP_SCOPE**（不要假设"既然进了循环就一直跑"）——以防有 LOOP_SCOPE = `single-epic` 跑完目标 epic 后却继续跑别的 epic 的 bug。

---

## 3. 死循环 / 失控防护（**必须严格遵守**）

这是用户的核心要求。任何一项触发都立即 halt，不要尝试自愈。注意：**子 agent 提问/请求确认不在此列**——按 §−1.b 代答政策处理，不计入失控。

| 触发条件 | 处理 |
|---|---|
| 子 agent 返回包含 `hit your limit` / `rate limit` / `usage limit` / `quota` / `reset` 等配额耗尽信号 | halt 并使用配额耗尽专属 halt 模板（选项 5）：等待 reset 时间后再让用户决定是否重启 stage（这是文本扫描唯一保留的一类——见 §-1.b 说明）。续作时主 agent 调 `harness-state.py --resume-prompt --stage <N>` 拿 deterministic prompt 段（harness-changelog 2026-05-03 §D），不要手工拼描述。 |
| 预期产物文件缺失或为空（每阶段"验收"列出的） | halt（不重新拉 agent，让人介入） |
| `harness-commit.py` 退出码 1（STATUS=halt）：黑名单 / 跨 story 隔离 / 预期外 artifact / 禁止的项目代码 / 未 staged 残余 / dev-result.json 或 review-findings.json schema 失败 | halt（脚本输出含具体诊断行 `BLACKLIST=`/`CROSS_STORY=`/`UNEXPECTED_ARTIFACT=`/`FORBIDDEN=`/`UNSTAGED=`/`DEV_RESULT_*=`/`REVIEW_FINDINGS_*=`，按 §−1.d 贴给用户）。**注意**：harness-changelog 2026-05-03 §A 起，subagent 偏离 schema 多产 `<KEY>.bmad-code-review.md` 等额外 .md 会被脚本自动剔除（输出 `AUTO_FIXED=unexpected-md ...`），不再触发 halt；§B 起，spec frontmatter `cross_story_artifacts:` 白名单内的 cross-story 路径自动放行。这两类已不计入 halt。 |
| 子 agent 返回 message 缺失 `git status --porcelain` 自报段（harness-changelog 2026-05-03 §M） | 主 agent **不 halt**，但必须自己跑 `git status --porcelain` 并交叉验证 worktree 状态。如果发现 subagent 实际改了它声称未改的文件（如 2-7 main.go 那种 BMad workflow 内部子工作流偷偷改文件的情况）→ halt 给用户决策（subagent 跑偏的 worktree 污染需要人介入判断"真 fix vs 垃圾"）。 |
| 阶段 ② 校验失败（`DEV_RESULT_MISSING` / `DEV_RESULT_FAIL_PARSE` / `DEV_RESULT_FAIL_CHECK` / `DEV_RESULT_STATUS_MISMATCH` / `DEV_RESULT_STATUS_MISSING`） | halt（脚本已自动校验；含义：dev-result.json 缺失 / JSON 解析失败 / `checks.<x>` 是 `fail` 或非法值（旧 schema 等价）/ `final_story_status` 与 story md 不一致 / md 缺 Status 行） |
| 阶段 ⑤ 完成后 story md Status 不是 `done` | halt（不要自动改成 done — 可能是 review 出了 critical 没修） |
| 阶段 ⑤ 校验失败（`REVIEW_FINDINGS_MISSING` / `REVIEW_FINDINGS_FAIL_PARSE` / `REVIEW_FINDINGS_UNRESOLVED` / `REVIEW_FINDINGS_STATUS_MISMATCH` / `REVIEW_FINDINGS_STATUS_MISSING`） | halt（脚本已自动校验；`UNRESOLVED` 含义：critical+high+medium > 0；其余字段同 stage ②） |
| 阶段 ② → ④ 之间产物被改回（status 又回到 in-progress） | halt |
| 单条 story 累计调用 > 6 个子 agent（5 阶段 + 至多 1 次 stage ⑤ 中断重启） | halt |
| 你发现自己第二次进入"修阶段 ④ 又 review 又修"模式 | halt（流水线**只有一次**修复机会） |
| 在 0.A 启动模式 `git status --porcelain` 不为空 **且** `find-by-status review` 也找不到任何 review 状态 story | halt（worktree 有不属于任何在跑 story 的脏数据，需要用户介入清理或解释；0.A 默认会自动切续作，仅当无可续作 story 时 halt——见 §0.A） |
| 同一 subagent 连续 2 次发问（即第一次代答政策没让它停止追问） | halt（异常 prompt 行为，需要人看） |

**绝对禁止**的逃逸路径：
- 跳过任何阶段
- 把失败的子 agent 重新拉一次（代答政策重发不算）
- 自动决定"小问题忽略"继续推进
- 把 story 从 done 改回早期状态再跑一遍
- 用户授权了"代答最优方案"，但**不等于**授权你跳过失败 — 失败仍然 halt
- **任何**自动 git 撤回 / reset / tag 删除 / branch 切换。撤回是用户的特权，不是主 agent 的。

### Halt 时主 agent 必须做的事（不可省略）

每次 halt 之前，主 agent 必须给用户输出这一段（替换 `$KEY` 为真实值）：

```
🛑 已 halt。当前 story: $KEY，halt 触发条件：<原因>。

可选操作（你来决定，主 agent 不会自动做任何一种）：
  0. （**配额耗尽 halt 优先 try 此项**，chore-harness-epic-4-orchestration-observations T4.3，2026-05-04）
     先跑 halt-recovery-check 探产物 ground truth：
       python3 .claude/harness/scripts/harness-state.py $KEY --halt-recovery-check --stage <N>
     输出 3 类 verdict（仅诊断，不副作用）：
       READY_TO_COMMIT  → work 已落地（典型：subagent 写产物后 quota 在 return summary 中耗尽）；可直接跑 `harness-commit.py <N> $KEY` 继续推进，跳过 fresh subagent
       NEED_RESUME      → work 未落地；走选项 5（fresh subagent）
       INCONSISTENT     → 部分齐部分缺；进选项 3 现场调查决断
  1. 整条撤回本 story（含全部子 agent 的 commit）：
       git reset --hard harness/$KEY/start
  2. 撤销当前未提交的 worktree 变更，保留之前阶段的 commit：
       git restore --source=HEAD --staged --worktree -- .
     （适用于：子 agent 中途中断后留下脏 worktree）
  3. 不撤回，进现场调查：
       git log --oneline harness/$KEY/start..HEAD
       git diff
  4. 修完之后想继续从下一条 story 跑：
       /harness-zh:run
     （主 agent 会重新拿 next backlog；本 $KEY 此时应已是 done 或被人为推进）
  5. （仅配额耗尽 halt 时）等到 reset 时间，告诉我"重启 stage <X>"我会重新调度该阶段子 agent
     （注意 stage ②/④/⑤ 的子 agent prompt 末尾带"断点续作约定"，重启时新 agent 会读 progress 文件跳过已完成项；不需要从零重做）
  6. 怀疑这是 plugin 缺陷？跑 /harness-zh:report-issue
     主 agent 会自动收集 plugin 版本 / 当前 story / halt 现场 / 近期 commits 拼好 issue body，
     用 gh CLI 直接提到 https://github.com/Niutie/my-cc-plugin/issues/new。
     提交成功后会附一个**临时绕过方案**让你不必等 plugin 修复就能继续推进项目。

子 agent 完整返回 / 脚本完整 stdout 如下：
<逐字粘贴子 agent 的最终消息或脚本输出>
```

这是 halt 的硬约束——任何场景都打印这段，不要简化、不要替用户选 1/2/3/4/5/6。


---

## 4. 用户中断点

用户随时可以打断你（Ctrl+C 或新 prompt）。你应当在每条 story **完成后**（阶段 ⑤ commit 之后、loop 回到顶部之前）短暂停顿一下，给用户一行进度回报。这是天然的中断窗口。

---

## 5. 参数

允许用户在触发命令时附加。下面的"目标范围解析"决定 §2 主循环何时退出，由 §0.0 在启动时绑定到主 agent 上下文中：

| 参数 | LOOP_SCOPE | 语义 | 何时停 |
|---|---|---|---|
| 无参数 | `all` | 跑完所有 backlog story（每个 epic 完成时自动触发该 epic 的 retrospective） | sprint-status 已无 backlog |
| `--story` | `single-story` | 跑下一条 backlog story 然后停 | 该 story 的 §1 走完（含触发的阶段 ⑥，如果它是该 epic 最后一条） |
| `--story <key>` | `single-story` | 强制从指定 key 开始（无论 backlog / review / 续作场景）。如果该 key 已有 `harness/<key>/start` tag，自动启用 §0.B 续作模式 | 同上 |
| `--epic` | `single-epic` | 跑当前 epic 剩余的全部 backlog story（含 retrospective）然后停。"当前 epic" = 下一条 backlog 所属的 epic（如果当前 epic 全 done，自动滑到下一个有 backlog 的 epic） | 该 epic 的所有 backlog 已 done + retro 已 done |
| `--epic <num>` | `single-epic` | 跑指定 epic 编号下的全部 backlog story（含 retrospective）然后停。如果该 epic 已全 done 但 retro 未做 → 走 §0.C retro-only 路径仅触发 retro；如果该 epic 已全 done 且 retro = done → 直接退出回报"该 epic 已完成" | 同上 |
| `--continue` | `continue-single` | 续作上次中断的 story（典型场景：开发到一半断网 / runtime quota / 主 agent 崩溃）。不指定 key 时取最近一条 `review` 状态的 story；走 §0.B 流程，调 `harness-state.py` 决定切入点。worktree 可以不干净 | 跑完续作的那一条就停（不滚动到下一条 backlog） |
| `--continue 继续完成当前这个story` | `continue-single` | 自然语言版的 `--continue`（中文向） | 同上 |
| `--dry-run` | `dry-run` | 不调子 agent、不 commit，只打印每阶段计划（用于第一次验证手册） | — |

**`--one` 已被废弃**（语义模糊：是哪一条？是当前 epic 还是当前 backlog？）—— 等价语义现在用 `--story`（无 key）表达。

**LOOP_SCOPE 的每条退出条件**在 §2 主循环里有对应的 `if` 分支，主 agent 必须严格遵守："要不要拉下一条 backlog"由 LOOP_SCOPE 决定，而不是由"还有没有 backlog"决定。

如果用户没有传参，就按 §0.A 全新启动 + §2 主循环（LOOP_SCOPE=`all`）跑到底。

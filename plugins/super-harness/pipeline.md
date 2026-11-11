# 单条 story 流水线

本文件是一条 story 从起跑到 epic retro 的执行手册，部署在项目的 `.claude/harness/pipeline.md`。它不是 slash 命令，由下面三种角色读取，各自只负责其中一段：

| 模式 | 谁在读 | 负责的步骤 |
|---|---|---|
| inline | `/super-harness:run-inline` 的主 agent，在用户当前会话里 | 全部：§0.A.0、B0 到 B4、⑥、⑥.5、verdict 门、§2 收尾提醒 |
| lane | `/super-harness:run` 起的 worker，一个 headless `claude -p` 进程，在自己的 git worktree 里 | 只到 B3。B3 完成（或按条件跳过）就回报，然后结束 |
| 调度 | `/super-harness:run` 的调度者，在主 worktree 里 | lane 合流之后的 B4，epic 收尾的 ⑥、⑥.5，以及 §0.A.0 |

正文里标着「lane 模式」「inline 模式」「调度模式」的段落只对该模式生效；没有标注的步骤，各模式做法相同。lane 模式的回报命令和占位符写在 worker prompt（`.claude/harness/prompts/worker.md`）里。

章节编号沿用 harness-zh `run.md` 的编号（§−1、§0.A.0、§0.B、§0.5、§1、§3），脚本注释和测试里引用的 `pipeline.md §1 B2.2` 之类的位置与旧版一一对应。

## −1. 主 agent 行为契约（贯穿全流程）

**(a) 监控信号**：你用 `Agent` / `SendMessage` 调度子 agent 时是同步等待的——子 agent 返回的那条消息就是"完成信号"。本手册里每一次 Agent 调用都要显式传 `run_in_background: false`，包括只用文字描述、没写代码块的 dispatch（§0.A.0、⑥.5）。不传这个参数不等于同步，有的环境默认后台运行；lane 模式下 worker 是 headless 的 `claude -p`，本轮一结束进程就退出，后台的子 agent 会被一起结束（issue #16）。每次调用后做两件事：
1. **看产物 / 跑审计**：每个阶段都列了"验收"项（B1/B3 是 `harness-commit.py build-verify`）。失败 → halt。
2. **看状态**：`python3 .claude/harness/scripts/harness-state.py $KEY --plain` 只读核对。发现与预期不符**不要**手工 `set`：sprint-status 推进只发生在 B4 `build-sync`（以及 retro 阶段），由 `harness-commit.py` 统一完成。

**送错对象的完成通知**（issue #20）：子 agent 自己派的子 agent（例如 B1 build agent 里 bmad-build-auto 派的实现子 agent）完成时，通知有时会送到你这里，而派它的那一层还在等。收到一条完成通知、它不是你直接派出的那个子 agent 时，不要自己接着做那一步，用 `SendMessage` 把通知原文转给派它的子 agent（B1 / B3 的 build agent），开头写一句「这是你派的 <描述> 的完成通知，按它继续」。build agent 的 prompt 后缀里也写了：通知迟迟不来、而那个子 agent 的产物已经落地时，它按产物继续。

**结构化校验优先，不做文本扫描**：主 agent 不在子 agent 返回文本里搜 `error` / `failed` 之类的词判断成败（误报极高）。真正的失败一定能被结构化校验抓到：build-verify 的 `SPEC_STATUS_NOT_DONE=` / `DIRTY_WORKTREE=` / `CROSS_STORY=`，`harness-commit.py` 的退出码 1。

**配额耗尽的判定**：Claude 运行时的额度耗尽在结构化层看不到，但也**不靠搜关键词**。story 本身可能就在做限流、鉴权、密码重置，子 agent 的正文里出现 `quota` / `rate limit` / `reset` / `unauthorized` 很正常。只有下面两条同时成立才算配额耗尽：
1. 结构化校验已经失败：build-verify 报 `SPEC_STATUS_NOT_DONE=` / `SPEC_MISSING=`，或某阶段的"验收"产物缺失；
2. 子 agent 的返回**第一行**就是 Claude Code 运行时的额度报错，以 `Claude AI usage limit reached`、`You've hit your limit`、`5-hour limit reached`、`API Error: 429` 之一开头（这类返回通常只有一两行，没有子 agent 自己写的正文）。

两条都满足 → halt，按 §3.1「配额耗尽」那一行给选项。只满足第 1 条 → 普通 halt。`API Error: Overloaded` 之类不是配额，按各阶段的瞬态错误规则处理。codex 的额度、登录问题不走这一条，看 `run_codex_review.sh` 输出的 `CODEX_STATUS:`（§B2.2）。

> **关于 git index**：bmad-build-auto 自己 commit；harness 自己的 commit（B2 的 3/4、B4、retro）一律经 `harness-commit.py` 预先 stage。主 agent 任何时候都不自己 `git add`。

**(b) 代答政策**：用户授权你在循环中替他回答所有 BMad / Codex 子 agent 的问询。通用决策原则在 `.claude/harness/answer-policy.md`，项目语境由 `harness-prompt-suffix.py` 从 harness-project-config.yaml 读出并内联进 prompt 后缀。

1. **每一个** subagent prompt 末尾都必须附带 prompt 后缀，**不要手贴**，改用：
   ```bash
   python3 .claude/harness/scripts/harness-prompt-suffix.py <stage> --file
   ```
   `--file` 把完整后缀（调度契约、代答政策、项目语境，约 5000 字）写进 `.git/super-harness/suffix/<stage>-<hash>.md`，stdout 只有两行：一句「先 Read 这个文件」和一个标记 `[harness-suffix <stage> <hash>]`。把这两行原样接在 prompt 末尾（前面空一行加 `---`）。不要改写、不要用占位符代替，也不要只写「见后缀」：手贴长后缀时出现过三次把它写成占位符（`BUILD_SUFFIX_PLACEHOLDER`、`FILLER_SUFFIX`、`$(SUFFIX)`），子 agent 因此拿不到代答政策（issue #21）。lane 模式下 `superh.py launch` 会检查 worker 派出的 B1 / B2.3 / B3 prompt 里有没有这个标记，没有的记进调度者的收件箱。
   stage 取值：`build`（B1/B3）/ `4`（B2 fix）/ `6`（retro）/ `chore`（§0.A.0 retro-fulfill）。`implement` 由 bmad-build-auto 的实现子 agent 自己拉取，主 agent 不用。B2.2 codex review 由主 agent 直接跑脚本，不起子 agent，`3` 不再使用。`1` / `2` / `5` 只给 §1.L 旧流水线 story 用。
2. bmad-build-auto 本身无人值守、不提问；intent 不清会 HALT `blocked`。其它子 agent 若仍提问回来（罕见），用 `SendMessage` 重发一次"按 `.claude/harness/answer-policy.md` 自决"，**不要**转给用户。
3. 真正必须 halt 的只有 §3 列出的硬错误。"我需要你确认 X / Y" 不属于硬错误。

**(c) 进度可视化**（inline 模式）：用 TaskCreate 在启动时为每条要跑的 story 建一个任务，之后用 TaskUpdate 改状态：进入流水线时 `in_progress`，完成时 `completed`。lane 模式和调度模式不调用 TaskCreate / TaskUpdate / TaskList，lane 模式也不调用 AskUserQuestion。

**(c′) lane 模式的额外约束**：
- 只在自己的 worktree 里工作。不 `cd` 到主 worktree 或其他 lane 的目录，不切分支，不 merge / rebase / reset，不删除或移动任何 tag（新打本 story 的 tag 除外）。
- 不碰 `sprint-status.yaml` 里本 story 的状态。账本由调度者在合流后统一写。
- 本手册要求「halt 并把 §3 模板贴给用户」的地方，lane 模式先看 §3.3：intent gap 这类有推荐读法的问题、验证命令超时，可以自己接着走。§3.3 不适用时，按 worker prompt 的回报命令报 `blocked`（配额耗尽报 `quota`），把 halt 原因和脚本完整输出写进 `--halt`，然后结束。§3.3 之外不尝试自愈，也不重跑失败的子 agent。
- 不移动、不删除 tag 的唯一例外是 `superh.py reopen`：它重开 spec 时会把 `followup-start` 挪到新提交上，由脚本完成，worker 自己不动 tag。

**(d) Commit 协议**：

| 谁 commit | 哪些阶段 | 主 agent 怎么守门 |
|---|---|---|
| bmad-build-auto 自己（Finalize 步骤） | B1 build、B3 follow-up | 事后跑 `harness-commit.py build-verify $KEY`：审计 `harness/$KEY/start..HEAD` 区间的每个路径（凭据黑名单 / `_bmad-output` 越界 / 跨 story 隔离）+ spec 终态 + 工作区干净 |
| 主 agent 经 `harness-commit.py` | B2 `3` / `4`、B4 `build-sync`、⑥ `6` / `6-5` / `6-done`、§0.A.0 `retro-fulfill` | 脚本列变更 → 黑名单 → 跨 story 隔离 → 按 stage 预期产出分类 → `git add --` → sanity check；主 agent 只按退出码 commit |

`harness-commit.py` 退出码：
- **0（STATUS=ok）**：脚本已 stage 好，输出 `SUGGEST_COMMIT_MSG=`（和可能的 `SUGGEST_TAG=`）。主 agent 用 HEREDOC + `Co-Authored-By:` 行 `git commit`，用脚本建议的 message；有 `SUGGEST_TAG` 就**立即** `git tag`。
- **1（STATUS=halt）**：拒绝 commit。按 §3 halt 模板把脚本完整 stdout 贴给用户。
- **2（STATUS=skip）**：没有可提交的变更。跳过 commit；如输出里仍有 `SUGGEST_TAG=`（`build-sync`），照样打 tag。

`build-verify` 退出码：0 = 审计通过；1 = halt（commit 已经存在，主 agent **不撤**，交用户决定）。

**绝对禁止**：
- 主 agent 自己写 `git add` / `git add -A` / `git add .`。
- 主 agent 自己"修复"脚本拒绝的路径（`git checkout -- file`、reset、revert 等）。halt = 用户介入。唯一例外是 §B2.1 c) 里那一个未入库的 `<KEY>.codex-review.md`，按那里给的命令删。
- 在 bmad-build-auto 运行前改工作区（它要求干净工作区，否则 HALT）。B1 之前唯一允许的写操作是 `git tag`。

---

## 0. 起跑前的共用步骤

### 0.A.0 retro DEV items 兑现前置 gate（issue #3；harness-zh v0.2.0 起对任意 epic 生效）

inline 模式和调度模式在主 worktree 里执行本节，lane 模式不执行。

**动机**：`retro_gate: block` 时，pre-commit gate ① 在有未兑现 `category: dev` retro action item 时拒绝新 story spec 的 commit。bmad-build-auto 在**最后**才 commit，被 hook 拦下时整条 story 的 token 已经花完，而且它会 HALT `finalization left repository dirty`。所以在 dispatch B1 **之前**把这些 dev 项清掉；清不掉就不 dispatch。

**先读模式**：`python3 .claude/harness/scripts/harness_config.py --get retro_gate --default warn --quiet`。
- `warn`（默认）→ hook 不拦，本节只跑下面的「检测」，把 `_PENDING_DEV_` / `_WITH_SPEC_` / `_NO_SPEC_` 三个数告诉用户一行（"有 N 条未兑现 dev retro 项，retro_gate=warn 不阻塞；想先兑现就把 retro_gate 设为 block 重跑"），然后进 §1，**不跑兑现循环、不 halt**。
- `block` → 按本节全部步骤执行。

执行时机：inline 模式在 `run-inline` §0.A 末尾、进入 §1 之前执行，每次跨 epic 进入新 epic 的第一条 story 前再执行一次（见 `run-inline` §2）。调度模式在某个 epic 第一次有 story 启动 lane 之前执行（`run` §2），同一个 epic 只做一次。

**检测**：

```bash
bash .claude/harness/scripts/grep_pending_dev_retro_items.sh
```

stdout 每个待兑现 dev 项一行 `ITEM<TAB><epic-N-retro><TAB><CODE><TAB><status><TAB><chore_spec|->`，末尾 `_PENDING_DEV_:<N>` / `_WITH_SPEC_:<M>` / `_NO_SPEC_:<K>`。

- `_PENDING_DEV_:0` → 跳过，进 §1。
- `N>0` → 告诉用户：检测到 N 条未兑现 dev retro 项（M 条有 chore_spec 可自动兑现 / K 条缺 spec），先清掉再起跑。

**兑现循环**（对每个有 chore_spec 的 ITEM，逐项串行）：设 `CODE` / `EPIC`（取自 `epic-${EPIC}-retro`）/ `SPEC`（`_bmad-output/implementation-artifacts/$SPEC`）。

1. **实现**：spawn 一个 fresh general-purpose subagent（`run_in_background: false`），prompt = `$SPEC` 全文 + "按本 chore spec 的 Tasks & Acceptance 段实现项目代码；这是一次性 chore 兑现，**不走** bmad-build-auto / codex / review 循环；完成后在 spec 的 Tasks checkbox 打勾。只动 spec 描述范围内的项目代码，不碰其它 story 的 artifacts；spec frontmatter 若声明了 `planning_artifacts:` 白名单（issue #9），按 spec 要求回写那些文件也在范围内。不要做任何 git 操作。" + `python3 .claude/harness/scripts/harness-prompt-suffix.py chore --file` 的 stdout。
2. **翻状态**（两本账一起翻，不要用 Edit 手改）：
   ```bash
   python3 .claude/harness/scripts/sprint-status.py retro-item-done ${EPIC} ${CODE}
   ```
   它先翻原生 `action_items` 里的 `epic-${EPIC}-retro-${CODE}`（有 uv 和上游 bmad-retrospective 脚本时走上游 `--set-action-status`，这是 BMad 规定的改法；没有就只改那一行 status；没有这一项时输出 `NATIVE=missing`，跳过），再把 `retro_action_items` 里这一条翻成 `done`。退出码 1、`NATIVE=failed` → 上游脚本拒绝了，harness 账没动，把 `UPSTREAM_OUTPUT=` 原样报告用户，不要手改。
3. **收口 commit**：`python3 .claude/harness/scripts/harness-commit.py retro-fulfill <CODE> --epic <EPIC>`。`STATUS=ok` → 用 `SUGGEST_COMMIT_MSG` commit；`STATUS=halt` → §3 halt。
4. 全部兑现后重跑 `grep_pending_dev_retro_items.sh` 确认。

**不走兑现循环的行动项**（issue #23）：手工兑现的 dev 项、`category: harness` 的项（提 issue、升级 plugin、改本仓配置），兑现时同样用 `sprint-status.py retro-item-done <EPIC> <CODE>` 翻状态，和兑现改动放进同一个 commit。只翻了一本账的，⑥ 之前的 `action-sync --fix` 会补齐。

**缺 spec 兜底（`_NO_SPEC_` > 0）**：这类 dev 项还没有 stage ⑥.5 落地的 chore spec。主 agent **不**臆造实现，**也不 dispatch B1**——直接 halt（§3 模板），列出这 K 条，给两条路：① `bash .claude/harness/scripts/process_retro_residue.sh --epic <EPIC>` 补 chore spec 后重跑本命令；② solo-dev 评估后手工兑现，或把该项 category 改为 `harness`（在 yaml 行注释里留痕）。

### 0.B 续作切入表

一条 story 已有 `harness/<KEY>/start` tag 时，先跑 `python3 .claude/harness/scripts/harness-state.py <KEY>` 拿状态 JSON（**必须用脚本**，不要自己 grep git log 推断），再按 `next_action_code` 切入：

| code | 动作 |
|---|---|
| `build` | §1 B1（spec 已存在时 intent 指向 spec 文件，bmad-build-auto 按 spec status 自己续跑） |
| `build-verify` | §1 B1 的"验收"一步 |
| `codex` / `codex-fix` | §1 B2 对应子步 |
| `followup` | §1 B3（`followup-start` tag 已存在时不要重打，直接 dispatch，bmad-build-auto 按 spec status 续跑；spec 的 status 是 in-review 之类、还没到 done 时，说明 B3 停下后被 reopen / resume 过，intent 改成「继续 spec `<spec 路径>`，按 status 续跑」，后面照样接 §B3 的「follow-up 的 bad_spec 回环」一段） |
| `followup-verify` | §1 B3 的"验收"一步（follow-up 已经跑完，**不要**再 dispatch B3） |
| `sync` | §1 B4 |
| `tag-only` | `git tag harness/<KEY>/done`，进 ⑥ 判断 |
| `blocked` | halt：bmad-build-auto 已 HALT blocked（B1，或 `followup-start` 之后的 B3），把 spec `## Auto Run Result`（或还没有 spec 时的 `bmad-build-auto-result-*.md`）里的 Status / blocking condition 贴给用户。lane 模式先按 §3.3 判断能不能自己接着走 |
| `blocked-dirty`（`next_action` 以 `B2 codex review report` 开头） | B2.2 跑完但没 commit。未入库的 `<KEY>.codex-review.md` 的 frontmatter 有 `findings:` 行（`run_codex_review.sh` 只在成功时写这个文件，写的时候带这一行）→ 跑 `harness-commit.py 3` commit，再重新切入。工作区里同时还有 B2.3 已经开始的修复（项目代码、spec 的处理记录、deferred-work.md）也照样跑：脚本只提交报告，把 stage 4 能收的改动留在工作区，输出 `AUTO_SPLIT=left-for-stage-4 <路径>`；commit 后重新切入会走到下面 `B2 codex fix round` 那一行。有 stage 4 也收不了的路径（凭据、别的 story 的文件）时脚本照旧 halt。文件没有 `findings:` 行（旧版本中途留下的）→ 按 §B2.1 c) 的命令删掉它，重新调 `harness-state.py`（会回到 `codex`） |
| `blocked-dirty`（`next_action` 以 `B2 codex fix round` 开头） | B2.3 的修复已部分落地。跑 B2.3 的"验收"：通过 → `harness-commit.py 4` commit；没通过 → 按 §0.B 末尾的续作规则重新 dispatch B2.3（prompt 头拼 `--resume-prompt --stage 4`） |
| `blocked-dirty`（`next_action` 以 `follow-up review left a dirty worktree` 开头） | B3 的 bmad-build-auto 没收干净就退出了，改动没有经过它的 review 和 commit。**不要**用 `harness-commit.py 4` 或其他 stage 把这些改动收进去。halt，把 `git status --porcelain` 和 spec `## Auto Run Result` 贴给用户，由用户决定撤掉还是交回 bmad-build-auto 续跑 |
| `blocked-dirty`（旧流水线，`next_action` 以 `legacy stage` 开头） | 见 §1.L：按文本提示验收对应产物，再用文本里写的 stage commit |
| `done` | 不该续作。`--story <key>` 指定的 story 已 done → 回报"<KEY> 已完成"并退出；inline 模式 `all` 下的自动切入按 `run-inline` §0.A 跑下一条 |
| `not-started` | 进 §1 B0 |
| `legacy-*` | 旧流水线 story，见 §1.L |

lane 模式：`sync`、`tag-only`、`done` 都说明 B3 及之前已经完成，直接回报 `ready`，不要执行 B4，也不要打 done tag。

B2 fix 续作时 prompt 头部拼 `python3 .claude/harness/scripts/harness-state.py <KEY> --resume-prompt --stage 4` 的输出（codex finding 数 vs 已处理行数），**禁止**主 agent 凭推理自己写"前情提要"。B1 / B3 续作不需要：bmad-build-auto 以 spec 文件为状态源，自己知道从哪一步接。

---

## 0.5 路径预期产出表

`harness-commit.py` / `build-verify` 内置规则的可读版。主 agent 看它是为了理解"为什么"，不是为了按表手工 `git add`。路径前缀 `_bmad-output/implementation-artifacts/` 省略。

| 阶段 | 谁 commit | 允许的路径 |
|---|---|---|
| B1 build / B3 follow-up | bmad-build-auto | 项目代码 + `spec-$KEY.md`（或 `spec-$KEY-<n>.md`）+ `epic-<N>-context.md` + `deferred-work.md`（spec Tasks 要求翻转既有 FU 时）+ spec frontmatter `cross_story_artifacts:` / `planning_artifacts:` 声明的路径。build-verify 事后审计，越界即 halt |
| B2 `3` `story($KEY): codex adversarial review report` | 主 agent | **仅** `$KEY.codex-review.md`（catchup 时另含 `$KEY.codex-skipped.resolved.json`） |
| B2 `4` `story($KEY): apply codex review fixes` | 主 agent | 项目代码 + spec（`### Codex Review Handling (Stage 3)` 段）+ `deferred-work.md` |
| B4 `build-sync` `story($KEY): sync sprint status & deferred ledger` | 主 agent | `sprint-status.yaml`（$KEY → done；epic backlog → in-progress）+ `deferred-work.md`（spec `deferred:` 导入的 `FU-<X.Y>.B<n>`）+ `$KEY.codex-skipped.json`（如有）。无变更 → STATUS=skip，仍打 done tag |
| ⑥ `6` `epic($EPIC): retrospective` | 主 agent | `epic-${EPIC}-retro-*.md` + `sprint-status.yaml` + `deferred-work.md` |
| ⑥.5 `6-5` `chore(retro-c$EPIC): process residue → N chore specs` | 主 agent | `chore-retro-c${EPIC}-<code>-<slug>.md` × N + `sprint-status.yaml`（仅 retro_action_items 子段） |
| ⑥ `6-done` `epic($EPIC): mark done` | 主 agent | **仅** `sprint-status.yaml` |
| §0.A.0 `retro-fulfill <CODE> --epic <EPIC>` | 主 agent | 项目代码 + `sprint-status.yaml` + `deferred-work.md` + `chore-retro-c${EPIC}-<CODE>-*.md` |

**halt 类条件**（两种守门方式共用）：凭据黑名单（`.env*` / `*.pem` / `*.key` / SSH 私钥 `id_rsa` 等 / `*.pfx` / `*.jks` / `*.tfstate` / `_bmad/**` / `.claude/**` 子集；`.env.example` 这类模板文件放行；`secrets/` 目录下只拦非源码文件；改名时新旧两个路径都检查）；跨 story 隔离（`<other-key>.*` / 别的 story 的 spec）；`_bmad-output/` 下 implementation-artifacts 以外的路径（`planning_artifacts:` 白名单除外）；预期外 artifact；禁止项目代码的 stage 出现项目代码。

**spec frontmatter 白名单**：`cross_story_artifacts:`（bare basename，`.md`）和 `planning_artifacts:`（完整路径，限 `planning-artifacts/` 子树，`.md`）。写法与约束见 `.claude/harness/prompt-suffixes/bmad-build-auto-suffix.md` §4/§5。

**自动剔除（不 halt）**：仓库根的 Go 构建二进制（`AUTO_FIXED=binary-blob`）、子 agent 多产的 `<KEY>.bmad-code-review.md` 等额外 .md（`AUTO_FIXED=unexpected-md`）、`<KEY>.maven-skipped.json` 等过程 marker（`AUTO_FIXED=process-marker`）。只作用于 harness 自己 commit 的阶段。

---

## 1. 单条 story 流水线（严格顺序）

设当前 story key = `$KEY`，short id = `<epic>.<seq>`（`3-2-digest-delivery` → `3.2`），`EPIC = $(python3 .claude/harness/scripts/sprint-status.py epic-of $KEY)`。spec 路径一律用 `python3 .claude/harness/scripts/harness-state.py $KEY --story-md` 取，或用 build-verify 输出的 `SPEC_FILE=`。bmad-build-auto 不一定照 `spec-$KEY.md` 命名（中文 key 常被转写成英文 slug），harness 按 `spec-<epic>-<seq>-*.md` 的编号前缀识别，所以不要自己拼路径。

### B0：起跑

- inline 模式：用 TaskUpdate 把本 story 的任务标 `in_progress`。
- lane 模式：先跑一次 `bash .claude/harness/scripts/check_bmad_runtime.sh`，`STATUS=fail` 时回报 `blocked`，把 `REMEDIATION=` 行写进 halt 文本。`CODEX_IN_BUILD=` 的取值记下来，B2 要用。
- **先查 start tag**（必须在工作区检查之前）：`git rev-parse --verify --quiet refs/tags/harness/$KEY/start` 成功，说明这条 story 已经起跑过（续作场景没走 `--continue`；lane 模式下就是 worker 被重新启动）→ 本节余下各步都不做，也不查工作区（续作的工作区本来就可能不干净）：调 `harness-state.py $KEY`，按 §0.B 表切入。inline 模式只有 `next_action_code == "done"` 才 halt（sprint-status 有脏数据）；lane 模式按 §0.B 末尾的规则回报 `ready`。
- **工作区必须干净**（每条 story 都查，不只启动时；lane 模式查的是自己的 worktree）：`git status --porcelain` 非空 → halt。上一条 story 的 ⑥ 残留、用户在两条 story 之间的改动都会让 bmad-build-auto 在 step-01 直接 HALT。
- **打 start tag**（撤回点，必须在 dispatch 之前）：`git tag harness/$KEY/start`
  - 任何阶段想整条撤回：`git reset --hard harness/$KEY/start`。
- **Deferred-work 注入（C11）**：输出两部分，一是 `[target:Story <short id>]` 的 open 项，二是 `[epic-backlog]` 标题之后、`[target:Epic <EPIC>]` 的 open 项（build-sync 导入的延后项都是这个 target，本 story 自己 defer 的不列）。stderr 不并进来（`read_harness_config` 的 WARN 行会混进 build intent），失败时单独显示：

  ```bash
  DEFERRED_ERR="$(mktemp)"
  DEFERRED_INJECT=$(bash .claude/harness/scripts/grep_pending_deferred_for_story.sh "$KEY" 2>"$DEFERRED_ERR")
  GREP_EXIT=$?
  if [ "$GREP_EXIT" -ne 0 ]; then echo "halt: deferred-work grep 失败 exit=$GREP_EXIT"; cat "$DEFERRED_ERR"; rm -f "$DEFERRED_ERR"; exit 1; fi
  rm -f "$DEFERRED_ERR"
  printf '%s\n' "$DEFERRED_INJECT"
  ```
- **epic 第一个 story（key 匹配 `^[0-9]+-1-` 且 epic > 1）**：另跑 `bash .claude/harness/scripts/grep_prev_retro_action_items.sh $EPIC`，输出作为继承段（C7）的参考上下文一起放进 intent。

### B1：Build（独立 general-purpose subagent 内跑 bmad-build-auto）

```
Agent({
  subagent_type: "general-purpose",
  description: "Build story <KEY>",
  prompt: <Build intent> + "\n\n---\n\n" + <`harness-prompt-suffix.py build --file` 的 stdout>,
  run_in_background: false
})
```

**同步等待**：显式传 `run_in_background: false`（见 §−1 (a)）。

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
  > （lane 模式把上面这句换成：）当前分支 `<lane 分支>` 是 super-harness 为本 story 单独开的分支，从 sprint 分支 `<sprint 分支>` 开出，只承载这一条 story；分支名与 sprint 不同不算 branch mismatch。
  >
  > ## Deferred-work 待消化提示（auto-injected by C11）
  >
  > <`$DEFERRED_INJECT` 原样>
  >
  > （lane 模式，worker prompt「调度者转交的答复」一节不是「（没有）」时再加）<那一节的 `## 已确认的答复` 原样>
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

- **STATUS=ok** → `git tag harness/$KEY/built`。记下输出里的 `SPEC_FILE=`（后续所有"spec 路径"都用它）、`FOLLOWUP_RECOMMENDED=` 与 `CODEX_LAYER_SKIPPED=`。`AUTO_FIXED=auto-run-result-heading` 是信息行：bmad-build-auto 把 `## Auto Run Result` 写成了别的标题层级，脚本照样认，spec 不改。`COMMITS=` / `COMMIT=` 列出 start 以来的每个提交（子 agent 在 bmad-build-auto 运行中自己提交的也在里面，bmad-build-auto 自己允许这种提交）。有 `PRE_BASELINE_COMMIT=` 和 `WARN=` 时，那几个改了项目代码的提交早于 spec 的 `baseline_revision`，不在这一轮 review 的 diff 里：在本 story 回报里写一行，lane 模式写进 `ready` 的 summary。
  - `CODEX_LAYER_SKIPPED=true`（codex 挂在 build 里但这一轮被跳过，常见原因是超时 / 额度）→ 现在只显示 §B2.1 b) 的通知框；marker 文件推迟到 B4 第 0 步再写（B3 可能还要跑 bmad-build-auto，它要求干净工作区）。
- **STATUS=halt**，按诊断行处理（都走 §3 halt 模板，commit 已存在、主 agent 不撤）：
  - `SPEC_STATUS_NOT_DONE=blocked` + `AUTO_RUN_RESULT=` 行：bmad-build-auto 自己 HALT 了（intent gap、spec 不达标、验证失败、review 修复循环 > 5 轮不收敛等）。lane 模式先按 §3.3 判断能不能自己接着走；不能的，把 blocking condition 贴给用户。
  - `BUILD_AUTO_RESULT=` + `AUTO_RUN_RESULT=` 行：bmad-build-auto 还没建 spec 就 HALT 了（脏工作区、分支不符、intent 不清、缺前序 story 连续性决定、uv 失败等）。贴给用户，不要重新 dispatch——同样的条件会让它再 HALT 一次。
  - `SPEC_STATUS_NOT_DONE=<其它>` 或 `SPEC_MISSING=`：subagent 中途退出。按 §−1 (a) 的「配额耗尽的判定」看返回第一行：是运行时额度报错 → 按 §3.1「配额耗尽」那一行给选项；不是 → 按「子 agent 中途退出」那一行。
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

> codex-in-cc 不可用是预期内的情况（额度、未登录、未装、网络）。允许跳过，但**绝不静默**：必须写 marker + 显式通知，供事后 `/super-harness:codex-catchup` 补跑。

触发来源（只看结构化信号，不搜关键词）：B2.0 pre-flight 命中；B2.2 `run_codex_review.sh` 退出码 2（第一行 `CODEX_STATUS: quota` / `auth` / `unavailable` / `timeout`）；B2.2 的 Bash 调用被工具超时打断、没拿到 `CODEX_STATUS:` 行（按 `timeout` 处理）；B1 验收 `CODEX_LAYER_SKIPPED=true`。

lane 模式：a) 和 b) 都不做。把 reason（取值同 a) 的 `<reason>`）记下来，回报时用 `--codex-skip-reason` 带上。marker 由调度者在合流后的 B4 第 0 步写，通知也由调度者转告用户。c) 照做。

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
  "catchup_command": "/super-harness:codex-catchup --story ${KEY}"
}
EOF
```

`<reason>`：pre-flight 填 `not_installed`；B2.2 照抄脚本输出的 `CODEX_REASON=`（`quota_exhausted` / `auth_failed` / `not_installed` / `timeout`），Bash 工具超时填 `timeout`；B1 验收填 `in_build_layer_skipped`。字段名 `stage2_base_sha` 沿用旧 schema，值填本节的 `BASE`。

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
│ 待 codex 恢复后跑：/super-harness:codex-catchup --story <KEY>       │
│ 或 /super-harness:codex-catchup 一次性补跑所有 skip 的 story。      │
└──────────────────────────────────────────────────────────────────┘
```

##### c) 跳过 B2 余下部分

不跑 `harness-commit.py 3` / `4`。a) 的 marker 文件**推迟到 B4 第 0 步写**（同一个 reason），由 `build-sync` 一起入库——B3 若还要跑，bmad-build-auto 需要干净工作区。

**清掉半成品报告**：`run_codex_review.sh` 只在成功时写 `<KEY>.codex-review.md`，正常走到这里时工作区里没有它。如果有（旧版本留下的，或者 Bash 被打断在写文件的那一刻），它没有入库，留着会让 B3 的 bmad-build-auto 因为脏工作区 HALT，或者让 B4 `build-sync` 报 `UNEXPECTED_ARTIFACT`。这是本手册里唯一允许主 agent 删除的文件，只删这一个、只在它未入库时删：

```bash
F="_bmad-output/implementation-artifacts/${KEY}.codex-review.md"
if [ -e "$F" ] && ! git ls-files --error-unmatch -- "$F" >/dev/null 2>&1; then rm -f -- "$F"; fi
git status --porcelain
```

`git status --porcelain` 仍不为空 → halt（还有别的改动，不归本步处理）。lane 模式同样执行这一步。

#### B2.2 codex review（主 agent 直接跑脚本，不起子 agent）

```bash
bash .claude/harness/scripts/run_codex_review.sh --key "$KEY" --base "$BASE" --spec "<spec 路径>"
```

**Bash 调用必须显式给 `timeout: 600000`**（10 分钟，工具上限）。默认的 2 分钟不够：codex 插件自己的 `adversarial-review` 命令说明里，除了一两个文件的小改动，都建议放后台跑。脚本内部再用 `timeout` 把 codex 限在 570 秒（`CODEX_REVIEW_TIMEOUT` 可调），超时会自己报 `timeout`，不会被工具硬杀。

脚本做的事：找 `codex-companion.mjs`（先 `$CLAUDE_PLUGIN_ROOT`，再 `~/.claude/plugins/cache/openai-codex/codex/*/` 里版本最高的），跑 `adversarial-review --wait --base <BASE>`，stdout 和 stderr 分别重定向到 `mktemp -d` 的临时目录（不在仓库里）。判定只看 codex 的退出码和它自己的输出格式：退出码 0、有 `Verdict: <词>` 行、并且有 `- [critical|high|medium|low] ...` finding 行或 `No material findings.` 行，才算成功。成功时用 shell 把 frontmatter（`story` / `base` / `head` / `reviewer: codex-adversarial` / `findings: <N>`）和 codex 的 stdout 原样拼成 `_bmad-output/implementation-artifacts/<KEY>.codex-review.md`，不经过任何人转写。失败时不写这个文件。

输出第一行固定是 `CODEX_STATUS: <状态>`，主 agent 只按它和退出码分支：

| 第一行 | 退出码 | 动作 |
|---|---|---|
| `CODEX_STATUS: ok` | 0 | 记下 `CODEX_FINDINGS=`（B2.3 要用），commit 报告 |
| `CODEX_STATUS: quota` / `auth` / `unavailable` / `timeout` | 2 | §B2.1，reason 取 `CODEX_REASON=` |
| `CODEX_STATUS: error` | 1 | halt，把脚本完整输出贴给用户（`RAW_DIR=` 里有 codex 原始输出） |
| 没有 `CODEX_STATUS:` 行（Bash 工具超时打断） | — | §B2.1，reason `timeout` |

quota / auth 的判定在脚本里，只匹配 codex 的报错行（stderr 中不是 `[codex]` 进度的行、`[codex] Codex error:` 行、`- Parse error:` 行），codex review 正文里出现 `rate limit` / `unauthorized` 不影响判定。

**验收**：`CODEX_STATUS: ok` 本身就是验收（脚本已核对 `Verdict:` 行和 finding 格式）。另外确认 `REPORT_FILE=` 指向的文件存在、frontmatter 有 `base: <BASE>` 行。

**commit**：`python3 .claude/harness/scripts/harness-commit.py 3 $KEY`。

#### B2.3 codex 修复（fresh general-purpose subagent，有意不走 BMad 工作流）

本步是 B1 实现的延续：codex 的每条 finding 都是 B1 没做好或漏掉的部分。没有契合"按外部 review 反馈修已完成代码"的 BMad 工作流，所以直接 freelance + 断点续作约定。统一 spawn fresh agent（跨会话 agentId 无效），让它从产物文件重建上下文。

**先看 finding 数**：B2.2 输出的 `CODEX_FINDINGS=`；续作时用 `harness-state.py $KEY` 的 `codex_findings`（按 codex 的 `- [<severity>]` finding 行计数）和 `codex_no_findings`。

- **0 条**（codex 报告是 `No material findings.`，`codex_no_findings: true`）→ 不 dispatch 修复 agent。主 agent 在 spec 末尾写一条处理记录（已经有 `- [none]` 行就不重复写），然后照常验收、commit：

  ```bash
  SPEC="<spec 路径>"
  grep -q '^- \[none\]' "$SPEC" || printf '\n### Codex Review Handling (Stage 3)\n\n- [none] codex 报告 No material findings.，无需处理\n' >> "$SPEC"
  ```

  这次 stage 4 commit 只含这一行记录，没有修改代码，**不触发 B3**（`harness-state.py` 也按这条规则路由：`codex_no_findings` 为 true 时 stage 4 commit 不算 follow-up 的触发条件）。
- **≥ 1 条** → dispatch 下面的修复 agent。dispatch 之前确认 `harness-state.py $KEY` 的 `next_action_code` 是 `codex-fix`，也就是报告已经由 `harness-commit.py 3` 提交（issue #19：先修后交报告，stage 3 会拒收）。

```
Agent({
  subagent_type: "general-purpose",
  description: "Dev fix codex findings <KEY>",
  prompt: <以下 prompt> + "\n\n---\n\n" + <`harness-prompt-suffix.py 4 --file` 的 stdout>,
  run_in_background: false
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
> 立 deferred FU 之前看一眼 spec frontmatter 的 `deferred:` 列表。这个 finding 和其中第 N 条（从 1 数）说的是同一个问题时，在 FU 的「关联」里写固定标记 `covers: frontmatter deferred #N`（同时覆盖几条就写 `#2 #3`）。build-sync 导入那一条时会直接标成 superseded 并引用你的 FU，账本里不会再多出一条 pending。只认这个写法，「第 3 条」「第四项」之类的说法不算。
>
> 每处理完一条，**立即**在 spec 文件末尾的 `### Codex Review Handling (Stage 3)` 段（没有就新建，放在 `<intent-contract>` 之外）追加一行：`- [F-1 high] <短描述> — fixed: 改了 <files>` / `- [F-2 medium] <...> — deferred: FU-x.y.z`。这是断点续作的 progress 来源。
>
> 结束条件：所有 finding 各有一条处理记录。然后停止，不要做任何 git 操作。修源码直接用 Edit。

**验收**：跑 `harness-state.py $KEY`，看 JSON 里的计数：
- `codex_findings` ≥ 1：`codex_handling_rows`（spec `### Codex Review Handling (Stage 3)` 段里 `- [F-N ...]` 行覆盖的 finding 数，同一编号只算一次）= `codex_findings`，并且 `codex_handling_malformed` 为 0；
- `codex_findings` = 0：`codex_handling_none` 为 true（段里有那条 `- [none]` 行）；
- `codex_findings` 为 null（报告不存在）→ halt。

`codex_handling_malformed` 大于 0：修复 agent 写了别的格式（加粗标题、反引号包着 `fixed`、表格），这些行不算数，续作时也认不出来。用 `SendMessage` 让修复 agent 把这几行改写成 `- [F-<n> <严重度>] <短描述> — fixed|wontfix|deferred: <说明>`，只改格式不改内容；它已经结束的，你自己用 Edit 改这几行（只动这几行的格式）。`harness-state.py $KEY --resume-prompt --stage 4` 会列出行号。

**commit**：`python3 .claude/harness/scripts/harness-commit.py 4 $KEY`。脚本提交前再核对一次：有格式不对的行（`HANDLING_ROW_MALFORMED=`）或处理记录少于 finding 数（`HANDLING_ROWS=<n>/<N>`）时 `STATUS=halt`，按上一段改好后重跑，不算 §3 的 halt。finding ≥ 1 时，B2.3 commit 之后 **B3 必跑**（修复代码还没被 review 过）；0 finding 的那次 commit 不是修复，不触发 B3。

### B3（条件触发）：follow-up review（bmad-build-auto 对 done spec 再跑一轮 review）

**触发条件**（任一）：B2.3 commit 了修复（codex finding ≥ 1；0 finding 时写 `- [none]` 行的那次 commit 不算）；B1 验收 `FOLLOWUP_RECOMMENDED=true`。都不满足 → 跳过。**每条 story 最多一轮**。

dispatch 之前先 `git tag harness/$KEY/followup-start`（续作时据此区分"还没跑"和"跑完待验收"，避免重复跑第二轮）。

```
Agent({
  subagent_type: "general-purpose",
  description: "Follow-up review <KEY>",
  prompt: "## Build intent\n\n对已完成的 spec `<spec 路径>`（story `<KEY>`）做一轮 follow-up review：直接把这个 spec 文件路径交给 bmad-build-auto（status done 的 spec 会进入新一轮 review pass，审查 baseline 以来的全部改动，包括 codex 修复）。\n\n" + <下面「follow-up 的 bad_spec 回环」一段原文> + "\n\n---\n\n" + <`harness-prompt-suffix.py build --file` 的 stdout>,
  run_in_background: false
})
```

接在 intent 后面的这一段（issue #29）。B3 开始时代码已经提交，bmad-build-auto 的 bad_spec 分支却要求先回退代码再按 KEEP 重做，而调度契约不许 reset、checkout。不写明的话，worker 要自己在两条规则之间权衡：

> **follow-up 的 bad_spec 回环**：这一轮开始时，本 story 的实现已经提交。review 判出 bad_spec 时，step-04 的 bad_spec 分支按下面的做法走，其余照原文：
> - 不回退代码。已提交的改动，加上这一轮回环里还没提交的改动，就是 KEEP 的全部。Spec Change Log 照常写触发的 finding、改了什么、避免的坏状态，KEEP 一项写「保留 `<当前 HEAD 短 hash>` 的树和本轮未提交的改动，只按改过的 Tasks 增量修改」。
> - 回到 step-03 时不重新记 `baseline_revision`，frontmatter 里的值保持不变。下一轮 review 照旧看 baseline 以来的全部改动。实现只做改过或新增的 Tasks。
> - `review_loop_iteration` 照 step-04 第 5 条：每次回环前加 1，超过 5 就 HALT blocked。它在这一轮开始时由 step-01 清零（bmad-build-auto 对 done spec 的规定，照做），所以数的是 follow-up 这一轮的回环次数。回环了却没加 1，这个上限就不起作用。

0.B 表里 `followup` 一行改写成「继续 spec，按 status 续跑」的 intent，同样接上这一段。

**验收**：再跑 `python3 .claude/harness/scripts/harness-commit.py build-verify $KEY`。STATUS=ok → `git tag harness/$KEY/followup`；halt 处理同 B1。

这一轮之后 `FOLLOWUP_RECOMMENDED` 仍为 `true` → 不再循环，在本 story 回报里写一行"bmad-build-auto 仍建议再 review：<spec `## Auto Run Result` 里点名的风险>"，交给用户决定。lane 模式把这句风险用 `--followup-note` 带进回报。

**lane 模式到此结束**：最后一次 `build-verify` 是 `STATUS=ok`、`git status --porcelain` 为空时回报 `ready`。B4 及之后的步骤由调度者在合流后执行。

### B4：build-sync（harness 自己的收口 commit）

inline 模式在 B3 之后直接执行。调度模式在 lane 合流进 sprint 分支之后执行，每一步做之前先问 `superh.py postmerge <KEY>` 还差什么（见 `run` §4）；第 0 步的 reason 取 `superh.py integrate` 输出的 `CODEX_SKIP_REASON=`，`BASE` 取它的 `BASELINE_REVISION=`。

**第 0 步：补写 codex-skipped marker**。本 story 在 B1 验收看到 `CODEX_LAYER_SKIPPED=true`，或 B2 走了 §B2.1 skip → 现在按 §B2.1 a) 写 `<KEY>.codex-skipped.json`（reason 分别为 `in_build_layer_skipped` / pre-flight 或 in-flight 的 reason）。续作场景记不清时：`harness-state.py $KEY` 的 `codex_layer_skipped: true` 即前者；后者会被 harness-state 路由回 `codex` 重新探测，不会走到这里。

```bash
python3 .claude/harness/scripts/harness-commit.py build-sync $KEY
```

脚本内部：把 spec frontmatter `deferred:` 里尚未导入的条目追加进 `deferred-work.md`（schema v1，`FU-<short id>.B<n>`，`[source:build-auto-of-<short id>]`）。同一 story 已有 FU（通常是 B2.3 立的 codex FU）在正文里写了 `covers: frontmatter deferred #<n>` 的，第 n 条照常按位置编号导入，但直接写成 `[status:superseded]`，「关联」引用那条 FU，「历史」记一行原因（issue #28）；`sprint-status.yaml` 里 `$KEY → done`，所属 epic `backlog → in-progress`；连同 `<KEY>.codex-skipped.json`（如有）一起 stage。

- STATUS=ok → 用 `SUGGEST_COMMIT_MSG` commit，然后 `git tag harness/$KEY/done`（`SUGGEST_TAG`）。`SPRINT_STATUS_AUTO_SYNC=import-deferred key=FU-...` 行是信息，被覆盖的条目 value 是 `superseded(covered-by:FU-...)`。
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

`git log --oneline harness/$KEY/start..harness/$KEY/done` 即本 story 完整提交序列。inline 模式：用 TaskUpdate 把本 story 的任务标 `completed`。

**待用户确认的取舍进收件箱**（issue #24）：bmad-build-auto 按代答政策自己定下、写进 spec `### 待用户确认` 段的取舍（`bmad-build-auto-suffix.md` §9），也认旧写法（标题或加粗行里带「待用户确认」「待确认」的段落）。条目里的 `备选：A / B` 导入成收件箱的备选项，`board` 和 `decisions` 都会显示。调度模式不用做：`superh.py launch` 和 `integrate` 会自动导入，输出 `SPEC_DECISIONS_IMPORTED=`。inline 模式在这里跑一次 `python3 .claude/harness/scripts/superh.py spec-decisions $KEY`，`IMPORTED=` 的编号写进本 story 的回报，提醒用户有空时 `superh.py decisions` 看、`confirm` 或 `override`。`SPEC_ITEMS=` 和 `INBOX_ITEMS=` 对不上时输出 `WARN=`，原样转告。

### 测试由谁负责

B4 之后直接进阶段 ⑥ 的判断，流水线里没有单独的测试阶段（0.3.0 删除了原来的 ⑤.5 和 `/super-harness:run-test`）。

- 单元测试和集成测试由 B1 的 bmad-build-auto 负责：spec 的 `## Verification` 段列出验证命令并实跑，step-03 的 Matrix Test Audit 要求 I/O 矩阵每一行都有跑通的测试，step-04 的 verification-gap 审查层专门找没有测试兜住的行为变更。
- `/super-harness:run` 并行模式多一道合流验证：`parallel.yaml` 配了 `verify_command` 时，`superh.py integrate` 在 lane 被 rebase 到 sprint 分支最新提交之后、ff 合并之前跑它，失败就把这一路挂起，sprint 分支不动（`run` §3）。调度 agent 用后台模式执行 integrate，验证跑多久都不会被 Bash 工具的超时杀掉；超过 `verify_timeout_sec` 时脚本结束整个进程组，算作验证失败。inline 模式一次只跑一条 story，B1 就在同一棵树上验过，不需要这一步。
- e2e 和验收测试不在 harness 范围内，交给下游测试团队。

### 阶段 ⑥（条件触发）：Epic Retrospective

```bash
EPIC=$(python3 .claude/harness/scripts/sprint-status.py epic-of $KEY)
if python3 .claude/harness/scripts/sprint-status.py epic-all-done $EPIC; then
    RETRO_STATUS=$(python3 .claude/harness/scripts/sprint-status.py epic-retro-status $EPIC || echo missing)
    # 只有 RETRO_STATUS != done 才跑
fi
```

（`epic-all-done` 把 `done`、`wont-do`、`cancelled` 都算终态。`harness-project-config.yaml` 的 `parked_statuses` 里列的挂起状态也不挡 retro，stderr 会多一行 `parked=`；但 epic 里一条 done 的都没有时返回 1，没有可回顾的内容。）

当前 story 不是该 epic 最后一条 → 跳过本阶段。inline 模式在每条 story 的 B4 之后做这个判断。调度模式不在单条 story 收口时判断，等 `superh.py tick` 给出 `retro` 再对该 epic 执行本阶段。

**两本账先对齐**（issue #23）：dispatch retro 之前跑一次 `python3 .claude/harness/scripts/sprint-status.py action-sync --fix`。它把 `retro_action_items` 已 done、原生 `action_items` 还 open 的条目翻成 done（`FIXED=` 行），改动留在工作区，由 commit row 6 一起提交。这样 retro 的 follow-through 段按原生账统计就是对的，不用逐条手数。退出码 1（`FIX_FAILED=`）不阻断 retro，把输出转告用户。

**retro 用的 `KEY`**（inline 模式的 retro-only 启动、调度模式都按这条取）：Read `sprint-status.yaml` 的 `development_status:`，在 `${EPIC}-` 开头的 key 里按 yaml 顺序取最后一条 status=done 的，再用 `sprint-status.py epic-of $KEY` 验证等于 `$EPIC`。**禁止**传空串或编造 key（`harness-commit.py` 的 key 位参必填）。

```
Agent({
  subagent_type: "general-purpose",
  description: "Retrospective epic <EPIC>",
  prompt: <以下 prompt> + "\n\n---\n\n" + <`harness-prompt-suffix.py 6 --file` 的 stdout>,
  run_in_background: false
})
```

prompt 核心：

> 用 Skill 工具调用 `bmad-retrospective`，参数 `-H <EPIC>`（BMad 6.12 的无人值守接口：不提问、不开 team discussion、verdict 只看证据，所有替用户做的假设记进文档 Assumptions 段）。
>
> **格式契约（强制，先做）**：先 Read `.claude/harness/prompt-suffixes/bmad-retrospective-suffix.md` 并全程遵守。要点：
> 1. Phase 1 Gather 之后、Phase 2 Analyze 之前先跑 `bash .claude/harness/scripts/run_retro_self_audit.sh <EPIC-1>`。首行是 `RETRO_SELF_AUDIT: no-config`（项目没配 `.claude/harness/retro-self-audit.tsv`）时不贴它的输出，§2 表格手工填；脚本失败也不阻断，同样手工填。
> 2. Action items 段**必须**按其 Form 1 书写（每条一个 H3：`### <code> — <标题>`），每条声明 `**Category**: dev` 或 `**Category**: harness`，owner 写 `solo-dev`。
> 3. Phase 5 的 `--add-action` JSON 每条显式给 `id: "epic-<EPIC>-retro-<CODE>"`（与 H3 code 一致），不要传 `--set-action-status`。
> 4. retro 文档 frontmatter 必须有 `verdict`。
> 5. 按 suffix 的「deferred-work 分诊」一节，跑 `bash .claude/harness/scripts/grep_pending_deferred_for_story.sh --epic <EPIC>`，把列出的 `[target:Epic M]` 条目逐条改成具体去处（改 target、resolved、skipped 或 needs-review），在 retro 文档里写一段分诊小结。
>
> 不合规形态（编号列表 / 表格）会让 stage 6 commit 的 parser 全 0 命中 → fail-loud halt。
>
> 完成后停止，不要做任何 git 操作。

等待返回。
- **瞬态 API 错误重试（issue #9 finding 4）**：retro subagent 死于瞬态 infra 错误（如 `API Error: Overloaded`，**不是**配额信号）且 `git status --porcelain` 干净 → 重新 dispatch 一次，不 halt；仍失败 → §3 halt。worktree 不干净 → 不重试，§3 halt。

**验收**：至少一份新的 `epic-${EPIC}-retro-*.md`，非空。

**commit row 6**：`python3 .claude/harness/scripts/harness-commit.py 6 $KEY --epic $EPIC`。脚本内部把 `epic-${EPIC}-retrospective` / `epic-${EPIC}` 翻 done（retro 的 sprint_status.py 已翻过则 no-op），从 retro md 解析 Form 1 H3 条目 seed `retro_action_items.epic-${EPIC}-retro`。STATUS=ok 输出含 `RETRO_VERDICT=<accepted|accepted-with-open-items|rejected|missing>`，**记下它**。

**commit row 6-done**：`python3 .claude/harness/scripts/harness-commit.py 6-done $KEY --epic $EPIC`（通常 STATUS=skip）。

### 阶段 ⑥.5（条件触发）：Retro Residue Processing（Chore C10）

阶段 ⑥ commit 完成后触发，把 retro 里 pending / partial / in-progress 的 action items 转成可执行的 `chore-retro-c${EPIC}-<code>-<slug>.md` spec。主 agent 不经手 prompt 和 spec 的正文：脚本把 prompt 写进临时文件，子 agent 自己读、自己写 spec，只回一份短清单。

1. `bash .claude/harness/scripts/process_retro_residue.sh --epic $EPIC`：
   - 退出码 0 → stdout 只有几行：`PROMPT_FILE=<临时文件绝对路径>`、`PENDING_COUNT=<n>`、`PENDING_CODES=<code 列表>`、`ARTIFACT_DIR=<spec 目录>`。记下这四个值。
   - 退出码 2 → "no residue to process"，跳过本阶段。
   - 退出码 1 → halt。
2. dispatch 一个 fresh general-purpose agent（`description: "Process retro residue epic-<EPIC>"`，`run_in_background: false`），prompt 只写一句话加后缀，不要把 prompt 文件内容贴进去："Read `<PROMPT_FILE>`，按其中的指令执行：每条待处理项用 Write 直接写到 `<ARTIFACT_DIR>/`，最后只回 MANIFEST 块和 ≤ 200 字总结。" + `harness-prompt-suffix.py chore --file` 的 stdout。
3. agent 返回 `=== MANIFEST ===` / 每行 `<code>: <dev|harness> <filename>` / `=== END MANIFEST ===` + ≤ 200 字总结。某行是 `<code>: COLLISION <filename>` → spec 命名冲突，halt。
4. 删掉临时文件：`rm -f "<PROMPT_FILE>"`。
5. 解析 MANIFEST：缺失 / 行数与 `PENDING_COUNT` 不一致 / category 取值非法的项一律默认 `harness`，输出一行 `MANIFEST_FALLBACK=<reason>`，**不** halt。filename 以磁盘为准：`ls <ARTIFACT_DIR>/chore-retro-c${EPIC}-<code>-*.md`。
6. 用 Edit 在 `retro_action_items.epic-${EPIC}-retro.<code>` 条目下、与 `status:` 同一缩进追加 `chore_spec: '<filename>'` 与 `category: <dev|harness>`（已有 `category:` 就改值，不要重复）。条目还是旧的标量写法（`<code>: pending`）时先跑 `sprint-status.py migrate-retro-items` 再改。**不**加 `chore-retro-cN-residue:` 段，**不**动 `development_status:`。
7. **sanity check**：
   - `grep -E "chore-retro-c[0-9]+-residue:" .../sprint-status.yaml` 必须为空
   - `git diff sprint-status.yaml` 只触及 retro_action_items 子段
   - `ls .../chore-retro-c${EPIC}-*.md | wc -l` ≥ 待处理数
   - 每个新 spec 都含 `frozen-after-approval` / `Tasks & Acceptance` / `Code Map`
   - 新 spec 不含"自动生成 / fresh agent / auto-generated"字样
   - `git status --porcelain` 里除了新 spec 和 `sprint-status.yaml` 没有别的路径（agent 只许写 spec）
   - `bash .claude/harness/scripts/check_retro_action_items.sh` 仅看 stderr 有无新增 WARN（信息性）
8. **commit row 6-5**：`python3 .claude/harness/scripts/harness-commit.py 6-5 $KEY --epic $EPIC`。

halt 触发：没有 MANIFEST 块；MANIFEST 有 `COLLISION` 行；sanity check 前 6 项任一失败；6-5 STATUS=halt → §3。halt 时 agent 已经写下的 spec 留在工作区，主 agent 不删，交用户处理。⑥.5 halt 不影响 epic retro 已 done 的事实。

### 阶段 ⑥ 之后：verdict 门

verdict 取自 commit row 6 或 6-done 输出的 `RETRO_VERDICT=`（两处都会打印；续作只跑到 6-done 时也能拿到），同时看 `EPIC_WONT_DO=` 和 `EPIC_PARKED=`。

`RETRO_VERDICT=rejected` → 本 epic 被 retro 判为不通过（上游语义：有非 `done` 的 story，或 acceptance criteria 不满足）。⑥.5 / 6-done 照常做完，然后：
- `EPIC_WONT_DO=none`、`EPIC_PARKED=none` 且 `LOOP_SCOPE = all`（inline 模式）→ **halt**（§3 模板），不进入下一个 epic；把 retro 文档的 Acceptance verdict 段和 Open questions 段要点贴给用户。调度模式同样 halt，但要先停止派发新 lane，等在跑的 lane 结束、合流、收口之后再 halt（`run` §5）。
- `EPIC_WONT_DO=<keys>`（状态为 `wont-do` 或 `cancelled` 的 story）：上游把这两种也算未完成，会强制判 `rejected`，这类 epic 每次都会是 rejected。不 halt，在回报里醒目写一行"verdict=rejected，可能只是 wont-do / cancelled 的 <keys> 触发；请看 retro 文档 Acceptance verdict 段确认是否还有其它原因"，然后继续。
- `EPIC_PARKED=<keys>`（状态在 `parked_statuses` 里的挂起 story）：上游同样把它们算未完成，强制判 `rejected`。不 halt，回报里单独写一行"verdict=rejected，可能只是挂起的 <keys> 触发；它们还会回来开发，epic 保持 in-progress"，和 wont-do 分开写，然后继续。commit row 6 在有挂起 story 时只把 `epic-${EPIC}-retrospective` 标 done，不把 `epic-${EPIC}` 标 done。挂起的 story 以后开发完，想再做一次 retro 就把 `epic-${EPIC}-retrospective` 改回 `optional`，下次会自动触发并在那时把 epic 标 done。
- inline 模式的其它 scope → 在最终回报里醒目标注。

`accepted-with-open-items` → 回报里列出 open items 所在段落，不阻流。`missing`（旧格式 retro）→ 不判断。

### 1.L 旧流水线 story（harness-zh ≤ 0.1.39 启动、未完成）

`harness-state.py` 的 `pipeline = legacy`（有 `story(<KEY>): create story spec` commit、没有 `spec-<KEY>.md`）。BMad 6.11+ 里 `bmad-create-story` / `bmad-dev-story` 不再安装，所以：

| code | 处理 |
|---|---|
| `legacy-stage2` | 无法续作。halt，告诉用户：`git reset --hard harness/<KEY>/start` 后删掉 `<KEY>.md`，再 `/super-harness:run-inline --story <KEY>` 走新流水线 |
| `legacy-stage3` / `legacy-stage4` | 按 B2.2 / B2.3 执行，`BASE` 用 `harness-state.py` 的 `stage2_base_sha`，spec 路径是 `<KEY>.md` |
| `legacy-stage5` | 调 `bmad-code-review`：review target = commit range `<stage2_base_sha>..HEAD`（diff 用 `git diff <range> -- . ':!.claude'`），spec_file = `<KEY>.md`，所有 HALT / CHECKPOINT 按 answer-policy 自决、patch 选 "Apply every patch"；另写 `<KEY>.review-findings.json`（`unresolved` / `resolved` / `final_story_status`）。验收后 `harness-commit.py 5 $KEY` + `git tag harness/<KEY>/done`。prompt 后缀用 `harness-prompt-suffix.py 5 --file` |

旧流水线的完整说明在 `.claude/harness/changelog.md` v0.1.39 及更早条目。

---

## 2. 收尾：codex-skipped 提醒

inline 模式在主循环结束时、调度模式在整个 sprint 跑完时执行一次：

```bash
SKIPPED_COUNT=$(ls _bmad-output/implementation-artifacts/*.codex-skipped.json 2>/dev/null | wc -l | tr -d ' ')
```

SKIPPED_COUNT 必须用 Bash 实跑，> 0 时必须完整打印通知框：

```
┌──────────────────────────────────────────────────────────────────┐
│ ⚠️  Codex review pending — 仍有 N 条 story 没做 codex review     │
│                                                                  │
│ Marker 文件：                                                    │
│   <每个 *.codex-skipped.json basename + reason>                  │
│                                                                  │
│ 待 codex 恢复后跑：/super-harness:codex-catchup                  │
└──────────────────────────────────────────────────────────────────┘
```

最后附一行：「这一轮如果有 plugin 行为不顺手 / 文档误导，跑 /super-harness:report-issue（自动收集上下文，一键提到 Niutie/my-cc-plugin）」。

---

## 3. 死循环 / 失控防护（**必须严格遵守**）

任何一项触发都立即 halt，不要尝试自愈（lane 模式的两种例外见 §3.3）。子 agent 提问 / 请求确认不在此列（按 §−1.b 处理）。

halt 的落地方式按模式不同：inline 模式打印下面的 halt 模板；lane 模式按 §−1 (c′) 回报 `blocked` / `quota`；调度模式按 `run` §8，先贴看板，再贴 halt 模板。

| 触发条件 | 处理 |
|---|---|
| 启动时（`run-inline` §0.A 第 0 步、lane 模式 B0、`run` §0）`check_bmad_runtime.sh` STATUS=fail | halt，贴 `REMEDIATION=` 行 |
| 配额耗尽（§−1 (a) 的两条判定同时成立：结构化校验失败 + 子 agent 返回第一行是运行时额度报错） | halt，按 §3.1「配额耗尽」那一行给选项。codex 的额度 / 登录问题不在此列：`run_codex_review.sh` 退出码 2 → §B2.1 skip+marker |
| `build-verify` STATUS=halt（`SPEC_STATUS_NOT_DONE=` / `SPEC_MISSING=` / `BUILD_AUTO_RESULT=` / `AUTO_RUN_RESULT_MISSING=` / `DIRTY_WORKTREE=` / `BLACKLIST=` / `CROSS_STORY=` / `OUT_OF_SCOPE_BMAD=` / `NO_CODE_CHANGE=`） | halt，贴脚本完整 stdout。commit 已存在，**不撤** |
| B0 工作区不干净 | halt |
| `harness-commit.py` 退出码 1 | halt，贴脚本完整 stdout（`BLACKLIST=` / `CROSS_STORY=` / `UNEXPECTED_ARTIFACT=` / `FORBIDDEN=` / `UNSTAGED=` 等） |
| 预期产物缺失或为空（各阶段"验收"项） | halt。⑥ 瞬态 infra 错误 + 干净工作区允许重试一次（见阶段 ⑥） |
| `retro_gate: block` 且 §0.A.0 仍有 `_NO_SPEC_` dev retro 项 | halt，不 dispatch B1 |
| `run-inline` §0.A 工作区不干净且没有 in-flight story | halt |
| 子 agent 返回缺 `git status --porcelain` 自报段 | 不 halt，主 agent 自己跑一次交叉核对；发现子 agent 改了它没声称改过的文件 → halt |
| `RETRO_VERDICT=rejected` 且 `EPIC_WONT_DO=none`、`EPIC_PARKED=none`，并且是 inline 模式 `LOOP_SCOPE=all` 或调度模式 | halt，不进下一个 epic |
| 单条 story 主步骤（B1 / B2.3 / B3）累计 dispatch > 4 个子 agent（3 个 + 至多 1 次中断重启；B2.2 是脚本，不计；lane 模式 §3.3 reopen 之后的重新 dispatch 不计）。⑥ / ⑥.5 / §0.A.0 不计入，各有上限：⑥ / ⑥.5 每 epic 各 1 个（另允许至多 1 次额外重启，配额重启与 ⑥ 瞬态重试合计）；§0.A.0 每个 dev 项 1 个 | halt |
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

halt 说明只讲这一次：停在哪、为什么停、现在什么状态、接下来怎么办。选项从 §3.1 表里按原因挑，最多 3 条，按推荐顺序排，每条都要写到能照着做的程度（改哪个文件、跑哪条命令、做完怎么续跑）。和这次原因无关的通用操作不要附上：整条撤回、`git restore` 全部、看 git log、report-issue、配额重启，只有 §3.1 那一行列了才出现。

```
🛑 已 halt：$KEY 停在 <阶段，例如「B1 build 验收」>。
原因：<一句话，说清楚是谁停的、为什么停。诊断行放到最后的完整输出里，这里不要只贴一个 SPEC_STATUS_NOT_DONE=blocked>

现在的状态：
  - 本 story 已有 <N> 个 commit，工作区<干净 / 有 M 个未提交文件>
  - <§3.1 表「状态要写的事实」那一列要求的内容>

建议（主 agent 不会自动执行，你来选）：
  A. <首选>
  B. <备选>
  C. <可选>

完整输出（逐字）：
<子 agent 返回 / 脚本 stdout>
```

写法：

- N 和 M 用命令查：`git rev-list --count harness/$KEY/start..HEAD`、`git status --porcelain`。没有 start tag 的 halt（启动检查、工作区检查）省掉 commit 数。
- 「续跑」按模式写成具体命令：inline 模式是 `/super-harness:run-inline --continue`；调度模式是 `python3 .claude/harness/scripts/superh.py retry $KEY`，再执行 `/super-harness:run`。要先把用户的答复写进 spec 的（intent gap、改 status 的那几行），调度模式写成 `python3 .claude/harness/scripts/superh.py resume $KEY --note "<答复>"`，它会写进 spec、改 status、commit、挪 `followup-start`，再重新排队。
- 需要用户改文件时，写出文件路径和要改的位置（例如 spec 路径 + `status:` 改成什么）。
- 不替用户选，不自动执行。git 撤回类命令（reset、restore、删 tag）只给出命令，用户明确让你执行才执行。

### 3.1 按原因给选项

| 原因 | 状态要写的事实 | 建议 |
|---|---|---|
| bmad-build-auto 停在 `intent gap`、`unclear intent`、`matrix ambiguity`（`SPEC_STATUS_NOT_DONE=blocked`，或 §0.B 的 `blocked`） | 从 spec `## Auto Run Result` 抄出它提的每个问题，编号列出，一个问题一行，保留它给的候选读法。step-04 review 阶段停的，再写出 `## Review Triage Log` 最后一条里保存的 patch 路径（代码已经被它还原） | A. 直接在对话里回答这些问题，主 agent 按 §3.2 写回 spec 并续跑。<br>B. 自己改 spec：把答案写进 `<intent-contract>` 块，frontmatter `status` 改成 `draft`（B3 停的改成 `in-review`），commit，然后续跑。调度模式用 `superh.py resume $KEY --note "<答复>"` 代替这几步。<br>C. 答案要改需求本身（epics 里的 story 定义写错了或漏了）：先改 planning artifacts，再按 B 做。想先跳过这条：在 sprint-status 里把它改成 `parked_statuses` 里的状态（列表为空就先在 harness-project-config.yaml 里加一个），然后 `/super-harness:run-inline` 跑下一条 |
| bmad-build-auto 停在验证失败：`implementation verification failed`、`patch verification failed`、`matrix test audit failed` | 失败的命令和报错前 10 行左右（从 Auto Run Result 抄） | A. 是环境问题（服务没起、依赖没装）：给出要补的环境，补好后 spec `status` 改成 `in-progress`，commit，续跑。<br>B. 是代码问题：用户修好并 commit，spec `status` 改成 `in-review`，续跑会从 review 接着做 |
| bmad-build-auto 停在 spec 问题：`spec failed ready-for-development standard`、`handoff conflicts with spec`、`review repair loop exceeded 5 iterations` | 不达标的条目或互相冲突的两段原文；循环不收敛的，列出 triage log 里反复出现的那几条 finding | A. 按列出的问题改 spec（多半是 AC 互相矛盾或写得太宽），`status` 改成 `draft`，commit，续跑。<br>B. 这条 story 拆小更合适：用 BMad 改 epics 后，`git reset --hard harness/$KEY/start` 撤回本 story 重来 |
| bmad-build-auto 在建 spec 之前就停了（`BUILD_AUTO_RESULT=`，或 §0.B `blocked` 且没有 spec） | result 文件里的 Status 和 Blocking condition | 按 condition 给一条对应的处理：工作区不干净 → 列出文件，请用户 commit 或清理；分支不对 → 写出当前分支；`unclear intent` → 指出 epics 里这条 story 缺了什么；`missing previous-story continuity decision` → 写出停在 in-review 的那条前序 story。处理完删掉这个 result 文件（已入库就 `git rm` 后 commit），续跑 |
| 子 agent 中途退出，不是配额（`SPEC_STATUS_NOT_DONE=` 非 blocked，或 `SPEC_MISSING=`） | spec 当前 status；子 agent 返回的第一行；本 story 主步骤已经 dispatch 了几次 | A. 直接续跑，bmad-build-auto 会按 spec status 接着做（占用本 story 唯一一次中断重启；已经用过就不要列这条）。<br>B. 返回内容是 Traceback、脚本找不到之类的 plugin 或运行时错误 → `/super-harness:report-issue` |
| 配额耗尽 | 报错里的 reset 时间（有就写）；`harness-state.py $KEY --plain` 的 `next_action_code` | A. 等到 reset 之后说「重启 <B1/B2/B3/⑥>」。`next_action_code` 是 `build-verify` 的，写明 build 其实已经跑完，重启只做验收 |
| `DIRTY_WORKTREE=` | 未提交文件列表，每个标出是新增还是修改 | A. 这些文件该留：看过内容后自己 commit，再续跑（会重新验收）。<br>B. 不该留：给出只针对这些文件的清理命令（`git restore -- <文件>`、`rm <未跟踪文件>`），清理后续跑 |
| `BLACKLIST=`、`CROSS_STORY=`、`OUT_OF_SCOPE_BMAD=`，或 `harness-commit.py` 报 `FORBIDDEN=`、`UNEXPECTED_ARTIFACT=` | 每个越界路径，以及引入它的 commit（`git log --oneline harness/$KEY/start..HEAD -- <路径>`） | A. 这个路径确实不该动：在一个新 commit 里改回去，然后续跑。<br>B. 判定像误报（比如本该放行的模板文件、本 story 自己的产物）→ `/super-harness:report-issue`，它会附临时绕过方案 |
| `NO_CODE_CHANGE=` | spec Tasks 列表；Auto Run Result 里说做了什么 | A. 实现漏了：spec `status` 改成 `in-progress`，commit，续跑。<br>B. 这条 story 本来就不需要改代码（已被前序 story 做掉、纯文档）：在 sprint-status 里把它标 done，`git tag harness/$KEY/done`，然后 `/super-harness:run-inline` 跑下一条 |
| B3 留下未提交改动（§0.B `blocked-dirty`，follow-up 那一行） | `git status --porcelain`；spec Auto Run Result 里最后一轮在修什么 | A. 丢掉这些改动：`git restore --source=HEAD --staged --worktree -- .`，未跟踪文件逐个删，续跑会重新做 B3。<br>B. 改动看过没问题：自己 commit，续跑会直接验收 |
| 工作区不干净（B0、`run-inline` §0.A） | 未提交文件列表；能看出来源的写出来源（上一条 story 的 ⑥ 产物、用户手改） | A. 用户自己的改动：commit 或 `git stash` 后重跑。<br>B. 上一步 harness 留下的：说明是哪一步，给出对应的 commit 或清理命令 |
| 子 agent 连续 2 次发问 | 两次问题原文 | A. 直接回答，主 agent 按 §3.2 写回 spec 并续跑。<br>B. 把答案补进 `.claude/harness/answer-policy.md` 或 harness-project-config.yaml 的项目语境，以后同类问题自动代答，然后续跑 |
| dispatch 超过 4 次、想第二次进入 B2 修复 → B3 循环 | 每次 dispatch 的结果各一行 | A. 按最后一次失败的原因处理（套用本表对应那一行），处理完续跑。<br>B. `git reset --hard harness/$KEY/start` 撤回本 story，拆小或改 spec 后重来 |
| `check_bmad_runtime.sh` STATUS=fail | `REMEDIATION=` 行 | A. 按 REMEDIATION 处理后重跑 |
| `retro_gate: block` 且有 `_NO_SPEC_` 项 | 那 K 条 dev 项 | 用 §0.A.0「缺 spec 兜底」那两条 |
| retro verdict 为 rejected | retro 文档 Acceptance verdict 段和 Open questions 段要点 | A. 补救工作开成新 story（BMad 加进 epics 和 sprint-status）后重跑。<br>B. 判断可以接受：直接重跑。retro 和 epic 在 sprint-status 里已经是 done，不会再停在这里 |
| 脚本内部错误（Traceback、约定之外的退出码）或上面都对不上 | 报错前 10 行左右 | A. `/super-harness:report-issue`。<br>B. 能看出直接原因（权限、磁盘、缺命令）就写出来，给出修法，修完续跑 |

表里没列到的原因，照同样的思路自己写：先说事实，再给 1 到 3 条针对这次原因的做法。

### 3.2 用户在对话里回答了 intent gap 或子 agent 的问题

只在用户明确给出答案时做，答案不完整就追问缺的那几个，不要替用户补。

1. 把问答写进 spec 的 `<intent-contract>` 块末尾，标题 `### Clarifications (<日期>)`，一问一答，问题照抄，答案用用户的原话。bmad-build-auto 重新规划时会原样保留这个块。
2. frontmatter `status` 改成 `draft`，其他字段不动。B3 停下的（已有 `harness/$KEY/built` 和 `followup-start` tag）改成 `in-review`：代码已经在了，只要接着 review，`draft` 会让 bmad-build-auto 整条重新规划。
3. `git add <spec 路径> && git commit -m "docs($KEY): 补充 intent gap 答复"`。
4. 调 `harness-state.py $KEY`，按 §0.B 切入（B1 停的这时应是 `build`，B3 停的是 `followup`）。这次 dispatch 计入本 story 的 dispatch 次数。

答案涉及改需求（epics 里的 story 定义）时不走这一节，按 §3.1 第一行 C 处理。调度模式不走这一节，调度者不自己改 lane worktree 里的文件，改用 `superh.py resume <KEY> --note "<答复>"`（每条答复一个 `--note`），它做的就是上面 1 到 3 步，另外把 `followup-start` 挪到新提交上，再把这一路重新排队（`run` §7）。

### 3.3 lane 模式：能自己接着走的两种停顿

只在 lane 模式生效。B1 或 B3 的验收报 `SPEC_STATUS_NOT_DONE=blocked`（或 §0.B 切入时是 `blocked`）时，先对照下面两种情况，都不符合再回报 `blocked`。两种都用 `superh.py reopen`：它在 lane worktree 里把 spec 改回能续跑的状态并 commit（spec 还没入库时先把停下时的样子单独 commit 一次，用户推翻时回到这里），B3 阶段再把 `followup-start` 挪到新提交上，最后输出 `STATUS=ok`。bmad-build-auto 在 review 阶段停下时保存的尝试改动（artifacts 目录下未入库的 `.patch` / `.diff`）会被挪到 `.git/super-harness/patches/<KEY>/`，输出 `MOVED_PATCH=`，不删除。之后调 `harness-state.py $KEY`，按 §0.B 切入（B1 停的回到 `build`，B3 停的回到 `followup`）。reopen 之后的重新 dispatch 不计入 §3 表里「主步骤 dispatch > 4」的次数，它的次数由 reopen 自己限制（代答 2 次、超时重跑 1 次）。

**(a) 有推荐读法的问题，按推荐项代答**

条件，全部满足才做：

1. worker prompt 里的决策模式是 `proceed`。
2. blocking condition 是 `intent gap`、`unclear intent`、`matrix ambiguity`，或者 Auto Run Result 列出了待回答的问题。
3. 每个问题都能按 `.claude/harness/answer-policy.md` 的决策原则和项目语境挑出一个读法。bmad-build-auto 给了候选读法时从候选里挑。
4. 没有一个问题落在 answer-policy「必须人工确认」那几类里。

做法：

1. 用 Write 在仓库之外写一个临时 JSON 文件（例如 `mktemp` 得到的路径），每个问题一项：
   ```json
   [{"question": "<Auto Run Result 里的问题原文>",
     "options": ["<候选读法 1>", "<候选读法 2>"],
     "chosen": "<挑中的读法，写到实现者照着做不会再有歧义>",
     "why": "<一句理由，指向 answer-policy 的哪条原则或项目语境的哪一点>"}]
   ```
2. `python3 .claude/harness/scripts/superh.py reopen $KEY --why "<blocking condition>" --decisions-file <文件>`。答复写在 spec `<intent-contract>` 末尾的 `### Clarifications（<日期>，按推荐项代答，待确认）` 里，带决定编号；B1 停的 spec 改成 `draft`（bmad-build-auto 重新规划时原样保留这一块），B3 停的改成 `in-review`。
3. `STATUS=ok`：删掉临时文件，记下 `DECISION_IDS=`，按 §0.B 续跑。最后回报 `ready` 时在 summary 里带上这些编号。决定进了调度者的收件箱，用户之后批量确认，推翻某一条时调度者会把这一路退回到决定之前按新答复重跑，worker 不用管。
4. `STATUS=halt`（同一条 story 已经代答过 2 次、决策模式是 `ask`、工作区里有 spec 之外的改动）：按 §3 回报 `blocked`，把 reopen 的输出也写进 `--halt`。

还没有 spec 就停下的（`BUILD_AUTO_RESULT=`）同样适用：reopen 会删掉 result 文件，输出 `INTENT_APPENDIX<<` 段。按 §0.B 切入时是 `build`（还没有 spec，用 B1「首次」intent），把这一段原样加在 intent 末尾。

**(b) 验证命令超时，重跑一次**

blocking condition 是 `implementation verification failed` 或 `patch verification failed`，并且 Auto Run Result 写明失败的命令是超时或挂住被结束的（不是断言失败、编译错误）：

```bash
python3 .claude/harness/scripts/superh.py reopen $KEY --kind transient \
  --why "<失败的命令> 超时，重跑一次" --status <in-progress|in-review>
```

`implementation verification failed` 用 `in-progress`，`patch verification failed` 用 `in-review`。每条 story 只能用一次，第二次 reopen 会返回 `STATUS=halt`，那时按 §3 回报 `blocked`。


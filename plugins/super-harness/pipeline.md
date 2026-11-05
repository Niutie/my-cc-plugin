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

**(a) 监控信号**：你用 `Agent` / `SendMessage` 调度子 agent 时是同步等待的——子 agent 返回的那条消息就是"完成信号"。每次调用后做两件事：
1. **看产物 / 跑审计**：每个阶段都列了"验收"项（B1/B3 是 `harness-commit.py build-verify`）。失败 → halt。
2. **看状态**：`python3 .claude/harness/scripts/harness-state.py $KEY --plain` 只读核对。发现与预期不符**不要**手工 `set`：sprint-status 推进只发生在 B4 `build-sync`（以及 retro 阶段），由 `harness-commit.py` 统一完成。

**结构化校验优先，不做文本扫描**：主 agent 不在子 agent 返回文本里搜 `error` / `failed` 之类的词判断成败（误报极高）。真正的失败一定能被结构化校验抓到：build-verify 的 `SPEC_STATUS_NOT_DONE=` / `DIRTY_WORKTREE=` / `CROSS_STORY=`，`harness-commit.py` 的退出码 1。

**配额耗尽的判定**：Claude 运行时的额度耗尽在结构化层看不到，但也**不靠搜关键词**。story 本身可能就在做限流、鉴权、密码重置，子 agent 的正文里出现 `quota` / `rate limit` / `reset` / `unauthorized` 很正常。只有下面两条同时成立才算配额耗尽：
1. 结构化校验已经失败：build-verify 报 `SPEC_STATUS_NOT_DONE=` / `SPEC_MISSING=`，或某阶段的"验收"产物缺失；
2. 子 agent 的返回**第一行**就是 Claude Code 运行时的额度报错，以 `Claude AI usage limit reached`、`You've hit your limit`、`5-hour limit reached`、`API Error: 429` 之一开头（这类返回通常只有一两行，没有子 agent 自己写的正文）。

两条都满足 → halt，用 §3 配额模板（选项 5）。只满足第 1 条 → 普通 halt。`API Error: Overloaded` 之类不是配额，按各阶段的瞬态错误规则处理。codex 的额度、登录问题不走这一条，看 `run_codex_review.sh` 输出的 `CODEX_STATUS:`（§B2.2）。

> **关于 git index**：bmad-build-auto 自己 commit；harness 自己的 commit（B2 的 3/4、B4、retro）一律经 `harness-commit.py` 预先 stage。主 agent 任何时候都不自己 `git add`。

**(b) 代答政策**：用户授权你在循环中替他回答所有 BMad / Codex 子 agent 的问询。通用决策原则在 `.claude/harness/answer-policy.md`，项目语境由 `harness-prompt-suffix.py` 从 harness-project-config.yaml 读出并内联进 prompt 后缀。

1. **每一个** subagent prompt 末尾都必须附带 prompt 后缀，**不要手贴**，改用：
   ```bash
   python3 .claude/harness/scripts/harness-prompt-suffix.py <stage>
   ```
   stage 取值：`build`（B1/B3）/ `4`（B2 fix）/ `6`（retro）/ `chore`（§0.A.0 retro-fulfill）。`implement` 由 bmad-build-auto 的实现子 agent 自己拉取，主 agent 不用。B2.2 codex review 由主 agent 直接跑脚本，不起子 agent，`3` 不再使用。`1` / `2` / `5` 只给 §1.L 旧流水线 story 用。
2. bmad-build-auto 本身无人值守、不提问；intent 不清会 HALT `blocked`。其它子 agent 若仍提问回来（罕见），用 `SendMessage` 重发一次"按 `.claude/harness/answer-policy.md` 自决"，**不要**转给用户。
3. 真正必须 halt 的只有 §3 列出的硬错误。"我需要你确认 X / Y" 不属于硬错误。

**(c) 进度可视化**（inline 模式）：用 TaskCreate 在启动时为每条要跑的 story 建一个任务，之后用 TaskUpdate 改状态：进入流水线时 `in_progress`，完成时 `completed`。lane 模式和调度模式不调用 TaskCreate / TaskUpdate / TaskList，lane 模式也不调用 AskUserQuestion。

**(c′) lane 模式的额外约束**：
- 只在自己的 worktree 里工作。不 `cd` 到主 worktree 或其他 lane 的目录，不切分支，不 merge / rebase / reset，不删除或移动任何 tag（新打本 story 的 tag 除外）。
- 不碰 `sprint-status.yaml` 里本 story 的状态。账本由调度者在合流后统一写。
- 本手册要求「halt 并把 §3 模板贴给用户」的地方，lane 模式改为按 worker prompt 的回报命令报 `blocked`（配额耗尽报 `quota`），把 halt 原因和脚本完整输出写进 `--halt`，然后结束。不尝试自愈，也不重跑失败的子 agent。

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

1. **实现**：spawn 一个 fresh general-purpose subagent，prompt = `$SPEC` 全文 + "按本 chore spec 的 Tasks & Acceptance 段实现项目代码；这是一次性 chore 兑现，**不走** bmad-build-auto / codex / review 循环；完成后在 spec 的 Tasks checkbox 打勾。只动 spec 描述范围内的项目代码，不碰其它 story 的 artifacts；spec frontmatter 若声明了 `planning_artifacts:` 白名单（issue #9），按 spec 要求回写那些文件也在范围内。不要做任何 git 操作。" + `python3 .claude/harness/scripts/harness-prompt-suffix.py chore` 的 stdout。
2. **翻状态**（两本账都翻）：
   - 用 Edit 把 `sprint-status.yaml` 里 `retro_action_items.epic-${EPIC}-retro.${CODE}` 的 status 翻成 `done`（只动这一行：嵌套写法是该条目下的 `status:` 子键，旧标量写法是 `${CODE}: <status>` 那一行）。
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

### 0.B 续作切入表

一条 story 已有 `harness/<KEY>/start` tag 时，先跑 `python3 .claude/harness/scripts/harness-state.py <KEY>` 拿状态 JSON（**必须用脚本**，不要自己 grep git log 推断），再按 `next_action_code` 切入：

| code | 动作 |
|---|---|
| `build` | §1 B1（spec 已存在时 intent 指向 spec 文件，bmad-build-auto 按 spec status 自己续跑） |
| `build-verify` | §1 B1 的"验收"一步 |
| `codex` / `codex-fix` | §1 B2 对应子步 |
| `followup` | §1 B3（`followup-start` tag 已存在时不要重打，直接 dispatch，bmad-build-auto 按 spec status 续跑） |
| `followup-verify` | §1 B3 的"验收"一步（follow-up 已经跑完，**不要**再 dispatch B3） |
| `sync` | §1 B4 |
| `tag-only` | `git tag harness/<KEY>/done`，进 ⑥ 判断 |
| `blocked` | halt：bmad-build-auto 已 HALT blocked，把 spec `## Auto Run Result`（或还没有 spec 时的 `bmad-build-auto-result-*.md`）里的 Status / blocking condition 贴给用户 |
| `blocked-dirty`（`next_action` 以 `B2 codex review report` 开头） | B2.2 跑完但没 commit。`git status --porcelain` 只有未入库的 `<KEY>.codex-review.md`，且它的 frontmatter 有 `findings:` 行（`run_codex_review.sh` 只在成功时写这个文件，写的时候带这一行）→ 跑 `harness-commit.py 3` commit，再重新切入。文件没有 `findings:` 行（旧版本中途留下的）→ 按 §B2.1 c) 的命令删掉它，重新调 `harness-state.py`（会回到 `codex`）。还有别的改动 → halt |
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
- **Deferred-work 注入（C11）**：stderr 不并进来（`read_harness_config` 的 WARN 行会混进 build intent），失败时单独显示：

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
  > （lane 模式把上面这句换成：）当前分支 `<lane 分支>` 是 super-harness 为本 story 单独开的分支，从 sprint 分支 `<sprint 分支>` 开出，只承载这一条 story；分支名与 sprint 不同不算 branch mismatch。
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
  - `SPEC_STATUS_NOT_DONE=<其它>` 或 `SPEC_MISSING=`：subagent 中途退出。按 §−1 (a) 的「配额耗尽的判定」看返回第一行：是运行时额度报错 → 配额模板；不是 → 普通 halt。
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
- **≥ 1 条** → dispatch 下面的修复 agent。

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

**验收**：跑 `harness-state.py $KEY`，看 JSON 里的计数：
- `codex_findings` ≥ 1：`codex_handling_rows`（spec `### Codex Review Handling (Stage 3)` 段里 `- [F-N ...]` 行数）= `codex_findings`；
- `codex_findings` = 0：`codex_handling_none` 为 true（段里有那条 `- [none]` 行）；
- `codex_findings` 为 null（报告不存在）→ halt。

**commit**：`python3 .claude/harness/scripts/harness-commit.py 4 $KEY`。finding ≥ 1 时，B2.3 commit 之后 **B3 必跑**（修复代码还没被 review 过）；0 finding 的那次 commit 不是修复，不触发 B3。

### B3（条件触发）：follow-up review（bmad-build-auto 对 done spec 再跑一轮 review）

**触发条件**（任一）：B2.3 commit 了修复（codex finding ≥ 1；0 finding 时写 `- [none]` 行的那次 commit 不算）；B1 验收 `FOLLOWUP_RECOMMENDED=true`。都不满足 → 跳过。**每条 story 最多一轮**。

dispatch 之前先 `git tag harness/$KEY/followup-start`（续作时据此区分"还没跑"和"跑完待验收"，避免重复跑第二轮）。

```
Agent({
  subagent_type: "general-purpose",
  description: "Follow-up review <KEY>",
  prompt: "## Build intent\n\n对已完成的 spec `<spec 路径>`（story `<KEY>`）做一轮 follow-up review：直接把这个 spec 文件路径交给 bmad-build-auto（status done 的 spec 会进入新一轮 review pass，审查 baseline 以来的全部改动，包括 codex 修复）。\n\n---\n\n" + <`harness-prompt-suffix.py build` 的 stdout>
})
```

**验收**：再跑 `python3 .claude/harness/scripts/harness-commit.py build-verify $KEY`。STATUS=ok → `git tag harness/$KEY/followup`；halt 处理同 B1。

这一轮之后 `FOLLOWUP_RECOMMENDED` 仍为 `true` → 不再循环，在本 story 回报里写一行"bmad-build-auto 仍建议再 review：<spec `## Auto Run Result` 里点名的风险>"，交给用户决定。lane 模式把这句风险用 `--followup-note` 带进回报。

**lane 模式到此结束**：最后一次 `build-verify` 是 `STATUS=ok`、`git status --porcelain` 为空时回报 `ready`。B4 及之后的步骤由调度者在合流后执行。

### B4：build-sync（harness 自己的收口 commit）

inline 模式在 B3 之后直接执行。调度模式在 lane 合流进 sprint 分支之后执行，每一步做之前先问 `superh.py postmerge <KEY>` 还差什么（见 `run` §4）；第 0 步的 reason 取 `superh.py integrate` 输出的 `CODEX_SKIP_REASON=`，`BASE` 取它的 `BASELINE_REVISION=`。

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

`git log --oneline harness/$KEY/start..harness/$KEY/done` 即本 story 完整提交序列。inline 模式：用 TaskUpdate 把本 story 的任务标 `completed`。

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

**retro 用的 `KEY`**（inline 模式的 retro-only 启动、调度模式都按这条取）：Read `sprint-status.yaml` 的 `development_status:`，在 `${EPIC}-` 开头的 key 里按 yaml 顺序取最后一条 status=done 的，再用 `sprint-status.py epic-of $KEY` 验证等于 `$EPIC`。**禁止**传空串或编造 key（`harness-commit.py` 的 key 位参必填）。

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
> 1. Phase 1 Gather 之后、Phase 2 Analyze 之前先跑 `bash .claude/harness/scripts/run_retro_self_audit.sh <EPIC-1>`。首行是 `RETRO_SELF_AUDIT: no-config`（项目没配 `.claude/harness/retro-self-audit.tsv`）时不贴它的输出，§2 表格手工填；脚本失败也不阻断，同样手工填。
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

### 阶段 ⑥.5（条件触发）：Retro Residue Processing（Chore C10）

阶段 ⑥ commit 完成后触发，把 retro 里 pending / partial / in-progress 的 action items 转成可执行的 `chore-retro-c${EPIC}-<code>-<slug>.md` spec。主 agent 不经手 prompt 和 spec 的正文：脚本把 prompt 写进临时文件，子 agent 自己读、自己写 spec，只回一份短清单。

1. `bash .claude/harness/scripts/process_retro_residue.sh --epic $EPIC`：
   - 退出码 0 → stdout 只有几行：`PROMPT_FILE=<临时文件绝对路径>`、`PENDING_COUNT=<n>`、`PENDING_CODES=<code 列表>`、`ARTIFACT_DIR=<spec 目录>`。记下这四个值。
   - 退出码 2 → "no residue to process"，跳过本阶段。
   - 退出码 1 → halt。
2. dispatch 一个 fresh general-purpose agent（`description: "Process retro residue epic-<EPIC>"`），prompt 只写一句话加后缀，不要把 prompt 文件内容贴进去："Read `<PROMPT_FILE>`，按其中的指令执行：每条待处理项用 Write 直接写到 `<ARTIFACT_DIR>/`，最后只回 MANIFEST 块和 ≤ 200 字总结。" + `harness-prompt-suffix.py chore` 的 stdout。
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
| `legacy-stage5` | 调 `bmad-code-review`：review target = commit range `<stage2_base_sha>..HEAD`（diff 用 `git diff <range> -- . ':!.claude'`），spec_file = `<KEY>.md`，所有 HALT / CHECKPOINT 按 answer-policy 自决、patch 选 "Apply every patch"；另写 `<KEY>.review-findings.json`（`unresolved` / `resolved` / `final_story_status`）。验收后 `harness-commit.py 5 $KEY` + `git tag harness/<KEY>/done`。prompt 后缀用 `harness-prompt-suffix.py 5` |

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

任何一项触发都立即 halt，不要尝试自愈。子 agent 提问 / 请求确认不在此列（按 §−1.b 处理）。

halt 的落地方式按模式不同：inline 模式打印下面的 halt 模板；lane 模式按 §−1 (c′) 回报 `blocked` / `quota`；调度模式按 `run` §8，先贴看板，再贴 halt 模板。

| 触发条件 | 处理 |
|---|---|
| 启动时（`run-inline` §0.A 第 0 步、lane 模式 B0、`run` §0）`check_bmad_runtime.sh` STATUS=fail | halt，贴 `REMEDIATION=` 行 |
| 配额耗尽（§−1 (a) 的两条判定同时成立：结构化校验失败 + 子 agent 返回第一行是运行时额度报错） | halt + 配额模板（选项 5）。codex 的额度 / 登录问题不在此列：`run_codex_review.sh` 退出码 2 → §B2.1 skip+marker |
| `build-verify` STATUS=halt（`SPEC_STATUS_NOT_DONE=` / `SPEC_MISSING=` / `BUILD_AUTO_RESULT=` / `AUTO_RUN_RESULT_MISSING=` / `DIRTY_WORKTREE=` / `BLACKLIST=` / `CROSS_STORY=` / `OUT_OF_SCOPE_BMAD=` / `NO_CODE_CHANGE=`） | halt，贴脚本完整 stdout。commit 已存在，**不撤** |
| B0 工作区不干净 | halt |
| `harness-commit.py` 退出码 1 | halt，贴脚本完整 stdout（`BLACKLIST=` / `CROSS_STORY=` / `UNEXPECTED_ARTIFACT=` / `FORBIDDEN=` / `UNSTAGED=` 等） |
| 预期产物缺失或为空（各阶段"验收"项） | halt。⑥ 瞬态 infra 错误 + 干净工作区允许重试一次（见阶段 ⑥） |
| `retro_gate: block` 且 §0.A.0 仍有 `_NO_SPEC_` dev retro 项 | halt，不 dispatch B1 |
| `run-inline` §0.A 工作区不干净且没有 in-flight story | halt |
| 子 agent 返回缺 `git status --porcelain` 自报段 | 不 halt，主 agent 自己跑一次交叉核对；发现子 agent 改了它没声称改过的文件 → halt |
| `RETRO_VERDICT=rejected` 且 `EPIC_WONT_DO=none`、`EPIC_PARKED=none`，并且是 inline 模式 `LOOP_SCOPE=all` 或调度模式 | halt，不进下一个 epic |
| 单条 story 主步骤（B1 / B2.3 / B3）累计 dispatch > 4 个子 agent（3 个 + 至多 1 次中断重启；B2.2 是脚本，不计）。⑥ / ⑥.5 / §0.A.0 不计入，各有上限：⑥ / ⑥.5 每 epic 各 1 个（另允许至多 1 次额外重启，配额重启与 ⑥ 瞬态重试合计）；§0.A.0 每个 dev 项 1 个 | halt |
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
       /super-harness:run-inline --continue     （续作本 story）
       /super-harness:run-inline                （跳到下一条 backlog；本 $KEY 应已 done 或被人为推进）
       /super-harness:run                       （调度模式：重新进入并行调度，会从磁盘状态接着处理）
  5. （仅配额耗尽）等到 reset 时间，告诉我"重启 <B1|B2|B3|⑥>"，我会重新调度该步
  6. 怀疑是 plugin 缺陷？跑 /super-harness:report-issue（自动收集上下文，gh CLI 直提，附临时绕过方案）

子 agent 完整返回 / 脚本完整 stdout 如下：
<逐字粘贴>
```

任何场景都打印这段，不要简化，不要替用户选。


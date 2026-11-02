---
description: 多路并行跑 sprint：按 depends_on 挑出可并行的 story，每条 story 开一个独立 worktree + headless claude worker 跑 harness-zh 的 B0-B3，主 worktree 串行合流并执行 build-sync、测试和 epic retro
argument-hint: '[--slots <N>] [--dry-run]'
allowed-tools: Bash, Read, Write, Agent, AskUserQuestion
---

# /super-harness:run — 多路并行 sprint 调度

你是调度者。你不写业务代码，也不直接运行 bmad-build-auto。你要做的是：挑出可以启动的 story、开 lane、启动 worker、等待、合流、收口，并且只在需要人处理时打扰用户。

每条 story 的 B0-B3（build、外部 codex、follow-up review）由 worker 在自己的 worktree 里完成，worker 遵循的仍然是 harness-zh 的 `.claude/commands/run.md`。B4 及以后（build-sync、⑤.5 测试、⑥ retro）由你在主 worktree 里按完成顺序逐条执行，步骤同样以 harness-zh `run.md` 为准。

下文用 `SH` 代指 `python3 .claude/super-harness/scripts/superh.py`，用 `HZ` 代指 harness-zh 手册 `.claude/commands/run.md`。

## −1. 行为契约

- 决策只依据脚本的结构化输出：`SH tick` 的 JSON、各命令的 `STATUS=` 行和退出码。不要从 worker 日志的自然语言里推断成败。
- 主 worktree 的写操作只有四种来源：`SH integrate` 的 ff 合并，`harness-commit.py` 的 stage（commit 用它给的 message），HZ §B2.1 a) 的 marker 文件，以及 HZ 规定的 `git tag`。你自己不 `git add`，也不改代码。
- 不进入 lane worktree 改文件。lane 里的事要么交给 worker，要么交给合流冲突子 agent（§3）。
- 以下动作必须先得到用户同意：`SH abandon`、删除 tag、`git reset`、切换主 worktree 的分支。
- 某一路出问题时，只停这一路，其他路照常推进。只有 §8 列出的情况才停下整个调度。
- 用户在 HZ 里给过的代答授权在这里同样有效。子 agent 发问时，按 `.claude/harness/answer-policy.md` 自行决定。

## 0. 启动

1. 检查部署：`.claude/super-harness/scripts/superh.py` 和 `.claude/harness/scripts/harness-commit.py` 都要存在。缺任何一个，提示用户先跑 `/super-harness:init`，然后退出。
2. `bash .claude/harness/scripts/check_bmad_runtime.sh`，`STATUS=fail` 时 halt（§8），贴出 `REMEDIATION=` 行。
3. 固定本次运行的 sprint 分支：`SH start-run`，带 `--slots N` 参数时加上 `--slots N`，没带时加 `--reset-slots`。
   - `MAIN_CLEAN=false`：halt，贴出 `DIRTY=` 行。合流需要干净的主 worktree。
   - `MAIN_CLEAN=resumable`：上次收口在 sync 步骤中途被打断（marker 已写或 build-sync 已暂存，还没 commit），脏文件都属于 `RESUMABLE_LANES=` 里的 lane。照常继续：tick 会先给出 `post-merge`，§4 的 `postmerge` 会给出 `NEXT=sync`，重跑 build-sync 时这些改动会一起提交。告诉用户一行「接着上次中断的收口：<KEY>」。
4. `--dry-run`：执行 `SH plan` 和 `SH board`，把输出原样给用户，然后退出。不 prepare，不 launch。
5. 给用户一行开场：sprint 分支、slot 数、就绪的 story 数（来自 `SH tick` 的 `launch` 和 `waiting`）。

上次运行留下的 lane 不需要特殊处理，`SH tick` 会从磁盘状态把它们读出来。

## 1. 主循环

每一轮都从下面这条命令开始：

```bash
python3 .claude/super-harness/scripts/superh.py tick
```

先看 `problems`，非空就 halt（§8）。否则按 `next_action` 分派：

| next_action | 做什么 |
|---|---|
| `post-merge` | 对 `post_merge` 里的第一条执行 §4（上次运行中途停下、已经合入但还没收口的 lane） |
| `integrate` | 对 `integrate` 里的第一条执行 §3，接着执行 §4 |
| `retro` | 对 `retro_due` 里的第一个 epic 执行 §5 |
| `launch` | 执行 §2 |
| `wait` | 执行 §6 |
| `stalled` | 执行 §7 |
| `finished` | 执行 §9 |

做完一步就回到本节开头重新 tick，不要依赖上一轮的 JSON。

每一轮都检查 `attention`。出现了新的条目（和你上次告诉用户的不同），就用一行告诉用户：key、阶段、detail、接手命令（`takeover` 字段）。然后继续循环，不要等用户回复。处理规则：

- `crashed`：worker 进程丢失，通常是上一个会话结束了。同一路第一次出现时自动执行 `SH retry <KEY>`，下一轮会重新 launch；worker 会按 harness-state 续作。第二次再出现就留给用户。
- `blocked` / `failed` / `held` / `conflict`：留给用户，不自动重试。
- `quota`：tick 已经停止派发新 lane（`quota_hold: true`）。等在跑的 lane 全部结束后，按 §8 的配额模板 halt。

## 2. 启动 lane

1. `queued` 里的 key（之前 prepare 过、或刚被 retry 的 lane）：直接执行第 3 步的 launch。
2. `launch` 里的每个 key，按顺序（其中可能有上次 prepare 中途被打断的 lane，`SH prepare` 会先清理现场再重做，输出里带 `ROLLED_BACK=`）：
   - 它所属的 epic 在 `epic_start` 里，说明这是该 epic 第一次有 story 启动。先在主 worktree 执行 HZ §0.A.0（retro DEV 项兑现 gate），通过之后再继续。同一个 epic 只做一次。
   - `SH prepare <KEY>`。`STATUS=halt` 时把输出贴给用户，跳过这个 key（lane 已记为 held，会出现在 attention 里），继续下一个。
3. launch 用 Bash 的后台模式运行，每个 key 单独调用一次：
   ```
   Bash({
     command: "python3 .claude/super-harness/scripts/superh.py launch <KEY>",
     description: "Run super-harness worker for <KEY>",
     run_in_background: true
   })
   ```
   不要用前台模式，也不要给它设 timeout。worker 跑完时你会收到通知。
4. 回到 §1。

## 3. 合流

```bash
python3 .claude/super-harness/scripts/superh.py integrate <KEY>
```

脚本会把 lane 分支 rebase 到 sprint 分支最新提交上，自动消解账本类冲突（`sprint-status.yaml` 和 `epic-N-context.md` 取 sprint 分支版本，`deferred-work.md` 做 union 合并），把 `harness/<KEY>/{start,built,followup-start,followup}` 这几个 tag 搬到 rebase 之后的提交上，在 lane worktree 里重跑 `build-verify`，最后 ff 合并进主 worktree。

- 退出码 0：记下输出里的 `CODEX_SKIP_REASON=`、`FOLLOWUP_NOTE=`，以及 `BUILD_VERIFY<<` 段里的 `BASELINE_REVISION=`，进入 §4。输出里有 `RECOVERED=already-merged` 时，说明上一次合流已经 ff 成功、只是没记下来，照样进入 §4；有 `WARN=` 行时把它转告用户。
- 退出码 3（`STATUS=conflict`）：派一个合流冲突子 agent。
  1. Read `.claude/super-harness/prompts/merge-fix.md`，替换占位符：`{{KEY}}`；`{{WORKTREE}}` 取输出的 `WORKTREE=`；`{{CONFLICT_FILES}}` 取所有 `CONFLICT_FILE=` 行，用顿号连接；`{{SPEC}}` 取 `cd <WORKTREE> && python3 .claude/harness/scripts/harness-state.py <KEY> --story-md` 的输出，失败就留空。
  2. 用前台 Agent 运行（`subagent_type: "general-purpose"`，`description: "Resolve merge conflict <KEY>"`）。
  3. 返回的第一行是 `NEEDS_PERSON:` 时，把原因告诉用户，这一路留在 conflict 状态，回到 §1。
  4. 否则重跑 `SH integrate <KEY>`。退出码 0 进入 §4；再次返回 3 时不再派第二个子 agent，告诉用户，回到 §1。
- 退出码 1：
  - `REASON` 说的是主 worktree 不干净或不在 sprint 分支：全局 halt（§8）。
  - 其他情况（例如 rebase 之后 build-verify 不通过）：这一路已经记为 held，sprint 分支没有被改动。把输出贴给用户，回到 §1。

## 4. 收口（主 worktree 串行执行）

收口的每一步都可能被打断（会话被关、配额耗尽），所以不要按固定顺序从头执行。每一步开始前先问脚本还差什么：

```bash
python3 .claude/super-harness/scripts/superh.py postmerge <KEY>
```

它只读，按磁盘上的事实（done tag、harness-state、测试产物、检查点）给出 `NEXT=`。按 `NEXT` 做对应的一步，做完再执行一次 `postmerge`，直到 `NEXT=finish`：

| NEXT | 做什么 |
|---|---|
| `sync` | 1. `MARKER=write` 时，按 HZ §B2.1 a) 的格式写 `<KEY>.codex-skipped.json`：reason 取 `CODEX_SKIP_REASON=`，`BASE` 取 integrate 输出的 `BASELINE_REVISION`，没有就取 `git rev-parse harness/<KEY>/start`。`MARKER=present` 或 `none` 时不要写，也不要重写已有的 marker。<br>2. 按 HZ §B4 执行 `harness-commit.py build-sync <KEY>`：STATUS=ok 时 commit，然后立刻 `git tag harness/<KEY>/done`；STATUS=skip 时不 commit，但同样立刻打这个 tag（否则 `postmerge` 会一直停在 `sync`）。然后输出 deferred-work 趋势。`STATUS=halt` 时全局 halt（§8）：这时主 worktree 可能有已 stage 的改动，继续合流只会把问题叠上去。 |
| `tag` | build-sync 已经 commit，只差 tag：`git tag harness/<KEY>/done` |
| `test` | 按 HZ 阶段 ⑤.5 派 run-test 子 agent，做 sanity gate（测试红不算 halt，和 HZ 一致）。gate 通过后执行 `SH mark <KEY> --step tested` |
| `finish` | `SH mark <KEY> --phase done`，然后 `SH cleanup <KEY>`。给用户一行进度：`<KEY> 已完成（M/N），在跑 <running 数> 路`；`FOLLOWUP_NOTE=` 非空时作为第二行附上 |
| `halt` | 全局 halt（§8），贴出 `REASON=` 和 `HARNESS_STATE_RAW=` |

不要在 `postmerge` 之外自己判断「这一步做过了没有」，也不要对已经存在的 tag 再执行 `git tag`。

epic retro 不在这里执行。epic 的最后一条 story 收口之后，下一轮 tick 会给出 `retro`。

## 5. Epic retro

对 `retro_due` 里的 epic `<N>`：

1. 先在主 worktree 跑 `git status --porcelain`，确认干净。
2. 按 HZ §0.C 的第 2 步取 `KEY`（该 epic 按 yaml 顺序最后一条 status=done 的 story），然后执行 HZ 阶段 ⑥、⑥.5 和 verdict 门。
3. verdict 是 `rejected` 并且 `EPIC_WONT_DO=none`：停止派发新 lane，等在跑的 lane 结束、合流、收口之后，按 HZ「verdict 门」的文案 halt。

retro 期间其他 lane 照常在各自的 worktree 里运行，不受影响。

## 6. 等待

没有可做的事时（`next_action = wait`），执行一次 `SH board`，把「进行中」那几行原样给用户，然后结束这一轮回复。

不要 sleep，不要轮询日志。任何一个后台 worker 退出，你都会被唤醒；醒来后从 §1 继续。

## 7. 停滞

`next_action = stalled` 表示没有在跑的 lane，也没有可启动的 story，但 sprint 还没完成。执行 `SH board` 和 `SH plan`，把「需要你处理」的部分和等待原因原样给用户，并附上下面的说明，然后结束：

```
处理完之后重新执行 /super-harness:run。常用操作：
  接手某一路：        cd <worktree> && claude --resume <session>
  修完让 worker 续作：python3 .claude/super-harness/scripts/superh.py retry <KEY>
  合流冲突手工解决后：git add 解决好的文件，重新执行 /super-harness:run（会从 rebase 现场继续）
  放弃某一路：        python3 .claude/super-harness/scripts/superh.py abandon <KEY> --yes
```

## 8. 全局 halt

以下情况停止整个调度：

| 情况 | 处理 |
|---|---|
| `check_bmad_runtime.sh` 失败 | 贴 `REMEDIATION=` 行 |
| tick 的 `problems` 非空，或 integrate 报主 worktree 不干净、不在 sprint 分支 | 贴原文 |
| §4 的 build-sync / 5-5 等 `harness-commit.py` 退出码 1 | 按 HZ §3 的 halt 模板 |
| §4 的 `postmerge` 给出 `NEXT=halt`，或报 done tag 不在 sprint 分支上 | 贴脚本输出 |
| 配额耗尽（`quota_hold` 且没有在跑的 lane） | 按 HZ §3 halt 模板的选项 5 说明；恢复后执行 `SH retry <KEY>`，再重新执行本命令 |
| retro verdict 为 rejected | 按 HZ「verdict 门」 |

halt 时先执行一次 `SH board`，把输出贴在 halt 说明前面，让用户看到每一路停在哪里。在跑的 worker 不用停，它们结束后状态会落盘，下次执行 `/super-harness:run` 时会接着处理。

## 9. 完成

1. 执行 `SH board`，贴出结果。
2. 执行 HZ §2 末尾的「Codex-skipped 提醒」。
3. 一行总结：完成的 story 数、跑过 retro 的 epic。

## 参数

| 参数 | 含义 |
|---|---|
| 无 | 按 config 的 `max_slots` 跑完所有能跑的 story |
| `--slots <N>` | 本次运行改用 N 路并发（写进 `.git/super-harness/run.json`，下次不带参数时恢复成 config 的值） |
| `--dry-run` | 只打印就绪分析和看板 |

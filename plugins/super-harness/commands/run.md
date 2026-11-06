---
description: 多路并行跑 sprint：按 depends_on 挑出可并行的 story，每条 story 开一个独立 worktree + headless claude worker 跑流水线的 B0-B3，主 worktree 串行合流（可选合流验证）并执行 build-sync 和 epic retro
argument-hint: '[--slots <N>] [--dry-run]'
allowed-tools: Bash, Read, Write, Agent, AskUserQuestion
---

# /super-harness:run — 多路并行 sprint 调度

你是调度者。你不写业务代码，也不直接运行 bmad-build-auto。你要做的是：挑出可以启动的 story、开 lane、启动 worker、等待、合流、收口，并且只在需要人处理时打扰用户。

单条 story 的步骤都写在流水线手册 `.claude/harness/pipeline.md` 里。B0-B3（build、外部 codex、follow-up review）由 worker 在自己的 worktree 里按其中的「lane 模式」完成；B4 及以后（build-sync、⑥ retro）由你在主 worktree 里按完成顺序逐条执行，做法是其中的「调度模式」。开始前先 Read 一遍 pipeline.md。

想在当前会话里一条一条直接跑、看清每一步（调试、优化流水线时），用 `/super-harness:run-inline`。

下文用 `SH` 代指 `python3 .claude/harness/scripts/superh.py`，带 `P` 前缀的章节（`P§0.A.0`、`P§1 B4`、`P§3`）指 pipeline.md。

## −1. 行为契约

- 决策只依据脚本的结构化输出：`SH tick` 的 JSON、各命令的 `STATUS=` 行和退出码。不要从 worker 日志的自然语言里推断成败。
- 主 worktree 的写操作只有四种来源：`SH integrate` 的 ff 合并，`harness-commit.py` 的 stage（commit 用它给的 message），P§1 B2.1 a) 的 marker 文件，以及 pipeline.md 规定的 `git tag`。你自己不 `git add`，也不改代码。
- 不进入 lane worktree 改文件。lane 里的事要么交给 worker，要么交给合流冲突子 agent（§3）。
- 以下动作必须先得到用户同意：`SH abandon`、删除 tag、`git reset`、切换主 worktree 的分支。
- 某一路出问题时，只停这一路，其他路照常推进。只有 §8 列出的情况才停下整个调度。
- P§−1 (b) 的代答政策在这里同样有效。子 agent 发问时，按 `.claude/harness/answer-policy.md` 自行决定。
- 任何 `SH` 命令输出 `STATUS=locked`（退出码 4）时，说明另一个会话持有调度锁（见 §0 第 3 步），按 §8 全局 halt。

### 后台命令

`SH prepare`、`SH integrate`、`SH launch`、`SH watch` 都可能运行很久（`prepare_command`、`verify_command`、worker 本身），一律用 Bash 的后台模式运行，不要用前台模式，也不要设 timeout。前台调用会被 Bash 的时限杀掉。prepare 和 integrate 这样写，让退出码出现在输出的最后一行：

```
Bash({
  command: "python3 .claude/harness/scripts/superh.py integrate <KEY> 2>&1; echo \"SUPERH_EXIT=$?\"",
  description: "super-harness integrate <KEY>",
  run_in_background: true
})
```

启动之后结束本轮回复，不要 sleep，也不要轮询。命令结束时你会收到通知。收到通知后读这条命令的完整输出：通知里给了输出文件路径就用 Read 读它，否则用读取后台任务输出的工具。最后一行 `SUPERH_EXIT=<n>` 是退出码，按它和 `STATUS=` 行分支。没收到这条命令的通知之前，不要对同一个 KEY 再启动 prepare 或 integrate。

等待期间被别的通知唤醒（例如某个 worker 退出了），照常从 §1 tick。还在运行的 prepare 和 integrate 会出现在 tick 的 `preparing` / `integrating` 里，tick 不会再把它们分派出来。有 integrate 在运行时，tick 也不会给出 `post-merge`、`integrate`、`retro`，因为这几步都要写主 worktree。

## 0. 启动

1. 检查部署：`.claude/harness/scripts/superh.py`、`.claude/harness/scripts/harness-commit.py` 和 `.claude/harness/pipeline.md` 都要存在。缺任何一个，提示用户先跑 `/super-harness:init`（升级 plugin 之后是 `/super-harness:update`），然后退出。
2. `bash .claude/harness/scripts/check_bmad_runtime.sh`，`STATUS=fail` 时 halt（§8），贴出 `REMEDIATION=` 行。
2.5. retro_action_items 写法检查：`python3 .claude/harness/scripts/sprint-status.py migrate-retro-items --check`。退出码 3 表示还有 harness-zh ≤ 0.1.39 的旧写法，BMad 6.12 的 retro 脚本会因此失败。主 worktree 干净时先跑 `python3 .claude/harness/scripts/sprint-status.py migrate-retro-items`，再跑 `python3 .claude/harness/scripts/harness-commit.py retro-migrate -`，按 P§−1 (d) commit（位参 key 用 `-` 占位）；不干净时（例如上次收口被打断，见第 3 步）这次先不迁移，告诉用户一行，留到下次启动。
2.6. 依赖写法检查：`python3 .claude/harness/scripts/sprint-status.py flatten-deps --check`。退出码 3 表示 `development_status` 里还有多行块写法，BMad 6.12.4 的 retro 会把块里已经 done 的 story 算成未完成（issue #14）。主 worktree 干净时跑 `python3 .claude/harness/scripts/sprint-status.py flatten-deps`，再跑 `python3 .claude/harness/scripts/harness-commit.py deps-migrate -` 按 P§−1 (d) commit，告诉用户一行：依赖已挪到顶层 `story_dependencies`，调度结果不变。退出码 4 时把 stderr 的 `PROBLEM=` 行转告用户，不 halt。不干净时留到下次启动。
3. 取调度锁，固定本次运行的 sprint 分支：`SH start-run`，带 `--slots N` 参数时加上 `--slots N`，没带时加 `--reset-slots`。
   - 退出码 4、`STATUS=locked`：另一个仍然活着的会话正在调度这个仓库（`LOCK_PID=`、`LOCK_SINCE=`）。两个会话同时调度会互相删掉对方的 lane、同时合流同一路，所以不要继续。把 `REASON=` 告诉用户，然后结束。用户确认那个会话已经不再调度（卡住了，或者要换到这个会话接手）并明确同意之后，才执行 `SH start-run --take-over`（`--slots` 参数照旧），再从这一步继续。持锁的会话退出后锁自动失效，下次 start-run 会直接收回（输出 `LOCK_RECLAIMED=stale`）。
   - `MAIN_CLEAN=false`：halt，贴出 `DIRTY=` 行，执行 `SH end-run` 释放调度锁。合流需要干净的主 worktree。刚跑完 `/super-harness:init` 或 `update` 时，脏文件通常是 `.gitignore`、`.claude/harness/harness-project-config.yaml`、`.claude/harness/parallel.yaml` 和新建的 `deferred-work.md`：提示用户按 init §5 把它们提交（仓库还没有任何 commit 时先做一次初始提交），不要替用户提交。
   - `MAIN_CLEAN=resumable`：上次收口在 sync 步骤中途被打断（marker 已写或 build-sync 已暂存，还没 commit），脏文件都属于 `RESUMABLE_LANES=` 里的 lane。照常继续：tick 会先给出 `post-merge`，§4 的 `postmerge` 会给出 `NEXT=sync`，重跑 build-sync 时这些改动会一起提交。告诉用户一行「接着上次中断的收口：<KEY>」。
4. `--dry-run`：执行 `SH plan` 和 `SH board`，把输出原样给用户，执行 `SH end-run`，然后退出。不 prepare，不 launch。
5. 给用户一行开场：sprint 分支、slot 数、就绪的 story 数（来自 `SH tick` 的 `launch` 和 `waiting`）。

上次运行留下的 lane 不需要特殊处理，`SH tick` 会从磁盘状态把它们读出来。

## 1. 主循环

每一轮都从下面这条命令开始：

```bash
python3 .claude/harness/scripts/superh.py tick
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

`orphaned` 非空时，里面的 lane 的 launch 进程已经没了，但 worker（claude 进程）还在跑，它退出时不会有通知。对其中每个 key，按「后台命令」的方式启动一次 `python3 .claude/harness/scripts/superh.py watch <KEY>`（不用加 `SUPERH_EXIT`）。worker 退出时 watch 跟着退出，你会被唤醒。已经有 watch 在跑的 lane 不会出现在 `orphaned` 里。不要对这些 lane 执行 retry，worker 还在它的 worktree 里工作。

每一轮都检查 `attention`。出现了新的条目（和你上次告诉用户的不同），就用一行告诉用户：key、阶段、detail、接手命令（`takeover` 字段）。然后继续循环，不要等用户回复。处理规则：

- `crashed`：worker 进程丢失，通常是上一个会话结束了。同一路第一次出现时自动执行 `SH retry <KEY>`，下一轮会重新 launch；worker 会按 harness-state 续作。第二次再出现就留给用户。retry 输出 `STATUS=halt`、说 worktree 里有没提交的半成品时，不要自己加 `--reset`，这一路留给用户，把 `REASON=` 和 `DIRTY=` 行转告用户。retry 输出里有 `ORPHAN_CONTAINER=` 行时同样转告。
- `blocked` / `failed` / `held` / `conflict`：留给用户，不自动重试。
- `quota`：tick 已经停止派发新 lane，`launch` 和 `queued` 都是空的（`quota_hold: true`）。等在跑的 lane 全部结束后，按 §8 halt。

## 2. 启动 lane

1. `queued` 里的 key（之前 prepare 过、或刚被 retry 的 lane）：直接执行第 3 步的 launch。
2. `launch` 里的每个 key，按顺序（其中可能有上次 prepare 中途被打断的 lane，`SH prepare` 会先清理现场再重做，输出里带 `ROLLED_BACK=`）：
   - 它所属的 epic 在 `epic_start` 里，说明这是该 epic 第一次有 story 启动。先在主 worktree 执行 P§0.A.0（retro DEV 项兑现 gate），通过之后再继续。同一个 epic 只做一次。
   - 按「后台命令」的方式运行 `SH prepare <KEY>`（`command` 写成 `python3 .claude/harness/scripts/superh.py prepare <KEY> 2>&1; echo "SUPERH_EXIT=$?"`），收到通知、读完输出再处理下一个 key。一次只跑一个 prepare。
     - `SUPERH_EXIT=0`（`STATUS=ok`）：对这个 key 执行第 3 步的 launch。
     - `SUPERH_EXIT=1`（`STATUS=halt`）：把输出贴给用户，跳过这个 key，继续下一个。lane 已记为 held（输出里有 `HOLD_KIND=`），会出现在 attention 里，tick 不会再把它分派出来。
     - `SUPERH_EXIT=4`、`STATUS=busy`：这一路已经有一个 prepare 在运行（例如上一个会话启动的），不要动它，继续下一个。
3. launch 用 Bash 的后台模式运行，每个 key 单独调用一次：
   ```
   Bash({
     command: "python3 .claude/harness/scripts/superh.py launch <KEY>",
     description: "Run super-harness worker for <KEY>",
     run_in_background: true
   })
   ```
   worker 跑完时你会收到通知。读这条命令的输出，有 `ORPHAN_CONTAINER=` 行时，把容器 id 和名字转告用户：worker 退出后还挂载着这一路 worktree 的容器，多半是子 agent 起的、没人管了。不要自己停，由用户确认。
4. 回到 §1。

## 3. 合流

按「后台命令」的方式运行（`verify_command` 可能要跑几十分钟），收到通知后按最后一行的 `SUPERH_EXIT=` 分支：

```
python3 .claude/harness/scripts/superh.py integrate <KEY> 2>&1; echo "SUPERH_EXIT=$?"
```

脚本会把 lane 分支 rebase 到 sprint 分支最新提交上，自动消解账本类冲突（`sprint-status.yaml` 和 `epic-N-context.md` 取 sprint 分支版本，`deferred-work.md` 做 union 合并），把 `harness/<KEY>/{start,built,followup-start,followup}` 这几个 tag 搬到 rebase 之后的提交上，在 lane worktree 里重跑 `build-verify`。`parallel.yaml` 配了 `verify_command`、并且这一路确实被 rebase 过时，接着在 lane worktree 里跑它（输出 `VERIFY=passed|failed|skipped-unset|skipped-not-rebased`）。都通过后 ff 合并进主 worktree。

输出里有 `NOTE=上次 integrate 在运行中被打断` 时，说明上一次合流被杀掉了（会话结束等），这次从断点继续，不用处理。同一路被打断超过 2 次，脚本会把它挂起（`HOLD_KIND=interrupted`），不会无限重跑。

- 退出码 0：记下输出里的 `CODEX_SKIP_REASON=`、`FOLLOWUP_NOTE=`，以及 `BUILD_VERIFY<<` 段里的 `BASELINE_REVISION=`，进入 §4。输出里有 `RECOVERED=already-merged` 时，说明上一次合流已经 ff 成功、只是没记下来，照样进入 §4；有 `WARN=` 行时把它转告用户。
- 退出码 3（`STATUS=conflict`）：派一个合流冲突子 agent。
  1. Read `.claude/harness/prompts/merge-fix.md`，替换占位符：`{{KEY}}`；`{{WORKTREE}}` 取输出的 `WORKTREE=`；`{{CONFLICT_FILES}}` 取所有 `CONFLICT_FILE=` 行，用顿号连接；`{{SPEC}}` 取 `cd <WORKTREE> && python3 .claude/harness/scripts/harness-state.py <KEY> --story-md` 的输出，失败就留空。
  2. 用前台 Agent 运行（`subagent_type: "general-purpose"`，`description: "Resolve merge conflict <KEY>"`，显式传 `run_in_background: false`，不传可能会放到后台）。
  3. 返回的第一行是 `NEEDS_PERSON:` 时，把原因告诉用户，这一路留在 conflict 状态，回到 §1。
  4. 否则按同样的后台方式重跑 `SH integrate <KEY>`。退出码 0 进入 §4；再次返回 3 时不再派第二个子 agent，告诉用户，回到 §1。
- 退出码 4：`STATUS=busy` 表示这一路已经有一个 integrate 在运行，不要动它，回到 §1；`STATUS=locked` 按 §8 全局 halt。
- 退出码 1，按下面的顺序判断：
  1. `REASON` 说的是主 worktree 不干净或不在 sprint 分支：全局 halt（§8）。这一路保持原状。
  2. 输出里有 `HOLD_KIND=`：这一路已经记为 held，sprint 分支没有被改动，tick 会把它放进 `attention`，不会再送回合流。把 `REASON=` 贴给用户，`HOLD_KIND=verify` 时连同 `VERIFY_OUTPUT<<` 段、`build-verify` 时连同 `BUILD_VERIFY<<` 段一起贴。然后回到 §1，不要自己修，也不要自动重试。各种 `HOLD_KIND`：
     | HOLD_KIND | 含义 |
     |---|---|
     | `verify` | 合流后的代码没通过 `verify_command`（包括超时） |
     | `build-verify` | rebase 之后 build-verify 不通过 |
     | `lane-dirty` | lane worktree 里有未提交或未跟踪的文件（例如测试留下的 coverage 文件） |
     | `rebase` | rebase 没能启动、`rebase --continue` 失败，或推进步数超限 |
     | `branch-missing` / `worktree-missing` | lane 分支或 worktree 不在了 |
     | `interrupted` | integrate 连续被打断超过 2 次 |
     | `retry-limit` | sprint 分支在合流期间被改动，连续 3 次重试都没成功 |
     | `git-error` / `error` | git 命令或脚本本身出错 |

     用户按 `attention` 里的 `takeover` 处理好之后，重跑 `SH integrate <KEY>` 即可，integrate 接受这些原因挂起的 lane。
  3. 输出里有 `RETRYABLE=yes`：sprint 分支在合流期间被改动了，这一路仍是 integrating，sprint 分支没有被改动。回到 §1，下一轮 tick 会把它送回合流，重新 rebase。
  4. 以上都不是（`lane ... 不存在`、`当前阶段 ... 只有 worker 回报 ready 的 lane 能合流`）：KEY 写错了或这一路不该合流，把输出贴给用户，回到 §1。
- 退出码 128 以上（`REASON=被信号 N 中断`）：integrate 被杀掉了，回到 §1，tick 会把它送回合流。

## 4. 收口（主 worktree 串行执行）

收口的每一步都可能被打断（会话被关、配额耗尽），所以不要按固定顺序从头执行。每一步开始前先问脚本还差什么：

```bash
python3 .claude/harness/scripts/superh.py postmerge <KEY>
```

它只读，按磁盘上的事实（done tag、harness-state）给出 `NEXT=`。按 `NEXT` 做对应的一步，做完再执行一次 `postmerge`，直到 `NEXT=finish`：

| NEXT | 做什么 |
|---|---|
| `sync` | 1. `MARKER=write` 时，按 P§1 B2.1 a) 的格式写 `<KEY>.codex-skipped.json`：reason 取 `CODEX_SKIP_REASON=`，`BASE` 取 integrate 输出的 `BASELINE_REVISION`，没有就取 `git rev-parse harness/<KEY>/start`。`MARKER=present` 或 `none` 时不要写，也不要重写已有的 marker。<br>2. 按 P§1 B4 执行 `harness-commit.py build-sync <KEY>`：STATUS=ok 时 commit，然后立刻 `git tag harness/<KEY>/done`；STATUS=skip 时不 commit，但同样立刻打这个 tag（否则 `postmerge` 会一直停在 `sync`）。然后输出 deferred-work 趋势。`STATUS=halt` 时全局 halt（§8）：这时主 worktree 可能有已 stage 的改动，继续合流只会把问题叠上去。 |
| `tag` | build-sync 已经 commit，只差 tag：`git tag harness/<KEY>/done` |
| `finish` | `SH mark <KEY> --phase done`，然后 `SH cleanup <KEY>`。给用户一行进度：`<KEY> 已完成（M/N），在跑 <running 数> 路`；`FOLLOWUP_NOTE=` 非空时作为第二行附上 |
| `halt` | 全局 halt（§8），贴出 `REASON=` 和 `HARNESS_STATE_RAW=` |

不要在 `postmerge` 之外自己判断「这一步做过了没有」，也不要对已经存在的 tag 再执行 `git tag`。

epic retro 不在这里执行。epic 的最后一条 story 收口之后，下一轮 tick 会给出 `retro`。

## 5. Epic retro

对 `retro_due` 里的 epic `<N>`：

1. 先在主 worktree 跑 `git status --porcelain`，确认干净。
2. 按 P§1 阶段 ⑥ 的「retro 用的 `KEY`」规则取 `KEY`（该 epic 按 yaml 顺序最后一条 status=done 的 story），然后执行 P§1 阶段 ⑥、⑥.5 和 verdict 门。
3. verdict 是 `rejected` 并且 `EPIC_WONT_DO=none`、`EPIC_PARKED=none`：停止派发新 lane，等在跑的 lane 结束、合流、收口之后，按 P§1「verdict 门」的文案 halt。

retro 期间其他 lane 照常在各自的 worktree 里运行，不受影响。

## 6. 等待

没有可做的事时（`next_action = wait`），执行一次 `SH board`，把「进行中」那几行原样给用户，然后结束这一轮回复。

不要 sleep，不要轮询日志。任何一个后台命令（worker、prepare、integrate、watch）退出，你都会被唤醒；醒来后从 §1 继续。等待期间调度锁仍由本会话持有，不要执行 `end-run`。

## 7. 停滞

`next_action = stalled` 表示没有在跑的 lane，也没有可启动的 story，但 sprint 还没完成。执行 `SH board` 和 `SH plan`，把「需要你处理」的部分和等待原因原样给用户，执行 `SH end-run` 释放调度锁（否则用户在别的终端里执行下面这些命令会得到 `STATUS=locked`）。

接着对看板上每一路「受阻」「失败」「配额耗尽」的 lane，读 `.git/super-harness/lanes/<KEY>.result.json` 的 `halt` 字段，按 P§3 的写法给这一路写一段：原因一句话、需要的事实、P§3.1 对应那一行的 1 到 3 条建议，续跑命令写 `SH retry <KEY>` 再 `/super-harness:run`。spec 和改动在这一路的 worktree 里，要抄问题、列文件就去那里读，但不要在里面改东西；P§3.2 在调度模式下不适用，需要改 spec 的让用户自己改，或者用看板上的「接手」命令进那一路处理。合流冲突、已挂起、进程丢失的 lane 不用读 result，从下面的命令里挑对应那一行附上，用不到的行不要列。写完就结束：

```
处理完之后重新执行 /super-harness:run。
  接手某一路：        cd <worktree> && claude --resume <session>
  修完让 worker 续作：python3 .claude/harness/scripts/superh.py retry <KEY>
  worker 留下半成品：  python3 .claude/harness/scripts/superh.py retry <KEY> --reset（retry 提示时才用，会丢掉没提交的改动）
  合流冲突手工解决后：git add 解决好的文件，重新执行 /super-harness:run（会从 rebase 现场继续）
  合流挂起（held）的：按看板「接手」一行处理后，python3 .claude/harness/scripts/superh.py integrate <KEY>
  放弃某一路：        python3 .claude/harness/scripts/superh.py abandon <KEY> --yes
```

## 8. 全局 halt

以下情况停止整个调度：

| 情况 | 处理 |
|---|---|
| `check_bmad_runtime.sh` 失败 | 贴 `REMEDIATION=` 行 |
| tick 的 `problems` 非空，或 integrate 报主 worktree 不干净、不在 sprint 分支 | 贴原文 |
| §4 的 build-sync 等 `harness-commit.py` 退出码 1 | 按 P§3 的 halt 模板 |
| §4 的 `postmerge` 给出 `NEXT=halt`，或报 done tag 不在 sprint 分支上 | 贴脚本输出 |
| 配额耗尽（`quota_hold` 且没有在跑的 lane） | 按 P§3.1「配额耗尽」那一行写；恢复后执行 `SH retry <KEY>`，再重新执行本命令 |
| retro verdict 为 rejected | 按 P§1「verdict 门」 |
| 任何 `SH` 命令输出 `STATUS=locked` | 贴 `REASON=` 和 `HINT=`。锁属于另一个会话，不要执行 `end-run`，也不要自行 `--take-over` |

halt 时先执行一次 `SH board`，把输出贴在 halt 说明前面，让用户看到每一路停在哪里。接着执行 `SH end-run` 释放调度锁，但 `STATUS=locked` 和 §0 第 3 步之前就 halt 的情况除外（那时锁不属于本会话）。在跑的 worker 不用停，它们结束后状态会落盘，下次执行 `/super-harness:run` 时会接着处理。

## 9. 完成

1. 执行 `SH board`，贴出结果。
2. 执行 P§2 收尾提醒（codex-skipped 通知框 + report-issue 提示）。
3. 执行 `SH end-run` 释放调度锁。
4. 一行总结：完成的 story 数、跑过 retro 的 epic。

## 参数

| 参数 | 含义 |
|---|---|
| 无 | 按 `.claude/harness/parallel.yaml` 的 `max_slots` 跑完所有能跑的 story |
| `--slots <N>` | 本次运行改用 N 路并发（写进 `.git/super-harness/run.json`，下次不带参数时恢复成 `parallel.yaml` 的值） |
| `--dry-run` | 只打印就绪分析和看板 |

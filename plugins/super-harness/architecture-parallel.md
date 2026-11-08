# super-harness 并行调度架构

本文讲 `/super-harness:run` 的多路并行调度。单条 story 的流水线写在 [pipeline.md](pipeline.md)，harness 整体设计（部署模型、状态机、retro 闭环、config 提取）在 [architecture.md](architecture.md)。

`/super-harness:run-inline` 一次推进一条 story；`/super-harness:run` 让几条互不依赖的 story 同时推进，每条 story 内部走的是同一份 pipeline.md。0.1.0 时调度层单独成一个 plugin、依赖项目里装好的 harness-zh；0.2.0 起 harness-zh 并入，本文按合并后的结构写。

带图的版本见 [docs/architecture.html](docs/architecture.html)（单文件，浏览器直接打开）。

设计思路来自 [deepseek-ai/dsh-superagent-prototype](https://github.com/deepseek-ai/dsh-superagent-prototype)，主要参考它的 `docs/001-domain.md` 和 `docs/003-execution.md`。

## 1. 借鉴了什么

| superagent | super-harness |
|---|---|
| Ticket：一份已授权的工作 | lane：一条 story 的一次并行执行 |
| 每个 Ticket 一个 Executor Session、一个目录，目录通常由 prepare 命令用 `git worktree` 准备 | 每条 story 一个 worktree（分支 `story/<KEY>`）加一个 headless `claude -p` 进程 |
| 主 Session 只评估和派工，自己不干活 | `/super-harness:run` 的主 agent 只做调度、合流和收口 |
| worker slot 数量固定，满了就排队 | `max_slots`，prepared 和 running 的 lane 都占 slot |
| Engine 是领域状态的唯一写入者 | 共享账本（sprint-status、deferred-work、`done` tag）只在主 worktree 里串行写 |
| Ticket 的阶段由存储的事实推导，按表从上到下取第一条匹配 | lane 阶段由 `lane.json`、`proc.json`、`result.json` 推导（§4.2） |
| 面板只显示需要人处理的事 | `/super-harness:board` 先列需要人处理的 lane，健康的 lane 只占一行 |
| 一个 Ticket 受阻不影响其他 Ticket | 单路 blocked / failed / conflict 只停这一路 |
| 人可以直接在 Executor Session 里接着做 | `cd <worktree> && claude --resume <session>` |
| 重启后从存储恢复，进程丢失的 Assignment 带恢复说明重启 | 状态落在 `.git/super-harness/`；进程丢失的 lane 自动 retry 一次，worker 按 harness-state 续作 |

没有照搬的部分：Source、Eval、Mandate、Subscription 这套事件和授权模型。super-harness 的工作来源只有 sprint-status.yaml，授权就是用户执行了 `/super-harness:run`。

## 2. 三个角色

```
                 调度者（主 worktree，/super-harness:run 的主 agent）
   tick → 有空 slot 就 prepare + 后台 launch → 无事可做就结束本轮，等 worker 退出通知
        │                         │
        ▼                         ▼
  worker（wt/3-2，claude -p）  worker（wt/3-4，claude -p）
  按 pipeline.md lane 模式      B0 start tag → B1 bmad-build-auto → build-verify
  B0-B3，最后 superh report      → B2 codex（按需）→ B3 follow-up（按需）
        │                         │
        └────────────┬────────────┘
                     ▼
            合流（调度者，串行）
   superh integrate：rebase 到 sprint 分支 → 账本冲突自动消解 → 搬 tag
                     → lane 内 build-verify → verify_command（按需）→ ff 合并
   代码冲突 → 合流冲突子 agent（prompts/merge-fix.md）→ 修不了就留给人
                     ▼
            收口（调度者，串行，主 worktree）
   B4 build-sync → done tag → cleanup
   epic 全部 done → ⑥ retro / ⑥.5
```

- 调度者：主 agent。所有确定性的判断都交给 `scripts/superh.py`，主 agent 只读 `tick` 的 JSON 做分派。
- worker：一个独立的 Claude Code 进程，工作目录是自己的 worktree。它读 `.claude/harness/pipeline.md`，按其中的 lane 模式执行 B0-B3。`prompts/worker.md` 只给出 key、分支、回报命令这些运行参数。
- 合流冲突子 agent：只在 rebase 遇到代码冲突时由调度者派出，在 lane worktree 里解决冲突并跑验证命令。

## 3. 为什么 worker 用独立进程

做过两种方案的对比：

| | Agent 工具后台运行 + `isolation: worktree` | 独立 `claude -p` 进程 |
|---|---|---|
| 工作目录 | 分支名、清理时机不受控 | 进程 cwd 就是 lane worktree，bmad-build-auto 的相对路径、`uv run`、`.claude/skills` 都能原样工作 |
| 嵌套深度 | 在调度者之下再嵌套，bmad-build-auto 自己还要起两层子 agent | 每个 worker 的嵌套深度从 0 算起 |
| 人工接手 | 不行 | `claude --resume <session>` |
| 上下文 | worker 的输出回流到调度者 | 调度者只读 `result.json` |

launch 时会清掉从调度者会话继承来的 `CLAUDECODE`、`CLAUDE_CODE_SESSION*`、`CLAUDE_CODE_MESSAGING*` 等环境变量，让 worker 成为一个全新的会话。输出用 `stream-json`，session id 从第一条 init 事件里取（实测 `--session-id` 传进去的值和实际 session 不一致，所以不预先指定）。

调度者用 Bash 的 `run_in_background` 启动 `superh.py launch`，这个包装进程一直等到 claude 退出才落盘退出码并结束。Claude Code 在后台命令退出时会唤醒调度者，所以调度者不需要轮询。代价是调度者的会话结束时，后台进程也会一起结束；下次运行时这些 lane 显示为 `crashed`，自动 retry 一次。

## 4. 状态

### 4.1 存放位置和写入者

全部放在 `$(git rev-parse --git-common-dir)/super-harness/`，不进 git，所有 worktree 看到的是同一份。除了 `decisions.json`，每个文件只有一个写入者，避免并发写坏：

| 文件 | 写入者 | 内容 |
|---|---|---|
| `run.json` | 调度者（`start-run`） | 本次运行固定的 sprint 分支、`--slots` 覆盖值 |
| `dispatcher.lock` | 调度者（`start-run` 取得，`end-run` 释放） | 持有调度权的会话：pid 和进程启动时间。见 §4.3 |
| `lanes/<KEY>.json` | 调度者（prepare / integrate / mark / retry / cleanup / abandon） | phase、分支、worktree、rebase 的 onto、要搬的 tag、自动消解记录；prepare / integrate 进行中的标记（pid、启动时间、子进程组）和被打断的次数；held 时的 `hold_kind` / `hold_reason` |
| `lanes/<KEY>.proc.json` | `launch` 包装进程 | pid、session id、attempt、退出码、最后的 result 文本、花费、worker 实际用的模型（stream 的 init 事件）、没带 harness 后缀的派发（`suffix_missing`） |
| `lanes/<KEY>.result.json` | worker（`superh report`） | status、summary、codex 跳过原因、follow-up 提示、halt 原文 |
| `logs/<KEY>.attempt-N.*` | `launch` | 渲染后的 prompt、stream-json 全量日志、stderr |
| `lanes/<KEY>.reopen.json` | worker（`superh reopen`） | 本 story 自己重开 spec 的次数（按推荐项代答最多 2 次，验证超时重跑 1 次） |
| `lanes/<KEY>.notes.json` | `reopen` / `resume` / `override` | 还没有 spec 时的答复，下一次渲染 worker prompt 时带进 B1 intent |
| `decisions.json` | worker（`reopen`）、调度者（`decide`、`resume`）、`launch` / `integrate`（漏后缀的派发、spec 里的待确认项）、用户（`confirm`、`override`） | 决策收件箱。这是唯一一个多写入者的文件，所有写入都在同一把 flock 下做完整的读改写。`kind`：`decision`（reopen 代答）、`dispatcher`、`audit`（漏后缀）、`spec`（worker 写在 spec `### 待用户确认` 段的取舍，带 `spec_ref` 和可选的 `merged_into`；`options` 只放没采用的备选，其他 kind 的 `options` 含采用项） |
| `resources.json` | `launch`（acquire）、`mark done` / `abandon` / `end-run --finished`（release），经 flock | 已经执行过 `resource_acquire`、还没 release 的资源 |
| `post_epic.json` | `post-epic` | 等 lane 停下再执行的 epic（`pending`）和已执行过的 epic（`done`） |
| `suffix/<stage>-<hash>.md` | `harness-prompt-suffix.py --file` | 子 agent prompt 后缀全文，按内容 hash 命名，所有 worktree 共用 |

流水线自己的状态源（`harness/<KEY>/*` tag、spec frontmatter、sprint-status.yaml）保持不变。tag 是仓库级的，任何 worktree 里打的 tag 主 worktree 都能看到。

### 4.2 lane 阶段

按下表从上到下，取第一条匹配：

| 阶段 | 条件 | 需要人 |
|---|---|---|
| done / abandoned | phase 为 done / abandoned | |
| conflict | phase = conflict（rebase 停在代码冲突上） | 是 |
| preparing / integrating（进行中） | lane 上有 prepare 或 integrate 的进行中标记，且记录的进程还活着（pid 和启动时间都对得上） | |
| held | phase = held。`hold_kind` 说明原因：`prepare`、`env`（worker 启动前环境没起来）、`resource`（`resource_acquire` 失败）、`verify-env`、`build-verify`、`verify`、`lane-dirty`、`rebase`、`branch-missing`、`worktree-missing`、`foreign`（分支或目录不是 superh 建的）、`interrupted`（prepare / integrate 被杀超过 2 次）、`retry-limit`、`git-error`、`error` | 是 |
| integrating | phase 为 integrating / merged | |
| queued | phase 为 prepared，或 preparing 但进程已不在（prepare 被打断，待重做），或这一次 attempt 还没有 proc 记录 | |
| working | proc 没有退出码，launch 进程或 claude 子进程有一个还活着（pid 和启动时间都对得上，防止 pid 被复用后误判） | |
| crashed | proc 没有退出码，两个进程都已不在，worker 也没有回报 | 是（第一次自动 retry） |
| failed | 退出了，但没有本次 attempt 的 result | 是 |
| ready / blocked / failed / quota | 按 result.status | blocked / failed / quota 需要人 |

`tick` 的 `next_action` 优先级：post-merge（已合入未收口）> integrate > retro > post-epic > launch > wait > finished / stalled。有 epic 在等 `post_epic_command`（`post_epic` 非空）时不再派发新 worker，等在跑的 lane 都停下才给出 `post-epic`。合流排在启动前面，是为了让依赖它的 story 尽早变成就绪。有 integrate 正在进行时，tick 不再给出别的 integrate、post-merge 或 retro。`quota_hold` 时 launch 和 queued 都不再派发。tick 的 JSON 另有 `preparing`、`integrating`（进行中的 key）和 `orphaned`（launch 进程已退出、claude 子进程还在跑的 key；调度者对它们执行 `superh.py watch <KEY>`，子进程退出时会被唤醒）。

### 4.3 调度锁

同一个仓库同一时间只能有一个会话调度。两个会话同时调度会互相把对方正在 prepare 的 lane 当成中断现场清掉，也会同时对同一路执行 integrate。`start-run` 在状态目录里取 `dispatcher.lock`，记下持锁会话的 pid 和启动时间；prepare、integrate、launch、retry 等会改状态的子命令在锁属于另一个仍然活着的会话时退出码 4，输出 `STATUS=locked`。持锁进程已经不在时，下一次 `start-run` 直接收回（`LOCK_RECLAIMED=stale`）。用户确认原会话不再调度后，可以用 `start-run --take-over` 接手。正常结束、halt、stalled 时调度者执行 `end-run` 释放。

## 5. 就绪判定

一条 story 能启动，需要同时满足：

1. sprint-status 里是 `backlog`，没有活着的 lane，也没有「有 start tag、没有 done tag」的残留（那是 run-inline 跑到一半的 story，并行调度不接手，用 `/super-harness:run-inline --continue` 收尾）。
2. epic 屏障（`epic_barrier: true`，默认）：编号更小的 epic 里所有 story 都已终态（done / wont-do / cancelled）或挂起（`parked_statuses`）；`retro_barrier: true` 时，这些 epic 的 retrospective 也要是 done。`epic_barrier: false` 时这一条整个跳过，只按依赖调度。
3. 依赖，按优先级取第一处有声明的：
   - `parallel.yaml` 的 `deps_overrides`；
   - sprint-status 顶层的 `story_dependencies`（值的写法和 `deps_overrides` 一样）；
   - `development_status` 多行块里的 `depends_on`。super-harness 读得懂这种写法，但 BMad 6.12.4 自己的 `sprint_plan.py` 和 retrospective 的 `detect-epic` 都处理不了（issue #14），所以 6.12 的项目把依赖写在 `story_dependencies`；
   - 依赖项可以写 story key、短号（`3.2` / `3-2`）或 `epic-N`。`ext-` 开头的是外部条件，永远不满足，story 一直等待，tick 的 `external` 和 board 单独列出，条件满足后由人从依赖里删掉。依赖一个挂起的 story 时照样等待，挂起不算完成；
   - 三处都没有：`no_deps_policy: serial` 时依赖它前面所有未终态、未挂起的 story，效果和 run-inline 一样一次一条；`epic-parallel` 时同 epic 内视为独立。
   - 依赖只有在**已经合入并 build-sync 为 done** 之后才算满足，所以下游 story 开 worktree 时一定能看到上游的代码。

`[]` 表示明确声明为独立，在 serial 策略下也能并行。

4. 独占资源（`parallel.yaml` 的 `resources`，0.5.0，issue #22）：story 声明的资源正被另一路占着时等待（plan 写「等待资源 X（KEY 正在用）」）。一路从 prepare 起占着它声明的资源，直到合入 sprint 分支或 abandon，停下等人的也继续占着，免得 retry 之后和别的 lane 撞上。同一轮 tick 里两条就绪 story 声明了同一资源时，只派前一条。`deps_overrides` 只能定死先后顺序，资源互斥不规定谁先谁后。

状态在 `parked_statuses` 里的 story 在 plan 里显示为「挂起」，不派发；tick 的 `parked` 列出它们，`pending_count` 不算它们，只剩挂起 story 时 tick 给出 `finished`。retro 在一个 epic 的 story 全部终态或挂起、并且至少有一条 done 时触发；全是挂起的 epic 不触发。

run-inline 的 `sprint-status.py next` 用同一套依赖来源（复用 `superh.py` 的解析），按文件顺序取第一条依赖已满足的 backlog，没有声明依赖的 story 不受影响。

## 6. lane worktree 的准备

1. `git worktree add -b story/<KEY> <worktree_root>/<KEY> <sprint 分支 HEAD>`。worktree 默认放在仓库外面（`<仓库名>.worktrees/`），避免出现在主 worktree 的 `git status` 里。
2. 主 worktree 里存在、但没进 git 的基建路径（`copy_paths`）复制进去，已经在 worktree 里的不动。`.claude/harness` 必须复制不能软链：其中的脚本用 `Path(__file__).resolve().parents[3]` 推算仓库根目录，软链会被解析回主 worktree，导致 worker 读写主 worktree 的文件。
3. 体积大的只读目录可以放进 `link_paths` 软链。
4. 复制或软链进来的路径必须被项目 `.gitignore` 忽略，否则 worktree 一开始就是脏的，bmad-build-auto 会拒绝启动。没被忽略时 prepare 直接失败，输出应该加进 `.gitignore` 的行（`GITIGNORE=/<路径>`），lane 记为 held。super-harness 不自己改 `.git/info/exclude`：这个文件所有 worktree 共用，为 lane 加的规则会让主 worktree 里同一路径下用户自己的文件也从 `git status` 里消失。软链要用不带结尾斜杠的规则（`/node_modules`），`node_modules/` 匹配不到软链。`superh.py doctor` 可以在开 lane 之前做这项检查，init 会调用它。
5. 执行 `prepare_command`（例如安装依赖），最后确认 worktree 干净。命令在独立的进程组里运行，超过 `prepare_timeout_sec` 时整个进程组先收到 SIGTERM，3 秒后 SIGKILL，不会留下还在跑的安装进程。

`.claude/harness/.backup/`（update 的备份）和 `__pycache__` 不会复制进 lane。

调度者用 Bash 的后台模式执行 prepare 和 integrate，这两步跑多久都不会被 Bash 工具的超时杀掉。万一还是被杀（例如会话被关），lane 上留着进行中标记：下次执行时先结束上次留下的进程组，再重做，被打断的次数加一；超过 2 次就把这一路记为 held（`hold_kind: interrupted`，prepare 阶段为 `prepare`），不再无限重试。进程还活着的 prepare 不会被当成中断现场清掉。

## 7. 合流

### 7.1 为什么用 rebase + ff

流水线的很多地方假定每条 story 的提交在一段连续区间里：`build-verify` 审计 `start..HEAD`，`codex-catchup` 用 `start..done` 作为 review 窗口，`git log start..done` 是 story 的完整提交序列。如果用 merge commit 合流，几条 story 交替合入后，这些区间里会混进别的 story 的提交。

所以合流时把 lane 分支 rebase 到 sprint 分支最新提交上，再 ff 合并。sprint 分支保持线性，每条 story 的提交仍然连成一段，流水线的所有区间语义不变。

### 7.2 tag 搬迁

rebase 会改写提交，lane 里已经打好的 `built`、`followup-start`、`followup` tag 会指向旧提交。integrate 在 rebase 之前给这些 tag 各建一个临时分支，用 `git rebase --update-refs` 让 git 在改写时同步移动这些分支，rebase 结束后把 tag 改指到新位置，删掉临时分支。`start` tag 改指到 rebase 的 onto 提交。这一步需要 git ≥ 2.38。

### 7.3 账本冲突

`build-verify` 允许 bmad-build-auto 在自己的提交里改 `sprint-status.yaml`、`deferred-work.md` 和 `epic-<N>-context.md`，所以几路并行时这三个文件几乎一定会冲突。规则如下（rebase 期间 ours 是 sprint 分支，theirs 是 story 的提交）：

| 文件（仅限 artifacts 目录下一层） | 处理 | 理由 |
|---|---|---|
| `sprint-status.yaml` | 取 sprint 分支版本 | 本 story 的状态由紧接着的 build-sync 写成 done；sprint 分支上别的 story 的 done 不能丢 |
| `epic-<N>-context.md` | 取 sprint 分支版本 | bmad-build 编译出的缓存，下次 build 会重新生成 |
| `deferred-work.md` | 三方 union 合并 | 追加型账本，两边新增的条目都要留 |

其他文件的冲突一律交给合流冲突子 agent，修不了就留在 conflict 状态等人。rebase 期间禁用 hooks（`core.hooksPath=/dev/null`）：被重放的提交在 lane 里提交时已经过了一遍 pre-commit。

### 7.4 中断后重跑

integrate 的每一步都能重跑，后面步骤依赖的信息都在可能被打断的步骤之前落盘：

- 新的起点 `onto` 和 `integrating` 状态在移动任何 tag、执行 ff 之前写入 lane。没有发生 rebase 时，`onto` 取 lane 分支和 sprint 分支的 merge-base，只记一次，重跑不会重新计算。
- `harness/<KEY>/start` 只在真的 rebase 过时才移动。
- lane 的 HEAD 已经包含在 sprint 分支里，说明上一次已经 ff 成功、只是没来得及记录。这时只补记 `merged`，不动任何 tag。

如果用当前的 sprint HEAD 现算起点，ff 之后它就是这条 story 自己的最后一个提交，start tag 一旦被移过去，`start..HEAD` 就成了空区间。

### 7.5 合并前再验一次

rebase 完成后、ff 之前，在 lane worktree 里重跑一次 `harness-commit.py build-verify`。冲突解决可能引入越界改动，这一步把它挡在 sprint 分支外面。不通过时 lane 记为 held，sprint 分支不动。

build-verify 只审计提交区间，不跑测试。两条 lane 各自在 B1 里测试通过，合在一起仍可能出问题，所以 build-verify 通过后还有一道合流验证门：`parallel.yaml` 配了 `verify_command` 时，integrate 在 lane worktree 里用 `sh -c` 跑它（超时取 `verify_timeout_sec`，默认 1800 秒；环境变量 `SUPERH_KEY`、`SUPERH_WORKTREE`、`SUPERH_MAIN_ROOT`）。这时 lane 的树就是 ff 之后 sprint 分支的树。

- 只在这一路确实被 rebase 到更新的 sprint 提交上时才跑。没 rebase 的 lane 树没变，B1 已经测过。
- 输出 `VERIFY=passed|failed|skipped-unset|skipped-not-rebased`。
- 超过 `verify_timeout_sec` 时结束整个进程组（SIGTERM，3 秒后 SIGKILL），算作验证失败，测试进程不会在 lane worktree 里继续跑。
- 失败时 lane 记为 held，sprint 分支不动。在 lane worktree 里修好并 commit，再跑 `superh.py integrate <KEY>`。integrate 接受因验证失败而 held 的 lane，重新走 build-verify 和验证。

inline 模式没有这道门：B1 就在 sprint 分支那棵树上跑，测试已经覆盖。

### 7.6 rebase 之后的 hash 对应

rebase 改写了 lane 的每个提交，spec 里 follow-up、codex 处理记录引用的 hash，以及 codex 报告 frontmatter 的 `head:`，指向的都是 lane 里的旧提交，合流后不在任何分支上（issue #25）。integrate 在第一次 rebase 前记下 lane 的原始 HEAD（`orig_head`），rebase 后按作者、作者时间和提交说明把 `base..orig_head` 的旧提交和 `onto..HEAD` 的新提交配对。rebase 不改这三项；patch-id 在重放到新基线后经常对不上（上下文变了、解过冲突），所以不用它。

配对结果记在 lane 的 `rewrites`，输出 `REWRITTEN=<旧> → <新>`，并在合流验证通过后、ff 之前往 lane 里追加一个提交：spec 末尾加一张对应表（`### 合流 rebase 后的提交对应`），codex 报告 frontmatter 在 `head:` 后面加 `head_rebased:`。原文不改。这个提交被 hook 拒绝时只留 `WARN=`，不挡合流。spec 的 `baseline_revision` 是 lane 内提交时，integrate 另外输出 `BASELINE_REVISION_REBASED=`，B4 写 codex-skipped marker 时用它。

## 8. 收口

ff 之后，调度者在主 worktree 里按 pipeline.md 的调度模式执行 B4 第 0 步（codex-skipped marker）、B4 build-sync，然后 `mark done` 和 `cleanup`。epic 的最后一条 story 收口后，下一轮 tick 给出 `retro`，按 pipeline.md 的阶段 ⑥ / ⑥.5 / verdict 门执行。

这几步都要写共享账本，所以全部串行。`parallel.yaml` 配了 `lane_cleanup_command` 时，`cleanup` 和 `abandon` 在删 worktree 之前执行它（环境变量带 `SUPERH_KEY`、`SUPERH_WORKTREE`、`SUPERH_BRANCH`），用来回收这一路在共享缓存里的产物；`post_epic_command` 由调度者在 epic retro 之后用 `superh.py post-epic <N>` 执行，有 lane 在跑时推迟到它们都停下（issue #26）。两者失败都只告警。0.3.0 之前这里还有 ⑤.5 测试阶段（已移除），基本测试改由 B1 和 §7.5 的合流验证门负责。

收口的任何一步都可能被打断，所以调度者不按固定顺序执行，而是每步之前跑一次只读的 `superh.py postmerge <KEY>`，由它根据磁盘上的事实给出下一步：

| 事实 | NEXT |
|---|---|
| done tag 不存在，harness-state 为 `sync`（或为 `codex` 且 marker 还没写） | `sync`：按需写 marker，build-sync，commit，打 done tag |
| done tag 不存在，harness-state 为 `tag-only`（build-sync 已 commit） | `tag` |
| done tag 存在 | `finish` |
| 其他 | `halt` |

marker 只在文件不存在时写，避免重跑时 `skipped_at` 变化把文件弄脏、再被 build-sync 当成新改动提交。build-sync 返回 skip 时照样打 done tag，否则会一直停在 `sync`。

## 9. 失败与恢复

| 情况 | 结果 | 恢复 |
|---|---|---|
| bmad-build-auto 停在 intent gap 这类有推荐读法的问题上 | 不停。worker 按 answer-policy 选推荐项，`superh reopen` 写进 spec、commit、续跑，决定进收件箱（`decision_mode: proceed`，默认） | 用户批量 `confirm`；不同意就 `override <ID> --answer`：没合入的 lane 回退到决定之前的提交（`reopen` 会把停下时的 spec 单独 commit 一次，回退点就是它），换上新答复重新排队；已合入的只记录 |
| worker 报 blocked / failed | 只停这一路。`blocked_policy: continue` 时它不再挡串行顺序、epic 屏障和 retro 屏障 | 要回答问题的用 `superh resume <KEY> --note`（写进 spec、改 status、commit、挪 `followup-start`、重新排队）；其他的接手 session 修好后 `superh retry <KEY>`，worker 按 harness-state 续作 |
| `resource_acquire` 失败 | 记为 held（`resource`），worker 不启动 | 把资源准备好后 `superh retry <KEY>` |
| worker 派 B1 / B2.3 / B3 时没带 harness 后缀 | launch 输出 `PROMPT_SUFFIX_MISSING=`，记一条 `audit` 进收件箱，这一路照常合流 | 用户看 spec 里那一步的记录，需要时开复审 chore |
| 环境没起（配了 `env_check_command`） | launch 前、verify_command 前先执行 `env_up_command`；还不行记为 held（`env` / `verify-env`），worker 不启动、sprint 分支不动 | 把环境起好后 `superh retry <KEY>`（`env`）或 `superh integrate <KEY>`（`verify-env`） |
| worker 退出但没有回报 | failed | 看 `logs/<KEY>.attempt-N.stream.jsonl`，然后同上 |
| worker 把子 agent 或命令放到后台后结束了本轮 | failed，DETAIL 写明是后台任务被一起结束；worktree 可能留有没提交的半成品 | `superh retry <KEY>`。lane 没有 commit 也没有 spec、工作区却不干净时，retry 会拒绝并列出 `DIRTY=`，确认不要后用 `retry <KEY> --reset` 恢复到 start tag |
| worker 退出后还有容器挂载着 lane worktree | launch 和 retry 输出 `ORPHAN_CONTAINER=` | 确认是子 agent 留下的后 `docker stop <id>` |
| 调度者会话结束 | 在跑的 worker 随之结束，显示为 crashed | 下次 `/super-harness:run` 自动 retry 一次 |
| 配额耗尽 | 不再派发新 lane，等在跑的结束后 halt | 额度恢复后 retry |
| 合流代码冲突 | conflict，rebase 现场保留在 lane worktree | 子 agent 处理；不行就人工解决冲突并 `git add`，再跑 `/super-harness:run`。tick 发现冲突文件都已解决，会把这一路送回 integrate，由它完成 `rebase --continue` |
| 合流过程中调度者被打断 | lane 停在 integrating，或 ff 已完成但状态没记下 | 下次 tick 把它送回 integrate：先结束上次留下的进程组，按 §7.4 续上。被打断超过 2 次记为 held（`interrupted`） |
| prepare 中途被打断（例如 `prepare_command` 运行时会话被关） | lane 停在 preparing | 进程还活着就显示为进行中，不动它。进程已不在时 tick 把它放回 launch 列表；prepare 先结束残留进程组，确认分支没有新提交、没有 harness tag，再清理现场重做；确认不了，或被打断超过 2 次，就记为 held |
| integrate 因 lane 自身的问题失败（lane worktree 不干净、rebase 无法继续、lane 分支或 worktree 不见了等） | held，`hold_kind` 说明原因，sprint 分支不动 | 按看板上的接手提示处理后重跑 `superh integrate <KEY>`。sprint 分支在合流途中被移动这类可重试的失败输出 `RETRYABLE=yes`，连续 3 次才记为 held |
| 另一个会话正在调度 | `STATUS=locked`，退出码 4 | 等那个会话结束；确认它不再调度后 `start-run --take-over`（§4.3） |
| launch 在两次落盘之间被打断 | phase=launched 但没有本次 attempt 的 proc 记录，显示为 queued | proc 记录写在启动 claude 之前，没有它就说明 worker 从没启动过；launch 直接重新启动 |
| 收口中途被打断 | lane 停在 merged | 下次 tick 进入 post-merge，`postmerge` 从第一个没完成的步骤继续（§8） |
| 收口在 sync 步骤里被打断（marker 已写或 build-sync 已暂存，未 commit） | 主 worktree 是脏的 | `start-run` 核对脏文件是否全部属于某个 merged、无 done tag 的 lane 的收口产物（sprint-status、deferred-work、该 lane 的 marker）。是则报 `MAIN_CLEAN=resumable` 放行，重跑 build-sync 时一并提交；混进任何其他文件仍然 halt |
| 补进 lane 的文件没被 .gitignore 忽略 | prepare 失败，lane 记为 held | 按输出的 `GITIGNORE=` 行补 `.gitignore` 并提交，`abandon --yes` 后重新排队 |
| rebase 后 build-verify 不通过 | held，sprint 分支不动 | 在 lane 里修好并 commit，重跑 `superh integrate <KEY>`（0.3.1 起 integrate 接受这种 held 的 lane） |
| rebase 后 `verify_command` 不通过 | 超时先自动重跑 `verify_timeout_retries` 次；仍不通过 held，sprint 分支不动 | 在 lane worktree 里修好并 commit，重跑 `superh integrate <KEY>`（retry 会重启 worker，而 worker 看到状态已是 sync 会直接回报 ready，修不了测试） |
| build-sync halt | 全局 halt | 按 pipeline.md §3 halt 模板 |
| 放弃某一路 | `superh abandon <KEY> --yes`：删 worktree、分支，以及这条 story 没有 done 的 `harness/<KEY>/*` tag | story 回到 backlog，可以重新排队 |

## 10. 调度层依赖的流水线契约

`superh.py` 和调度手册依赖下面这些东西。它们现在和调度层在同一个 plugin 里，改动时一起改、一起跑 `superh_test.sh`：

- `pipeline.md`：worker 按 lane 模式、调度者按调度模式执行，两种模式的差异写在对应步骤上；
- `harness-commit.py build-verify` / `build-sync` 的 `STATUS=` 输出和退出码契约；
- `harness-state.py` 的续作路由（`next_action_code`）；
- `harness_config.get_artifacts_root()`、`harness_spec.TERMINAL_STORY_STATUSES`；
- `harness/<KEY>/{start,built,followup-start,followup,done}` tag 的语义。

配置在 `.claude/harness/parallel.yaml`，由 `deploy_assets.sh` 在缺失时投放（有 0.1.0 的 `.claude/super-harness/config.yaml` 就原样搬过来，否则用模板），之后不覆盖。只有旧配置时 `superh.py` 拒绝运行，避免静默用默认值。

## 11. 已知限制

- 依赖信息要靠 `deps_overrides`、`story_dependencies` 或 `depends_on`。都没有时默认串行，不会自动推断。
- 不预测文件级的冲突。两条声明为独立的 story 改到同一段代码时，要到合流时才发现。
- epic retro 串行执行；跨 epic 的并行受 retro 屏障限制，可以关掉 `retro_barrier`，但 pre-commit gate ① 仍会按 `retro_gate` 设置拦截。
- worker 默认用 `bypassPermissions` 无人值守运行。
- 调度者会话结束会带走在跑的 worker。
- 进程启动时间在 macOS 上用 `ps -o lstart=` 读取，这条路径只在 Linux 上实测过。
- `verify_command` 在合流队列里串行执行，跑多久合流就卡多久。全量测试很慢的项目，建议只放合流最容易打破的那部分（编译、类型检查、核心包的单测）。
- 合流验证门只看 `verify_command` 的退出码，不区分不稳定的测试和真失败。偶发失败时直接重跑 `superh.py integrate <KEY>` 即可。

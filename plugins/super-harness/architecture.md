# ${project_display_name} Harness 自动化架构

> **分发模型**：本 harness 原为 harness-zh plugin，0.2.0 起并入 super-harness，以 Claude Code plugin 形式分发（仓库 [`Niutie/my-cc-plugin`](https://github.com/Niutie/my-cc-plugin)）。每个项目通过 `/super-harness:init` 把 plugin 资产投递到 `.claude/harness/`；详 §〇「Plugin 分发模型」。原"clone harness 到新项目"机制（§十一）已由 plugin 自动化替代，§十一 保留作 yaml schema 与字段提取设计的动机记录。
>
> **占位符替换**：本文档读 [`harness-project-config.yaml`](harness-project-config.yaml)（部署到项目侧 `.claude/harness/` 的副本）解析 `${project_display_name}` 等占位符；新项目跑 `/super-harness:init` + BMad workflow 后该 yaml 自动填充。
>
> 本文档是 harness 元设计的**单一权威来源**——后续讨论"harness 自动化怎么走"先 reference 本文。单条 story 的执行手册是 [`pipeline.md`](pipeline.md)；多路并行调度的设计在 [`architecture-parallel.md`](architecture-parallel.md)。
>
> 文中保留的 harness-zh 版本号（v0.1.x / v0.2.x）指的是并入前 harness-zh 的版本，对应记录在 changelog「harness-zh 历史」一节。文中写 `run.md` 的地方，0.2.0 起对应 `pipeline.md`（单条 story 步骤）和 `commands/run-inline.md`（单路主循环）。

---

## 〇、Plugin 分发模型

### 〇.1 三层架构（marketplace → plugin store → project）

```
┌──────────────────────────────────────────────────────────────────┐
│            GitHub: Niutie/my-cc-plugin (private)                 │
│                                                                  │
│  .claude-plugin/marketplace.json  (列 plugin 清单)               │
│  README.md                                                       │
│  plugins/super-harness/                                          │
│    ├─ .claude-plugin/plugin.json                                 │
│    ├─ commands/   ← 8 个 .md（init / update / run / run-inline / │
│    │               board / upgrade-deferred-work /               │
│    │               report-issue / codex-catchup）                │
│    ├─ pipeline.md ← 单条 story 流水线手册                        │
│    ├─ scripts/    ← 运行时脚本（含 superh.py）+ *_test.sh        │
│    ├─ prompts/    ← worker / merge-fix prompt 模板               │
│    ├─ conventions/ + prompt-suffixes/                            │
│    ├─ git-hooks/pre-commit                                       │
│    ├─ templates/  ← harness-project-config.yaml.template +       │
│    │               deferred-work.md.template + parallel.yaml     │
│    └─ architecture*.md / answer-policy.md / changelog.md         │
└─────────────────────┬────────────────────────────────────────────┘
                      │ /plugin marketplace add https://github.com/Niutie/my-cc-plugin.git
                      │ /plugin install super-harness@my-cc-plugin
                      ▼
┌──────────────────────────────────────────────────────────────────┐
│ ~/.claude/plugins/<...>/super-harness/ (Claude Code plugin store)│
└─────────────────────┬────────────────────────────────────────────┘
                      │ /super-harness:init  (一次/项目)
                      │ /super-harness:update  (plugin 升级后)
                      ▼
┌──────────────────────────────────────────────────────────────────┐
│                       <user-project>/                            │
│  .claude/harness/                                                │
│    ├─ pipeline.md ← run-inline / run / worker 都读它             │
│    ├─ scripts/ + prompts/ + conventions/ + prompt-suffixes/ ...  │
│    ├─ git-hooks/pre-commit                                       │
│    ├─ harness-project-config.yaml ← 项目特定，update 不覆盖     │
│    ├─ parallel.yaml ← 并行调度配置，update 不覆盖                │
│    └─ architecture*.md / answer-policy.md / changelog.md         │
│  （命令由 plugin 直接提供，不复制进 .claude/commands/）          │
│  .git/hooks/pre-commit ← install_git_hooks.sh 装                 │
│  .git/super-harness/   ← 并行调度的 lane 状态（不进 git）        │
│  _bmad-output/  (用户跑 BMad workflow 后产出，harness 读)        │
└──────────────────────────────────────────────────────────────────┘
```

### 〇.2 为什么是 asset deployer 而不是 runtime container

理论上 plugin 可以让 commands 直接通过 `${CLAUDE_PLUGIN_ROOT}` 引用 plugin 内资产，runtime 无需项目副本。**但实际撞两堵墙**：

1. **Git pre-commit hook** 在 git 上下文跑（非 Claude Code），`${CLAUDE_PLUGIN_ROOT}` 不可用 → hook 必须用 project-relative 路径
2. **Markdown slash-command bash 块** 在 commands 上下文（per [Anthropic plugins docs](https://code.claude.com/docs/en/plugins.md)）**不保证**注入 `${CLAUDE_PLUGIN_ROOT}` —— 该变量明确文档化于 hooks 上下文，commands 上下文未提及

所以 harness 走"plugin = 源；project = 部署副本"模式：
- Plugin 是 source of truth（marketplace 唯一升级路径）
- Project 是 deployed copy（runtime 实际操作的对象）
- Sync 通过 `/super-harness:update`（cmp + backup + overwrite，不丢用户本地修改）

代价：每个项目带一份资产副本（增加少量磁盘占用）；好处：所有现有路径引用（`.claude/harness/scripts/...` 等）零改动可用，git hook + markdown command bash 都跑得了。

部署副本只包括 `.claude/harness/` 下的资产。命令文件本身不复制：它们由 plugin 以 `/super-harness:*` 提供，运行时要读的手册（`pipeline.md`）、prompt 模板放在 `.claude/harness/` 里。harness-zh 时代会把命令复制到 `.claude/commands/`，0.2.0 起由 manifest purge 清掉。

### 〇.3 命令分工

| 命令 | 职责 | 何时跑 |
|---|---|---|
| `/super-harness:init` | 首次 bootstrap — mkdir 项目目录 → 探测 plugin path → cmp/backup/overwrite copy 资产 → 投放 yaml template（仅当不存在）→ 装 git hooks → 检测 BMad → 齐则进 §十一 字段提取（14 个，另有 2 个已在 0.3.0 退役）/ 缺则报告引导。**v0.1.13+** 半路接入项目时还检测 `deferred-work.md` schema state（§A.3.c 三档分支）；**v0.1.26+** §A.3.d 改为纯 advisory（不再迁移 category:harness 残余 — upstream-feedback.md 通道已退役，由 `/super-harness:report-issue` 替代）。 | 1 次/项目；后续 BMad 补齐后可重跑（merge 模式补填 yaml 空字段） |
| `/super-harness:update` | 升级后刷资产 — 同 init 部署逻辑但**不**投 yaml、**不**跑 BMad 提取；只 sync `.claude/harness/*` + 重装 git hooks | 每次 `/plugin marketplace update my-cc-plugin` 后 |
| `/super-harness:run-inline` | 单路 sprint loop，在当前会话里按 `pipeline.md` 逐条推进 — 详 §一-§五 | 调试、优化流水线，或不需要并行时 |
| `/super-harness:run` | 多路并行调度：每条就绪 story 一个 worktree + headless worker，串行合流收口；合流前可在合流后的代码上跑 `parallel.yaml` 的 `verify_command` — 详 [`architecture-parallel.md`](architecture-parallel.md) | story 之间依赖清楚、想并行时 |
| `/super-harness:board` | 并行调度看板，先列需要人处理的 lane | 并行跑起来之后 |
| `/super-harness:upgrade-deferred-work` | **v0.1.13+** 事后 deferred-work.md schema 复测 + mode 切换。跑 detector → 给三档（advisory / archive+greenfield / 手工 backfill 指南）→ 应用选择。供 init 时选 advisory 后想切回 strict、或手工 backfill 完想验证的场景。 | Ad-hoc，按需 |
| `/super-harness:report-issue` | **v0.1.26+** 一键给 plugin 作者提 GitHub issue。自动收集 plugin 版本 / 当前 sprint+story 状态 / halt 现场 / 近期 commits 等上下文，gh CLI 直提到 `Niutie/my-cc-plugin`。halt 场景提完会附临时绕过方案，让用户不必等 plugin 修复就能继续推进项目。 | halt / 阶段收尾 / ad-hoc 任意时机 |
| ~~`/super-harness:run-test`~~ | 0.3.0 移除。原来是流水线 ⑤.5 自动调用的 ATDD + e2e 子循环，见 §一 的说明 | 不再提供 |
| `/super-harness:codex-catchup` | **v0.1.27+** 补跑被主流水线（run-inline / run）因 codex-in-cc 不可用（未装 / 配额耗尽 / 未登录；v0.2.0 起还包括 bmad-build-auto 内 codex 层被跳过的 `in_build_layer_skipped`）跳过的 codex review + fix（stage 3+4，即 pipeline.md B2）。扫 `_bmad-output/implementation-artifacts/*.codex-skipped.json` marker → 对每条 KEY 重跑 stage 3 codex review + stage 4 dev fix → 归档 marker 为 `*.codex-skipped.resolved.json`。本命令开头会再跑一次 `check_codex_availability.sh` 探测；codex 仍不可用直接 halt（不静默重跳过）。**v0.1.38 闭环修正**：§4.6 归档先于 §4.7 stage 4 commit（归档结果随 commit 一并入库，不再留 dirty 残留）；§4.2 dirty 检查放宽为允许本命令已知的 marker / 归档残留；§4.3 stage 3 review 窗口锚定 `harness/<KEY>/done` tag（缺 tag 时 stage 5 commit subject 精确匹配兜底）+ detached 临时 worktree 把 diff 终点钉在该 SHA，避免 HEAD 已包含后续 story 提交造成的 review 窗口污染。 | codex 恢复后 |

### 〇.4 与 §十一「通用化与项目 config」的关系

§十一 设计于 plugin 化之前，描述"clone harness 到新项目 + 改 5 必填字段 + 自填 extra map"的通用化方案。

- **用户层流程**已被 plugin 模型替代：不再 clone 文件，而是装 plugin + 跑 `/super-harness:init`
- **底层数据契约**（字段 mapping、merge 模式 / `--dry-run` / `--force`、yaml schema）未变 —— `/super-harness:init` §0-§6 直接复用 §十一 设计的提取逻辑

§十一 保留作设计动机 + schema 文档；运行机制以本节 + [`commands/init.md`](commands/init.md) + [`commands/update.md`](commands/update.md) 为准。

### 〇.5 依赖

`plugin.json` **自 v0.1.28 起不声明任何硬依赖**（`dependencies` 字段已删除——装 plugin 不再要求先装 codex）。

**可选依赖：codex**（marketplace `openai-codex`）— 提供 `/codex:adversarial-review`。v0.2.0 起有两种接法：项目在 `_bmad/custom/bmad-build-auto.toml` 把 codex 挂成 review layer（codex 在 bmad-build-auto 内部跑，harness 不再单独跑）；没挂就由 pipeline.md B2 在 build 之后单独跑一次。不可用时的优雅降级链（v0.1.27 引入，v0.1.38 闭环，v0.2.0 扩展）：

1. **Pre-flight 探测**：pipeline.md B2.0 spawn codex subagent 之前先跑 `check_codex_availability.sh`，不可用（未装 / 配额耗尽 / 未登录）→ 走 B2.1 skip 路径
2. **显式跳过 + marker**：写 `<KEY>.codex-skipped.json` marker（含 reason / skipped_at / stage2_base_sha），跳过 B2 继续 B3/B4 → done——主循环不被 codex 阻断，但绝不静默。v0.2.0 起 build-verify 发现 build 内 codex 层被跳过（triage log `codex-cross-model: SKIPPED`）时同样写 marker（`reason: in_build_layer_skipped`）
3. **Marker 生命周期闭环**：`<KEY>.codex-skipped.json` 在 harness-commit.py `build-sync`（旧流水线 stage 2/4/5）的 expected-output 集里，随 B4 commit 入库；`<KEY>.codex-skipped.resolved.json` 进 stage 3/4 expected
4. **事后补跑**：codex 恢复后跑 `/super-harness:codex-catchup`（详 §〇.3 表）

未声明 plugin dep 但**前置必需**（README 列）：
- **BMad ≥ 6.11**（`bmad-build-auto` / `bmad-sprint-planning` / `bmad-retrospective` / `bmad-prd` / `bmad-architecture` 等；0.3.0 起不再需要 TEA）+ **uv**（6.12 的 skill 启动走 `uv run _bmad/scripts/render_skill.py`）——BMad 装在项目 `.claude/skills/bmad-*` 而非 Claude Code plugin，无法用 `dependencies` 字段声明。`check_bmad_runtime.sh` 在 `/super-harness:run-inline` 启动时硬检查、在 init 时 advisory 检查

### 〇.7 v0.2.0 build 流水线（BMad 6.11+）

BMad 6.11 把 `bmad-create-story` / `bmad-dev-story` / `bmad-quick-dev` 合并成 `bmad-build`（交互）和 `bmad-build-auto`（无人值守），6.12 默认不再安装旧 ID（`installShims: false`）。旧 5 阶段（create → dev → codex → fix → bmad code-review）的前两段因此无法调用，后三段又和 bmad-build-auto 内置的多层 review 重复。v0.2.0 改成：

| 步骤 | 谁执行 | 产物 / 守门 |
|---|---|---|
| B0 起跑 | 主 agent | `harness/<KEY>/start` tag；C11 deferred 注入；epic 第一个 story 附前序 retro 状态 |
| B1 build | subagent 内跑 `bmad-build-auto`（它再起 reviewer / 实现子 agent，嵌套 2 层） | `spec-<epic>-<seq>-<slug>.md`（按编号前缀识别；frontmatter status / baseline_revision / deferred / followup_review_recommended）+ 代码 + 它自己的 commit；主 agent 跑 `harness-commit.py build-verify` 事后审计 `start..HEAD`，通过后打 `built` tag |
| B2 外部 codex（条件） | subagent | 仅当 codex 没挂进 bmad-build-auto：`<KEY>.codex-review.md`（stage 3 commit）+ 修复（stage 4 commit，记在 spec 的 `### Codex Review Handling (Stage 3)`） |
| B3 follow-up（条件） | subagent 内跑 `bmad-build-auto`（done spec → 新一轮 review pass） | B2 有修复、或 spec `followup_review_recommended: true` 时跑一轮；再 build-verify，打 `followup` tag |
| B4 build-sync | 主 agent（`harness-commit.py build-sync`） | sprint-status `<KEY> → done`、epic `backlog → in-progress`；spec `deferred:` 导入 deferred-work.md（`FU-<X.Y>.B<n>`）；打 `done` tag |

要点：
- **commit 模型**：build 阶段由 bmad-build-auto 自己 commit（它的 Finalize 要求如此，且要求干净工作区），harness 的 §-1.d 守门从"commit 前预先 stage"移到"commit 后审计区间"。harness 自己的 commit（3/4/build-sync/retro）不变。
- **实现子 agent 拿不到 dispatch prompt**（bmad-build-auto 规定 spec 是唯一事实来源），harness 的实现清单通过 spec frontmatter `context:` 挂载 `bmad-build-implement-suffix.md`，再由它让实现子 agent 拉取 `harness-prompt-suffix.py implement`。
- **状态源**：`harness-state.py` 以 tag（start / built / followup-start / followup / done）+ spec frontmatter status + `story(<KEY>): sync sprint status & deferred ledger` commit 判断续作点；`--in-flight` 取代 `find-by-status review` 作为 `--continue` 的目标来源。
- **retro**：`bmad-retrospective -H <epic>`；retro 文档 frontmatter `verdict` 由 stage 6 commit 读出（`RETRO_VERDICT=`），`rejected` 时 all 模式不进下一个 epic，除非只是 `EPIC_WONT_DO=` / `EPIC_PARKED=`（0.3.1）里的 story 触发。BMad 原生 `action_items` 与 harness `retro_action_items` 按 id `epic-<N>-retro-<CODE>` 对齐，retro-fulfill 两本账一起翻。
- **pre-commit gate ①** 触发从写死的 `[4-6]-*.md` 改成任意 epic 的新 story spec（`spec-<N>-<M>-*.md` / `<N>-<M>-*.md`）；是否拦截由 `retro_gate: warn | block` 决定，默认 warn。
- **retro_action_items 写法**改为合法 YAML 嵌套映射（`CODE:` + `status:` 子键），BMad 6.12 原生脚本整文件按 YAML 解析；旧标量写法由 `sprint-status.py migrate-retro-items` 迁移，读取器两种都认。
- **旧流水线 story**：`harness-state.py` 报 `pipeline: legacy` + `legacy-stage*` code，处理见 pipeline.md §1.L。

### 〇.8 0.3.1 变更要点

上线前做了一轮全面检查和修复，并处理 issue #14、#15。完整清单见 changelog v0.3.1，这里只列影响架构理解的部分。

- **git 跟踪规则**：`.claude/harness/` 下部署进来的资产不进 git，`harness-project-config.yaml` 和 `parallel.yaml` 进 git。`ensure_gitignore.sh` 往项目 `.gitignore` 补三行规则，init 和 update 都会跑。update 的备份放在 `.claude/harness/.backup/<TS>/`，开 lane 时不复制。init / update 必须在仓库根目录执行。
- **init 写后校验**：改用 `harness_config.py check`，退出码非 0 才回滚；`[]`、`''` 是合法空值，不再报 WARN。init 不再跑 `simulate_clone_test.sh`。
- **B2.2 codex 审查**：不再派子 agent，主 agent 直接跑 `run_codex_review.sh`（600 秒超时）。成功要求退出码 0、`Verdict:` 行，以及 finding 或 `No material findings.`；零 finding 时 spec 里写一行 `- [none]`，stage 4 照常提交，不触发 B3。codex 的额度、登录、超时问题看脚本首行 `CODEX_STATUS:`；Claude 运行时额度耗尽只看子 agent 返回的第一行，都不再在正文里搜关键词。
- **依赖来源**：`deps_overrides` → sprint-status 顶层 `story_dependencies` → 多行块 `depends_on`。BMad 6.12.4 的 `sprint_plan.py` 和 retrospective `detect-epic` 读不了多行块（#14），`sprint-status.py flatten-deps` 负责迁移，`run` / `run-inline` 启动时自动改写并用 `harness-commit.py deps-migrate` 提交。run-inline 的 `next` 也按依赖挑 story。依赖里 `ext-` 开头的是外部条件，永远不自动满足。
- **挂起状态**：`harness-project-config.yaml` 的 `parked_statuses`（#15）。这些 story 不派发，不算 epic 屏障里的未完成，不挡 retro；retro 时输出 `EPIC_PARKED=`，verdict 门不因它 halt；有挂起 story 的 epic 在 stage 6 只标 retrospective done，epic 保持 in-progress。`parallel.yaml` 新增 `epic_barrier` 开关。
- **pre-commit hook**：不再用 `cmd | grep -q`（大提交时 SIGPIPE 会让检查被跳过）；`retro_action_items:` 块不存在时 gate ① 直接放行；产物路径从配置读。
- **并行调度**：prepare / integrate 由调度者后台执行，被打断超过 2 次记 held；lane 级失败统一记 held 并带 `hold_kind`；超时结束整个进程组；`dispatcher.lock` 保证一个仓库只有一个会话调度。详见 architecture-parallel.md §4、§6、§9。

### 〇.6 0.1.28-0.1.38 机制演进要点（本节按 working tree 实况核对）

> 详细动机 / commit 对照见 [`changelog.md`](changelog.md)；此处只收口"读本文档需要知道的行为变化"。

**run.md 编排层**：
- **§0.A.0 retro DEV 项兑现前置 gate**（v0.1.33，issue #3）：`/super-harness:run-inline` 启动时先跑 `grep_pending_dev_retro_items.sh`，`category: dev` 的 pending retro 项 N>0 → 先进兑现循环（有 `chore_spec` 的自动兑现、缺 spec 的列给用户二选一），清零后才进 stage ①——否则 stage ① commit 必被 pre-commit gate ① 拦
- **retro-only 路径（§0.C）**：`--epic` 指定 epic 全 done 但 retro 未 done 时直接跳到阶段 ⑥；入口已预先用 `epic-all-done` + `epic-retro-status` 验证
- **stage 3 quota 例外**：Claude 运行时额度耗尽一般 stage 即 halt；codex 自己的额度 / 登录 / 超时问题改走 §③.1 skip+marker 路径（catchup-friendly）。0.3.1 起两者都不再靠搜关键词：前者看子 agent 返回第一行是否为运行时额度报错（pipeline.md §−1 (a)），后者看 `run_codex_review.sh` 的 `CODEX_STATUS:` 与退出码

**harness-commit.py 安全门（review 2026-06-10 #1/#7 修复，v0.1.38）**：
- worktree 扫描改 `git status --porcelain -uall -z`：`-uall` 展开 untracked 新目录内的每个文件（此前整目录折叠成一行，目录内 blacklist 文件不可见）；`-z` 拿 NUL 分隔的原始字节路径（含双引号 / 换行 / CJK 文件名不再被 C-quote 干扰）
- `glob_match` 改 gitignore 语义：`**/` 匹配**零或多段**（`**/.env*` 现在也命中仓库根目录的 `.env`）
- BLACKLIST 拆两档：**halt 档**（凭证类 `.env*` / `*.pem` / `credentials*` 等 + 受保护 harness/BMad 基建路径）命中 → STATUS=halt；**junk 档**（`.DS_Store` / `*.tmp` / `*.swp` / `__pycache__` / `*.pyc` 等系统/编辑器垃圾）命中且**路径不在 HEAD** → 自动从工作集剔除 + stderr 一行 `NOTE: skipped junk file`，**不 halt 不入库**。junk 档只对 untracked / newly-added 路径生效——tracked 文件的修改与 `git rm` 删除照常走流水线入 commit；`*.log` 不属于 junk（.log 是常见合法项目文件，构建日志由项目 .gitignore 管）
- 退出码契约：`0` = 可 commit（stdout 给 SUGGEST_COMMIT_MSG / SUGGEST_TAG）；`1` = halt（stdout 诊断行 verbatim 进 halt 模板）；`2` = 无改动跳过（仅 *-fallback / *-done 类 stage 合法）

**retro 链（issue #3/#6 + review #5/#29/#72，v0.1.33-0.1.38）**：
- run.md 阶段 ①/⑥ 子 agent prompt 注入**显式 Read 强制契约**：阶段 ① "先 Read `bmad-create-story-suffix.md`"、阶段 ⑥ "先 Read `bmad-retrospective-suffix.md`（Form 1 + Category + pre-retro self-audit）"——suffix 格式契约从"无人送达的死契约"变成真实送达通道（详 §十）
- retro markdown 的 `**Category**: dev|harness` 声明被真实消费：`_parse_retro_action_items` 返回 `(code, title, category)` 三元组，seeder 在 `retro_action_items.<id>` 下写 `category: dev|harness` 子键（非法/缺失声明 → 不写子键 + WARN，gate 按 NOCAT 保守不阻）
- `_seed_retro_action_items` 顶层父键缺失时自动 bootstrap（v0.1.36，issue #6）；文件末行无换行时统一归一化后再追加（不再产出粘连 YAML）；follow-through 表格过滤在整文件兜底扫描前切除（上期 AI-N.M 不再误 seed 进当前 epic）
- epic letter 映射 `_epic_letter` 支持 bijective base-26（v0.1.35，issue #5）：1→A … 26→Z → 27→AA，epic > 26 不再崩

**状态机（issue #4 + review #76/#77，v0.1.34-0.1.38）**：
- sprint-status.py 兼容多行块格式（`key:` 换行 + 嵌套 `status:` / `depends_on:`）与单行格式双轨；`cmd_set` 就地改写"承载 status 值的那一行"。（0.3.1 注：BMad 6.12.4 自己的脚本读不了多行块，依赖改推荐写在顶层 `story_dependencies`，见 §〇.8）
- `cmd_status` 不再过滤 `epic-*` key（epic-N / epic-N-retrospective 可读，读写对称）；harness-commit.py `read_story_status` 容多词 status（`Ready for Review` 等）
- `_sync_sprint_status_for_stage` 两阶段 read-then-set：先读全部目标 key 当前值，确认后再统一 set——幂等 + 半途 halt 不留半套状态

**配置 SoT（review #9/#33/#49/#60/#80）**：
- `harness_config.py` 新增 `get_frontend_dir()` / `get_e2e_test_subdir()`：harness-commit.py 的 e2e spec 白名单前缀与 run-test.md T3/T4 的占位符同源读 config（0.3.0 测试阶段移除后，e2e 相关的白名单和 `e2e_test_subdir` 字段一并退役）
- `get_artifacts_root()` 对绝对路径 / 越界相对路径**降级不 raise**：仓库内绝对路径规范化为 repo-relative，仓库外回落默认值 + WARN（三个 import 期消费方不再裸 traceback）
- init §A.3 / upgrade-deferred-work §3.3.B 的 deferred-work 路径统一 source `read_harness_config.sh` 派生（自定义 artifacts_root 时两处检查同一个文件）

**bash 基建（review #2/#3/#18/#21/#50/#58/#87）**：
- `install_git_hooks.sh` 退出码契约：`0` = 安装成功；`3` = 良性拒装（用户自定义 `core.hooksPath`，调用方按 WARN 处理）；`1` = 真实安装失败（源目录缺失 / cp/chmod 失败，update halt / init WARN 引导自查）——init/update 的契约表同步
- `deploy_assets.sh`：manifest 原子写 + 临时文件入 EXIT trap + `find` 排除隐藏文件（`.DS_Store` 不再投递）+ purge 失败文件回写 manifest 重试；`prompt-templates/` 自分发清单移除后由 manifest purge 对账自动清掉下游残留
- 新增 `scripts/prompt_template_lib.sh`：`${project_display_name}` 占位符渲染共享库（awk 字面替换，`&` / `\` / CJK 安全），process_retro_residue.sh 与 backfill_resolved_markers.sh 共用；4 份 retro parser 的文法 / 枚举对齐收敛进 `deferred_work_schema_lib.sh`
- pre-commit gate ② 修复纯删除 diff 触发 pipefail 无声阻断 commit 的问题

**测试体系（review #10/#40/#41/#44/#45/#46）**：
- `run_all_tests.sh` 的 KNOWN_STALE 名单从 9 项清到 **1 项**（仅 `simulate_clone_test.sh`——其测试对象就是宿主仓库的部署树，源码树跑不了，由 CI bootstrap-tests job 实跑）；stale-listed 测试 PASS 时打 "remove from KNOWN_STALE" 提示防名单腐化
- ci.yml 三 job：`source-tests`（源码树全量 + release_check 版本门）/ `bootstrap-tests`（伪下游项目 fixture 内 glob sweep 跑部署副本测试）/ `macos-bash32-tests`（macOS bash 3.2 真覆盖）
- 新增回归测试：`sprint_status_format_test.sh`（44 断言，单行/多行块双格式）、`harness_commit_blacklist_test.sh`（安全门双档）、`deploy_assets_purge_test.sh`（22 断言）、`retro_category_round_trip_test.sh` / `retro_fulfill_stage_test.sh` / `read_harness_config_issue7_test.sh` 等

---

## 一、两循环总览

```
┌──────────────────────────────────────────────────────────────┐
│                        solo-dev 触发器                        │
└──────────┬───────────────────────────────────┬───────────────┘
           │                                   │
           ▼                                   ▼
  ┌─────────────────────────────┐   ┌─────────────────────┐
  │ /super-harness:run-inline   │   │   主 agent 手工      │
  │ 或 /super-harness:run       │   │   chore 循环 (元)    │
  │ 业务故事循环                │   │   单 commit          │
  │ B0-B4 + 6/6.5               │   │                      │
  │                             │   │   写: retro_action_  │
  │ 写: dev_status epic-seq-*   │   │        items.epic-N  │
  └─────────┬───────────────────┘   └──────────┬──────────┘
            │                                  ▲
            │ stage 6.5 生成 chore spec        │
            └──────────────────────────────────┘

            ▲                                  │
            │  pre-commit hook (C1)            │
            │  gate 新 story spec 创建（任意 epic）
            └──────────────────────────────────┘
            (retro_action_items 有 pending → 阻断主循环开新 epic)
```

**关键约束**：
- 路径 A 的 key 必须 `epic-seq-slug` 数字开头格式（sprint-status.py epic-of 硬假设）
- 路径 B 的 key 是 `retro_action_items` 的字母数字 code（A1 / B5 / C7 / D2）

**测试放在哪**：0.3.0 之前这里是三循环，第三个是 `/super-harness:run-test` 测试循环（T1 test-design、T3 ATDD 红相、T4 e2e），由流水线 ⑤.5 在每条 story done 之后调用。实际运行中它几乎总在跳过：没有 e2e 的项目每条 story 白起一个子 agent，配了 e2e 的项目红了也只记一条 FU，挡不住任何东西。0.3.0 把它整体移除，测试分工改为：

- 单元测试和集成测试在 B1 里完成。bmad-build-auto 在 spec 的 `## Verification` 写验证命令并实跑，step-03 的 Matrix Test Audit 要求 I/O 矩阵每一行都有跑过且通过的测试，step-04 的 verification-gap 审查层找没有测试兜底的行为改动。
- 并行模式合流时，`superh.py integrate` 可以在合流后的代码上再跑一次 `verify_command`，见 [`architecture-parallel.md`](architecture-parallel.md) §7.5。
- e2e 和验收测试交给下游测试团队。

---

## 二、单 epic 完整流水线（端到端展开）

```
solo-dev 跑: /super-harness:run-inline
   │
   ▼
┌─ epic-N backlog (12 / 9 / 11 stories) ──────────────────────────────────┐
│                                                                         │
│   for each story (N-1, N-2, ..., N-last):                               │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                                                                 │   │
│   │  B0: start tag + C11 注入                                        │   │
│   │    ┌──────────────────────────────────────────────────┐        │   │
│   │    │ bash grep_pending_deferred_for_story.sh KEY       │       │   │
│   │    │   → "本 story 应消化 N 条 deferred FU"            │       │   │
│   │    └──────────────────────────────────────────────────┘        │   │
│   │  B1: bmad-build-auto（规划 → 实现 → 多层 review → commit）       │   │
│   │    ├─ 单元 / 集成测试在这里写并实跑（Verification 命令 +        │   │
│   │    │  Matrix Test Audit + verification-gap 审查）               │   │
│   │    └─ harness-commit.py build-verify 审计 start..HEAD           │   │
│   │  B2: 外部 codex review + fix（仅 codex 未挂进 build 时；        │   │
│   │      0.3.1 起主 agent 直接跑 run_codex_review.sh）              │   │
│   │    └─ codex 不可用 → 写 <KEY>.codex-skipped.json 显式跳过       │   │
│   │       （待 /super-harness:codex-catchup 补跑——§〇.5）              │   │
│   │  B3: bmad-build-auto follow-up review（按需，最多一轮）          │   │
│   │  B4: build-sync（sprint-status + spec deferred → ledger）        │   │
│   │                                                                 │   │
│   │  → development_status.KEY = done                                │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│   epic-N 全部终态或挂起（至少一条 done）触发 stage 6:                    │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │  stage 6: bmad-retrospective -H N (headless; verdict 门)        │   │
│   │    → epic-N-retro-YYYY-MM-DD.md                                 │   │
│   │    (内含 D1-Dn 共 m 项 action items)                            │   │
│   │                                                                 │   │
│   │  stage 6.5 (C10): bash .claude/harness/scripts/                 │   │
│   │                        process_retro_residue.sh --epic N        │   │
│   │    ┌──────────────────────────────────────────────────┐        │   │
│   │    │ fresh agent 读 retro markdown                     │       │   │
│   │    │   + sprint-status retro_action_items.epic-N-retro │       │   │
│   │    │   + 已存在 chore-retro-cN-* 列表 (黑名单)         │       │   │
│   │    │ 输出: chore-retro-cN-D1-*.md ... cN-Dm-*.md       │       │   │
│   │    │ 写: retro_action_items.epic-N-retro.D1.chore_spec │       │   │
│   │    └──────────────────────────────────────────────────┘        │   │
│   │                                                                 │   │
│   │  stage 6-done: epic-N + epic-N-retrospective 双状态 done        │   │
│   └─────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
   │
   │  /super-harness:run-inline 主循环准备进 epic-(N+1)
   │
   ▼
┌─ pre-commit hook (C1) gate ─────────────────────────────────────────────┐
│                                                                         │
│   尝试创建 [N+1]-*.md spec → hook 触发                                  │
│   check_retro_action_items.sh 扫所有 epic 的 retro_action_items         │
│       ├─ 有 pending/in-progress → exit ≠ 0 → 阻断 commit                │
│       └─ 全 done → 通过                                                 │
│                                                                         │
└──────────────────────────────────┬──────────────────────────────────────┘
                                   │
                                   ▼
                              有 pending?
                              /         \
                            是           否
                            ▼             ▼
              ┌─────────────────────────┐  /super-harness:run-inline 进 epic-(N+1)
              │ 进入手工 chore 循环      │  (回到上面流水线)
              │ (路径 B)                 │
              └─────────────────────────┘
                            │
                            ▼
              for each chore-retro-cN-*.md (按 backlog 顺序):
              ┌─────────────────────────────────────────────┐
              │  主 agent 实施单条 chore                      │
              │   1. 读 chore-retro-cN-Dx-*.md spec          │
              │   2. 实施 Tasks (写脚本 / 改文件 / 测试)      │
              │   3. 跑 self-test                            │
              │   4. git add 具体路径 + 单 commit             │
              │   5. 翻 retro_action_items.epic-N.Dx = done  │
              └─────────────────────────────────────────────┘
                            │
                            ▼
                    全 done? → 解除 hook gate
                            │
                            ▼
                    /super-harness:run-inline 进 epic-(N+1) (循环到顶)
```

---

## 三、闭环关系（数据流）

```
                                          ┌──────────────┐
                                          │ deferred-    │
                                          │ work.md      │
                                          │              │
                                          │ 200+ FU 项   │
                                          │ Resolved 标记│
┌──────────────┐                          │              │
│ run-sprint   │  C12 一次性 backfill     │ 10% → 30%+   │
│ stage 2 dev  │  改 inline Resolved       │              │
│ 顺手 resolve │ ◄────────────────────────┤              │
└──────────────┘                          └──────────────┘
       ▲                                          │
       │                                          │ C11 grep
       │ prompt 头部注入                          ▼
       │                                  ┌──────────────┐
       └──────────────────────────────────│ stage 1      │
                                          │ create spec  │
                                          └──────────────┘

┌──────────────┐                          ┌──────────────┐
│ stage 6      │ epic retro 自由文字       │ epic-N-retro │
│ /bmad-retro  │ ────────────────────────►│ -*.md        │
└──────────────┘                          └──────┬───────┘
                                                 │
                                                 ▼ stage 6.5
                                          ┌──────────────┐
                                          │ fresh agent  │
                                          │ 语义分析     │
                                          │ 生成 chore   │
                                          └──────┬───────┘
                                                 │
                                                 ▼
                                          ┌──────────────┐
                                          │ chore-retro- │
                                          │ cN-Dx-*.md   │  ◄─── pre-commit
                                          │              │       hook gate
                                          │ + retro_     │       (C1)
                                          │ action_items │
                                          │ chore_spec   │
                                          └──────┬───────┘
                                                 │
                                                 ▼ 主 agent 手工实施
                                          ┌──────────────┐
                                          │ retro_action │
                                          │ _items.Dx =  │
                                          │ done         │
                                          └──────────────┘
```

---

## 四、状态字段写入责任表

```
┌──────────────────────────────────────┬─────────────────────────┬────────────────────┐
│ 字段路径                              │ 写入者                   │ 触发时机           │
├──────────────────────────────────────┼─────────────────────────┼────────────────────┤
│ sprint-status.yaml                   │                         │                    │
│   .development_status.<epic-seq-key> │ harness-commit build-sync│ B4（→ done）       │
│   .retro_action_items.epic-N.<code>  │ stage 6.5 (C10) seed    │ epic 收尾自动       │
│     .chore_spec: <path>              │ stage 6.5 (C10) 写       │ chore 生成时        │
│     status: pending → done           │ 主 agent 手工翻         │ chore 实施完成     │
│                                      │                         │                    │
│ deferred-work.md                     │                         │                    │
│   FU-X.Y.Z bullet                    │ B1 实现子 agent / B2 fix│ 实现 / codex 修复  │
│   FU-X.Y.B<n> bullet                 │ build-sync 导入 spec    │ B4                 │
│                                      │ frontmatter deferred:   │                    │
│   ` — Resolved by Story X.Y` inline  │ run-sprint stage 2 dev  │ 顺手 resolve      │
│   ` — Resolved by ...` (回填)        │ C12 一次性 fresh agent  │ 单次 chore 跑      │
│                                      │                         │                    │
│ <artifacts_root>/                    │                         │                    │
│   <KEY>.codex-skipped.json           │ run-sprint B2.1 skip    │ codex 不可用       │
│     （随 B4 build-sync commit 入库）  │                         │                    │
│   <KEY>.codex-skipped.resolved.json  │ codex-catchup §4.6 归档 │ catchup 补跑完成   │
│     （随 catchup stage 4 commit 入库）│                         │                    │
│                                      │                         │                    │
└──────────────────────────────────────┴─────────────────────────┴────────────────────┘
```

0.3.0 起 `test_status` 段、`FU-Test-*` 条目、`test_artifacts/` 目录和 e2e spec 都不再由 harness 写入。老项目里已有的这些内容原样保留，harness 不读也不删。

---

## 五、Skill / Hook 调用图

```
                   ┌──────────────────────────────────────┐
                   │ .claude/harness/pipeline.md          │
                   │   (主 orchestrator)                   │
                   └─────┬────────────┬───────────┬────────┘
                         │            │           │
                         ▼            ▼           ▼
                ┌──────────────────────────┐ ┌──────────────────┐
                │bmad-build-auto (B1 / B3) │ │codex:adversarial-│
                │ ├ compile-epic-context   │ │review (B2，仅    │
                │ ├ 实现子 agent           │ │codex 未挂进      │
                │ └ review layers（含项目  │ │build；不可用 →   │
                │   自定义 codex 层）      │ │B2.1 skip marker）│
                └──────────────────────────┘ └──────────────────┘
                         │
                         ▼ stage 6
                   ┌────────────────────┐
                   │bmad-retrospective  │
                   └────────────────────┘
                         │
                         ▼ stage 6.5
                   ┌────────────────────────────┐
                   │ .claude/harness/scripts/             │
                   │   process_retro_residue.sh │
                   │   (fresh agent 调度)        │
                   └────────────────────────────┘

                   ┌──────────────────────────────────────┐
                   │ .claude/harness/git-hooks/pre-commit (C1)       │
                   │   gate 新 story spec 创建（任意 epic） │
                   └──────────────────────────────────────┘
```

---

## 六、4 个 Decisions — Q1/Q2/Q3 RESOLVED 2026-05-03 / Q4 RESOLVED 2026-05-05

### Q1 ✅ RESOLVED: C10 spec 修正 — 同意修正

C10 不在 sprint-status.yaml 加 `chore-retro-cN-residue: backlog` 段（撞 run-sprint 5-stage key 数字格式硬假设）。C10 仅：
- 生成 chore spec 文件
- 在 `retro_action_items.<code>.chore_spec` 字段写指针

生成的 chore 走**路径 B 手工实施**（与 C1/C5 同款），不进 run-sprint。

C10 spec 已 2026-05-03 改完（commit pending）：Approach / Boundaries / Q2 / I/O Matrix / Code Map / Tasks / Acceptance / Design Notes / Verification / Suggested Review Order 共 9 处。

### Q2 ✅ RESOLVED: stage 5.5 嵌入 — 嵌入（0.3.0 SUPERSEDED：⑤.5 与 run-test 已移除）

> **Supersession note (0.3.0)**：⑤.5 跑下来几乎总是跳过，没有 e2e 的项目每条 story 白起一个子 agent，有 e2e 的项目红了也不 halt。0.3.0 移除 ⑤.5 和 `/super-harness:run-test`，基本测试归 B1 的 bmad-build-auto，并行模式加合流验证门，e2e 交给测试团队。详见 §一 和 changelog 0.3.0。下面是当时的决策原文。

`/super-harness:run-test` 嵌入 run-sprint stage 5.5（每条 story bmad-code-review 完成后自动调）+ 保留独立入口 `/super-harness:run-test --story <key>`。stage 5.5 graceful skip（sandbox 无 docker → 写 FU-Test-KEY-sandbox + exit 0）保证不阻 run-sprint 主循环。这是真扩展 run-sprint 5-stage 到 6-stage（不是为残留改主循环——测试本就是开发流水线一环）。

C-bootstrap spec 内部 Q4 已 2026-05-03 标 RESOLVED。

### Q3 ✅ RESOLVED: chore 实施 — 主 agent 自动续作

每次新会话起步主 agent 扫 `retro_action_items.<id>.{status,chore_spec}`，pending 项自动通知 solo-dev + 等指令决定是否进入 chore 实施流程。

具体协议见项目根 [`CLAUDE.md`](../CLAUDE.md)「会话起步约定（chore 自动续作）」段（2026-05-03 同 commit 落地）。

风险缓冲：主 agent **不**在 solo-dev 给其它指令时擅自跑；只在用户肯定回复"继续"时进入 chore 模式；任一步骤失败立即 halt + 报告状态。

### Q4 ✅ RESOLVED 2026-05-05 → SUPERSEDED 2026-05-07 by v0.1.14 → SUPERSEDED 2026-05-09 by v0.1.26：`category:harness` 通过 `/super-harness:report-issue` 直提 GitHub issue（取消 upstream-feedback.md 中转）

> **Supersession note (v0.1.26)**：v0.1.14 的 `upstream-feedback.md` 中转通道实际运行 ~3 周后发现：用户 review 该文件 → 复制粘贴到 GitHub issue 创建页 → 手填 title / 标 label，仍是 5+ 步手工损耗，多数项目积累几条后就懒得提了，反馈到达率低。v0.1.26 改为**直通管道**：新命令 `/super-harness:report-issue` 自动收集 plugin 版本 / 当前 sprint+story 状态 / halt 现场 / 近期 commits 拼好 issue body，gh CLI 一键直提到 `Niutie/my-cc-plugin/issues`；halt 场景提完还附临时绕过方案让用户继续推进项目。`upstream-feedback.md` / `extract_harness_feedback.sh` / `detect_harness_residue.sh` / `templates/upstream-feedback.md.template` 全删；retro skill 不再分流（`category: dev` 与 `category: harness` 都写 sprint-status.yaml，仅 pre-commit gate 行为不同 — dev 阻 commit / harness 仅 WARN + hint 跑 `/super-harness:report-issue`）。`migrated-upstream` status enum 保留兼容（v0.1.14-0.1.25 残余视同 done）。Q4 B 方案的 schema/gate/process 决策仍在。详 changelog v0.1.26。

> **Supersession note (v0.1.14)**：B 方案落地后实际运行表明，把 plugin-maintainer 的债（`category: harness`）继续放在 sprint-status.yaml 里仍是 plugin **用户视角**的污染（用户感觉"项目背着插件作者的待办"+ `check_retro_action_items.sh` 反复 WARN）。v0.1.14 曾改为：retro skill 写入时直接分流 — `category: dev` 仍写 sprint-status（行为同 B 方案），`category: harness` 改写 `.claude/harness/upstream-feedback.md`（markdown 而非 yaml；用户复制粘贴提 GitHub issue 给作者）。该方案在 v0.1.26 被进一步取代（见上）。



**Problem**：retro 产出实证混合两类问题 — (i) **dev 类**（产品代码 / 测试 / 文档 / NFR / ADR / 业务功能优先级，blast radius 局限于一个 epic 的产品交付）和 (ii) **harness 类**（流程脚本 / hook / skill / template / convention / schema / 通用化，blast radius 跨所有后续 epic 的所有 story，metasystem 级）。原方案两类共用同一个 `retro_action_items` 表 + 同一个 pre-commit gate，等于把"基础设施改造"和"产线作业"挂在同一根保险丝上 — D5 那次 inheritance gate 误伤 epic-5 stage ③ codex-review.md 是典型表现（v1.3 复盘已删 gate ②）。

**Decision — B 方案（轻分离）**：

1. **schema 升级**：`sprint-status.yaml.retro_action_items.<id>` 加必填字段 `category: dev | harness`（与 `chore_spec:` 平级）
2. **gate 分流**：`check_retro_action_items.sh` v2 仅把 `category: dev` 的 pending/in-progress 计入 exit code（阻 epic 4-6 spec 创建）；`category: harness` 的走 stderr WARN 段（"non-blocking"）；缺失 category 的走 NOCAT WARN 段（保守按"不阻"处理 + 提示 schema drift）
3. **chore 自动续作分流**：CLAUDE.md「会话起步约定」按 category 分两段通知 — dev 类是主通知（dev pending 时优先消化）；harness 类**仅在 dev 全 done 时**才作为次通知出现，且**必须 solo-dev 显式触发**（"评估 harness 优化" / "继续 harness <id>"）才进入实施流程
4. **residue processor 分流**：`process_retro_residue_prompt.md` 加 category rubric + MANIFEST block 输出契约 — fresh agent 生成 chore 时同步给出 category 判断（模糊归 harness — 错分进 harness 代价小）

**Why B 不是 A（完全分离）**：A 方案把 harness 类彻底搬出 sprint-status.yaml 到 `.claude/harness/improvement-backlog.yaml` + 完全手动评估。代价：harness 演进显著变慢（critical path 类如 schema 升级 / test harness 接通会被 solo-dev 习惯性拖延）；solo-dev 自负全部跟踪成本。B 保留同一个表只是为了 chore 自动续作能继续工作；solo-dev 仍能看到 harness backlog 的存在，但不被强制阻塞。

**Why B 不是 C（物理拆两表）**：C 方案的核心难点是 residue processor 分类启发式 — 错分会把 critical path harness 改动错放进 backlog 永远不做。B 让 fresh agent 在生成 chore 时打 tag，错了 solo-dev 一眼能改，比"分类后写两文件不可逆"更稳。

**为什么 D5 那次能引发讨论**：D5 落地的 inheritance pre-commit gate ② 是典型 harness 改动 — 一个 hook bug 直接阻塞所有 epic-5 spec 创建，迫使 v1.3 把 gate ② 整个删除。这是 harness blast radius 不对称的实证 — B 方案让 harness 改动天然降级为"建议"，等同事实上的 staging 环境（先 WARN，solo-dev 显式确认再实施 + commit）。

**实施落地**：2026-05-05 同一会话 5 文件 single commit
- sprint-status.yaml — schema 升级 + 40 条 retro_action_items 回填 category
- check_retro_action_items.sh v2 + 12 fixture self-test 全过
- pre-commit hook v1.5 错误文案分流
- process_retro_residue_prompt.md 加 rubric + MANIFEST 契约
- CLAUDE.md 起步约定分流通知

---

## 七、实施 roadmap（spec → 全自动 harness）

### 当前已落
- ✅ C1 pre-commit hook + sprint-status retro_action_items 块（commit 4bc987b）
- ✅ C5 deferred-work.md §1 物化 + grep_deferred_buckets.sh（commit 2b71aab + 后续）
- ✅ C10 / C11 / C12 / C-bootstrap 4 份 chore spec（commit 3d3aaa5）
- ✅ Q4 B 方案 retro_action_items 按 category 分流（2026-05-05；schema 升级 + 40 条回填 + checker v2 + hook v1.5 + residue prompt rubric + CLAUDE.md 起步约定分流）

### 待做（顺序）

```
Q1/Q2/Q3 决策点 → 改 C10 + C-bootstrap spec（如有修正）
   │
   ▼
1. 实施 C11 (deferred grep injection)
   单 commit + 翻 retro_action_items.epic-3-retro.C11=done
   │
   ▼
2. 实施 C12 (deferred resolved backfill)
   分 epic-1/2/3 三批 commit + 翻 C12=done
   │
   ▼
3. 实施 C10 (retro residue processor)
   单 commit + 翻 C10=done
   │
   ▼
4. 跑 process-retro-residue 历史回填:
   bash .claude/harness/scripts/process_retro_residue.sh --epic 1   → ~6 chore-retro-c1-*.md
   bash .claude/harness/scripts/process_retro_residue.sh --epic 2   → ~8 chore-retro-c2-*.md
   bash .claude/harness/scripts/process_retro_residue.sh --epic 3   → ~7 chore-retro-c3-*.md
   = 共 ~21 个 chore spec 自动生成
   │
   ▼
5. 实施 C-test-harness-bootstrap
   testarch 三 skill 跑通 + /run-test.md 第一版
   单 commit + 翻 C-bootstrap=done
   (Q2 决策处；0.3.0 已整体移除)
   │
   ▼
6. 主 agent 逐条实施 21 个 chore-retro-cN-*.md
   每条单 commit + 翻 retro_action_items.epic-N.<code>=done
   (Q3 决策处)
   │
   ▼
全 retro_action_items=done → pre-commit hook gate 解除
   │
   ▼
/super-harness:run-inline (无参) 自动跑 epic-4 / 5 / 6
   每条 story 自动走 B0-B4 + 6 + 6.5（0.3.0 前还有 ⑤.5，已移除）
   每个 epic 收尾自动 process-retro-residue 生成新 chore
   主 agent 在新 epic 启动前自动消化 chore (闭环)
```

---

## 八、不在本架构 scope 内（已确认不做）

- ❌ **改 BMad 上游 skill**（`bmad-build-auto` / `bmad-retrospective` 等；旧版是 `bmad-create-story` / `bmad-dev-story`）— 用 prompt 拼接 + spec `context:` 挂载绕过
- ❌ **deferred-work.md schema 迁移**（每条 FU 加 frontmatter）— C12 inline 标记够用
- ❌ **为 chore 改 run-sprint 主循环**（让 run-sprint 支持 chore-* 命名空间）— chore 走路径 B 即可
- ❌ **husky / npm prepare 路径** — C1 raw `.git/hooks/` 已落
- ❌ **harness 内的 e2e / 验收测试循环** — 0.3.0 起移除（原 testarch 接通、⑤.5、`/super-harness:run-test`）；e2e 交给测试团队

---

## 九、引用

- 4 份 chore spec: `_bmad-output/implementation-artifacts/chore-retro-c10-*.md` / `c11-*.md` / `c12-*.md` / `chore-test-harness-bootstrap.md`
  - C11 / C12 已标 superseded by deferred-work-schema-v1（2026-05-04）— 脚本骨架保留, 解析路径切到 schema tag
- C1 pre-commit hook spec: `_bmad-output/implementation-artifacts/spec-retro-c1-pre-commit-hook-retro-action-items.md`
- run-sprint 主流程: `.claude/harness/pipeline.md`（单条 story）+ `/super-harness:run-inline` / `/super-harness:run`（主循环）
- 代答政策: `.claude/harness/answer-policy.md`
- sprint 状态机: `.claude/harness/scripts/sprint-status.py`（单行 + 多行块双格式，v0.1.34+；0.3.1 起推荐单行 + 顶层 `story_dependencies`）+ `.claude/harness/scripts/harness-state.py`
- commit 协议: `.claude/harness/scripts/harness-commit.py`（退出码 0=可 commit / 1=halt / 2=空 worktree 跳过；安全门双档见 §〇.6）
- **conventions（项目层格式契约）**:
  - `.claude/harness/conventions/deferred-work-schema.md` — deferred-work.md schema v1（FU bullet 4-tag 头 / status / bucket / target / source / 历史 audit log；C11/C12 取代）

---

## 十、Prompt suffix 注入约定（C11 / A3 / A7 / B2 / B3 / C2 / C3 / C7 / C9 沉淀；v0.1.38 改 Read 强制契约）

CLAUDE.md 严格禁止动 `.claude/skills/bmad-*/`，因此所有 SKILL 级 enforce 都走 prompt 注入路径。

> **历史变更（v0.1.38）**：早期版本由主 agent 在 user prompt 首部 inject 一串文件引用（含
> `prompt-templates/` 4 个段模板）。review 2026-06-10 #27/#30 证实该清单是**死契约**——
> 没有任何编排路径真的执行注入，且 `prompt-templates/` 4 模板停留在 pre-schema-v1 语义、
> 零运行时引用。v0.1.38 起 `prompt-templates/` 目录**停止分发**（下游残留由 update 的
> manifest purge 对账清掉），注入机制改为下述三通道——全部在 run.md 子 agent prompt
> 模板里**逐字落地**，不再依赖主 agent 自觉。

### 通道 1：显式 Read 强制契约（B1/B3 build / 阶段 ⑥ retrospective）

run.md 的子 agent prompt 模板**逐字包含**格式契约段（v0.2.0 起 build 段由 `harness-prompt-suffix.py build` 输出）：

- B1/B3：跑 bmad-build-auto 的 subagent 在 step-02 写 spec 前 Read `.claude/harness/prompt-suffixes/bmad-build-auto-suffix.md`——slug = story key、frontmatter `context:` 挂实现清单、cross_story_artifacts / planning_artifacts 声明、Epic 第一个 story 继承段（C7，`check_inheritance_block.sh` 自检）、deferred 注入项处理。旧 create-story suffix 的 `check_spec_length.sh` / `extract_d_decisions.sh` 两个 Finalize 步骤退役（bmad-build-auto 自带 900–1600 token 范围标准与 `oversized` warning）
- 实现子 agent：通过 spec `context:` 读 `bmad-build-implement-suffix.md`，再拉取 `harness-prompt-suffix.py implement`（Q6 / ledger 格式 / marker 禁令）
- 阶段 ⑥：`先 Read .claude/harness/prompt-suffixes/bmad-retrospective-suffix.md`——Form 1 action-items 格式 + 每项 `**Category**: dev|harness` 声明 + pre-retro self-audit（`run_retro_self_audit.sh <prev_epic_num>` 输出是表格时 paste 进 §2 cross-reference 草稿；输出 `RETRO_SELF_AUDIT: no-config` 时不贴）。**Category 声明被真实消费**：harness-commit.py stage 6 commit 时 `_parse_retro_action_items` 解析出 `(code, title, category)` 三元组，seeder 写 `retro_action_items.<id>.category` 子键（stage 6-5 不做 seeding，仅给已处理条目补 `chore_spec` 子键），pre-commit gate ① 按 dev 阻 / harness WARN 分流（§六 Q4）。§0.C retro-only 路径同样必须带本契约段

### 通道 2：`harness-prompt-suffix.py <stage>` stdout 拼接（build / implement / chore / 4 / 6；旧流水线 1 / 2 / 5。`3` 仍保留但 0.3.1 起不再使用：B2.2 改由主 agent 直接跑 `run_codex_review.sh`，不再派子 agent）

每个子 agent prompt 末尾拼 `python3 .claude/harness/scripts/harness-prompt-suffix.py <stage>` 的 stdout，自动包含：

- 代答政策附带段（通用原则引用 `answer-policy.md`；项目语境从 yaml `extra.project_context` 内联）
- §1.x 断点续作约定（deterministic 续作三段，主 agent 不得手写"前情提要"）
- `implement` 块：Q6 全栈贯通 sub-bullet（从 yaml `extra.fullstack_review_steps` 渲染；答复体例 reference 指向 `bmad-build-implement-suffix.md` Q6 段）；旧流水线 stage 2 另有 deferred-work schema v1 扫描约定（§L）

### 通道 3：C11 deferred 注入段（B1 Build intent 内）

`grep_pending_deferred_for_story.sh <KEY>` 的命中结果作为机器注入段（带显式分隔符）放进 B1 的 Build intent——"本 story 应消化 N 条 deferred FU"。bmad-build-auto 把它当规划上下文，按 `bmad-build-auto-suffix.md` §3 决定纳入与否。

0.3.3 起注入段分两部分：`[target:Story X.Y]` 的条目，以及 `[epic-backlog]` 之后同 epic 的 `[target:Epic N]` 条目。build-sync 从 spec `deferred:` 导入的延后项一律是 `target:Epic N`，以前没有任何 story 能匹配到，只会一直挂着。现在同 epic 后面的 story 能看到它们（门槛比指名的条目高），epic 收尾时 retro 再用 `--epic N` 把剩下的逐条改到具体去处（见 `bmad-retrospective-suffix.md`「deferred-work 分诊」）。

项目自己的 BMad 覆盖写在 `_bmad/custom/<skill>.toml`（例如把 codex 挂成 bmad-build-auto 的 review layer），由 BMad skill 自身加载，harness 只读不写（`build_auto_codex_layer_ids` 探测）。旧文档里的 `_bmad/customize/` 目录名从来不对，已更正。

---

## 十一、通用化与项目 config（chore-test-harness-conditional-triggers 沉淀）

Harness 的项目特定字段已经解耦到一个 yaml，clone 到新项目时改它即可，不再需要全文 sed Aegis-specific 字符串。

本节标题里的 chore 当初也落了 9 个 testarch skill 的条件触发（`test-stage-triggers.yaml` + `eval_test_stage_triggers.sh`），0.3.0 随测试阶段一起移除，下文只保留 config 部分。

### 关键文件

| 文件 | 作用 | 单一来源（SoT）字段 |
|---|---|---|
| `.claude/harness/harness-project-config.yaml` | 项目 config：必填字段 + extra map 扩展 | `project_display_name` / `container_orchestrator` / `frontend_framework` / `backend_languages` + extra（如 `frontend_dir` / `container_count` / `i18n_locales`）。`e2e_framework`、`extra.e2e_test_subdir` 已在 0.3.0 退役 |
| `.claude/harness/scripts/simulate_clone_test.sh` | self-test：mktemp + cp 三件套 + 改 config + 跑部署副本 | exit 0 = 通用化无遗漏 |

### 跨项目 clone 验证

`.claude/harness/scripts/simulate_clone_test.sh` 物理验证：mktemp -d → cp 三件套（CLAUDE.md / .claude / .claude/harness/scripts / .claude/harness/git-hooks）→ 写最小 project config → 跑 install_git_hooks → assert harness 元文档零 Aegis 硬编码。落地后每条新 chore self-test 都过一遍此 simulate（CI 友好）。

### 路径与模块外化（chore-harness-path-externalization 沉淀）

C-path-externalization 落地后，三类项目特定值从脚本硬编码移出，进入 `harness-project-config.yaml`：

| 字段 | 位置 | 类型 | 说明 |
|---|---|---|---|
| `artifacts_root` | 一级 | 字符串（相对仓库根） | artifact 输出根（默认 `_bmad-output/implementation-artifacts`）；新项目可改 `docs/specs` 等 |
| `extra.path_classifiers` | 二级 | list of {label, regex} | `harness-state.py` resume-prompt 用，按改动文件路径打 label 桶；空 list 合法（全归 "other"） |
| `extra.verification_commands` | 二级 | 多行 `\|` 块字符串 | `harness-state.py` resume-prompt 引用的 verification 引导文本 |

**两个 helper（all scripts 唯一来源）**：

- `.claude/harness/scripts/harness_config.py` — Python 端，hand-rolled YAML 解析（no PyYAML dep，与 sprint-status.py 同手法）。暴露 `get_artifacts_root() / get_sprint_status_path() / get_deferred_work_path() / get_path_classifiers() / get_verification_commands()` 5 函数。
- `.claude/harness/scripts/read_harness_config.sh` — bash 端，sources 后暴露 `read_harness_config_field <key> [default]` 函数 + `HARNESS_REPO_ROOT / HARNESS_ARTIFACTS_ROOT / HARNESS_SPRINT_STATUS_PATH / HARNESS_DEFERRED_WORK_PATH` env vars。

**Fallback 准则**：字段缺失 / yaml 文件缺失 / yaml 损坏 → fallback to hardcoded default + stderr WARN（fail-open）。新项目第一次 clone 时不会因缺字段崩。

**不做**：① slash command（run-sprint.md 等）prose 不外化（散文级路径示例，模板化是后续 chore）；② commit message 模板 / 5-stage 状态机命名不外化（架构层硬约定）。

### `/super-harness:init` — clone-time / mid-project 一次性 yaml 同步（chore C-run-sprint-init 沉淀）

`harness-project-config.yaml` 是 harness 跨脚本的项目配置 SoT。其 BMad-sourced 提取字段（编号 1-16，其中 5 `e2e_framework`、7 `extra.e2e_test_subdir` 已在 0.3.0 退役，实际提取 12 描述 + 2 注入语境：`extra.project_context` / `extra.fullstack_review_steps`）的事实源头是 BMad planning artifacts（`product-brief.md` / `prd.md` / `architecture/tech-stack.md` / `architecture/repo-structure.md`）；另有 3 个派生字段不读 BMad（见下）。手填易漂移、新项目 clone 启动门槛高 — `/super-harness:init` 一次性把 BMad → yaml 同步。

**触发场景**：
- ① clone harness 到全新项目（空 yaml + 完整 BMad 产物）→ 全部字段填上
- ② mid-project 启用 harness（部分手填 yaml + 完整 BMad）→ merge：既有字段保留 + 缺失字段补全

**调用形式（LLM-orchestrated；与 `/super-harness:run-inline` 同款）**：

```
/super-harness:init               # 默认 merge — 已存在字段不动 + 缺失字段补全
/super-harness:init --dry-run     # 仅 stdout 列 diff，0 写入
/super-harness:init --force       # 覆盖既有值（含手改字段）；先列 "field: old → new" + 二次确认
```

**Prerequisite gate（3 必需 + 1 可选；单文件、BMad 6.12+ 运行目录、sharded 三种布局都接受）**：

| 概念产物 | 必需性 | 接受的形式（按顺序认） | 引导 BMad skill |
|---|---|---|---|
| prd | **必需** | `prd.md` → `prds/prd-<项目>-<日期>/prd.md` → sharded `prd/` | `/bmad-prd` |
| architecture | **必需** | `architecture.md` → `architecture/architecture-<项目>-<日期>/ARCHITECTURE-SPINE.md` → sharded `architecture/`（目录下要直接有 `.md`） | `/bmad-architecture` |
| sprint-status | **必需** | `<implementation_dir>/sprint-status.yaml` | `/bmad-sprint-planning` |
| product-brief | **可选**（缺仅 WARN，不阻流）| `product-brief*.md`（glob，上游含项目名后缀）→ `briefs/brief-<项目>-<日期>/brief.md` | `/bmad-product-brief` |

> **三种布局都是 BMad 上游合法布局**：BMad 6.12 起这三个 skill 默认写进带日期的运行目录，位置由各自 `customize.toml` 的 `<x>_output_path`、`run_folder_pattern` 决定（`_bmad/custom/` 可覆盖），helper 照这些配置找；更早的版本产单文件；用户跑过旧版 `/bmad-shard-doc` 的是 sharded 形式。有多个运行目录时 `status: final` 优先，再取日期最新的。super-harness 对三者无偏好。
>
> ux-design / epics 等其他 BMad 产物（`ux-design-specification.md` 单文件 vs `ux-design-specification/` sharded、`epics.md` vs `epics/`）当前**未在 harness-zh 任何运行时路径引用**（不在 §A.5 检测、不在 §2 字段提取、不在 retro 审计）；信息从 sprint-status.yaml + PRD + architecture 间接获取，未来若加 hard ref 需同步加多布局检测。

helper：[`scripts/run_sprint_init_check_prereq.sh`](scripts/run_sprint_init_check_prereq.sh) — exit `0`（全部 MUST-EXIST 在位）/ `2`（BMad planning artifact 缺失 → stderr 引导）/ `3`（sprint-status.yaml 缺失 → 引导 `/bmad-sprint-planning`）/ `1`（参数 / 内部错误）；JSON stdout（含 `optional_missing` 字段，以及实际命中的 `prd_path`、`architecture_path`、`product_brief_path` 和各自的布局 `*_form`）+ 引导 stderr。

**字段 mapping 概要**（详 [`commands/init.md`](commands/init.md) §2 — 表格用 sharded 路径写 source 列，LLM 提取时按 helper 给的 `*_path`、`*_form` 读：sharded 读子文件，单文件和运行目录按章节找）：

| yaml field | BMad source（sharded 形式 / 单文件章节）| 提取语义 |
|---|---|---|
| `project_display_name` | product-brief*.md / prd.md | 产品名 / 项目代号 |
| `container_orchestrator` | architecture/tech-stack.md / architecture.md §tech-stack | 容器编排（docker-compose / k8s） |
| `frontend_framework` | architecture/tech-stack.md / architecture.md §tech-stack | 前端框架（Next.js / SvelteKit） |
| `backend_languages` | architecture/tech-stack.md / architecture.md §tech-stack | 后端语言列表（Go / Python / Rust） |
| ~~`e2e_framework`~~ | — | 0.3.0 退役，不再提取 |
| `extra.frontend_dir` | architecture/repo-structure.md / architecture.md §repo-structure | 前端代码目录 |
| ~~`extra.e2e_test_subdir`~~ | — | 0.3.0 退役，不再提取 |
| `extra.container_count` | tech-stack.md / architecture.md §tech-stack | 服务容器数量 |
| `extra.i18n_locales` | architecture/i18n.md / architecture.md §i18n（NICE） | 前端国际化语种 |
| `extra.routing_pattern` | i18n.md / tech-stack.md（NICE） | 路由模式 |
| `extra.proxy_addon` | architecture/proxy*.md / architecture.md §proxy（NICE） | 代理插件 |
| `extra.sandbox_constraint` | architecture/nfrs.md / architecture.md §nfrs（NICE） | 沙箱资源约束 |
| `extra.resource_baseline` | architecture/nfrs.md / architecture.md §nfrs（NICE） | 资源 baseline |
| `extra.backend_modules` | architecture/repo-structure.md / architecture.md §repo-structure | 后端模块列表 |
| `extra.project_context` | product-brief*.md / prd.md | 产品定位 + 关键决策原则段（多行 `\|` 块，6-10 条）；subagent 按 answer-policy.md 自决时的项目语境，由 `harness-prompt-suffix.py` 内联注入 |
| `extra.fullstack_review_steps` | architecture/data-model.md / component-architecture.md / repo-structure.md | 核心数据流 7 段追溯清单（list of {label, file_path}）；dev-story Q6 全栈贯通 review 由 `harness-prompt-suffix.py` stage 2 渲染；空 list → Q6 整段降级跳过 |

派生字段（3 个；不读 BMad，基于上述描述字段拼模板）：
- `artifacts_root` — 默认 `_bmad-output/implementation-artifacts`（yaml 已设则保留）
- `extra.path_classifiers` — 基于 `frontend_dir` + `backend_modules` + `backend_languages` 条件分支生成 list of regex；上游缺失 → fallback Aegis 默认 11 条 + WARN
- `extra.verification_commands` — Q5 三组合（Go/TS / Python/TS / Rust/TS）模板拼接；其它栈 fallback `# TODO: ...` placeholder + WARN

**LLM-driven 提取**（不写 grep/awk 解析）：BMad markdown 段标题 / 段位置不严格固定（中英文 / 编号前缀 / 同义词都漂移），LLM 用 Read 工具 + 语义检索（"找前端框架" 而非 "读 ## Frontend 段"）天然 robust。代价仅 init 一次性 token；平时所有 script call 仍是 grep yaml 零 LLM 成本。

**写入策略（Q2 / Q3 / Q6）**：
- Edit 工具逐字段替换（保留顶部 schema 文档注释）
- merge 模式：既有不动 + 缺失补全；force 模式：列 "field: old → new" + 二次确认 prompt → 全替换
- 写完跑 `harness_config.py check`（0.3.1 起；退出码非 0 才回滚，`WARN` 行不算）；fail → rollback yaml + halt。init 不再跑 `simulate_clone_test.sh`，它只适用于本仓库的部署树
- **不**自动 commit yaml — solo-dev review 后自决（与 §-1.d "禁止主 agent 自己 git 操作"同精神）

**self-test**：[`scripts/run_sprint_init_test.sh`](scripts/run_sprint_init_test.sh) — 3 fixtures（全新 / mid-project / MUST-EXIST 缺失）；mechanically 测 §1 prereq gate 行为，§2-§4 LLM-driven 部分由人工 spot-check（`--dry-run` 真实跑 + 字段填值合理性）。

### 老 chore spec 的 frozen 边界

C-cond-triggers 落地前的老 chore spec（c1-A1 / c2-B5 等含 "7 容器栈" / "console-api" 硬编码）**不回填**——已 frozen done 的历史快照。通用化效力从本 chore 落地后下一条新生成 chore（如 epic-4 stage 6.5 输出的 c4-* spec）起；fresh agent prompt 加"用 placeholder"约束防止再次硬编码。

### 不做（决策边界）

- ❌ yq / Python / Node 依赖（与 C1 / C12 同款）— 纯 bash + grep + awk + sed
- ❌ 回填老 chore spec（c1-A1 等保留 Aegis 历史快照）
- ❌ 强制 sed pre-process 文档占位符（占位符按需替换 — 多数场景由阅读者上下文理解）

---

## 十二、目录布局（按功能分组；0.3.1 对照 `ls` 实况更新 — 项目侧 `.claude/harness/` 下 scripts 71 + prompts 2 + suffixes 3 + conventions 1 + templates 4 + git-hooks 1；slash 命令 8 个由 plugin 提供）

> 维护契约：新增脚本 / convention / template / hook 时同步在本段加一行（位置 = 对应功能组末尾）。本段是 onboarding / 自查的功能视角索引，与 [`changelog.md`](changelog.md)（时间视角）+ [`scripts/deploy_assets.sh`](scripts/deploy_assets.sh)（分发清单 SoT：`REQUIRED_TOP_FILES` + `SUBDIRS`）三视角互补。
>
> **真实文件数请以 `ls plugins/super-harness/scripts/ commands/ templates/` 为准** —— 本段树形图随 plugin 版本可能落后；如发现不一致以实际文件系统为准（上次全量核对：2026-06-10 / v0.1.38）。

### 12.1 全树（标 portable / project-specific / 归属）

> **三块归属**：(A) **harness-owned** — 本仓库 chore 立的资产，clone 时必带；
> (B) **BMad-installer-managed** — BMad install 时生成 / 用户改的，新项目自己跑 BMad install 会重生（cloning 也行，更便利）；
> (C) **project-specific** — 项目代码 / 产出，不进 harness clone。

```
. (project root)
│
├── CLAUDE.md                                ← (A) harness 入口（起步约定 / chore 实施流程 / 严格禁止；含 ${project_display_name} 占位符）
│
├── .claude/                                 ← (A) 100% harness-owned
│   ├── （slash 命令不复制进项目。8 个命令 init / update / run-inline / run / board / codex-catchup /
│   │    report-issue / upgrade-deferred-work 由 plugin 以 /super-harness:* 直接提供；harness-zh 时代
│   │    复制进 .claude/commands/ 的副本由 init / update 的 manifest purge 备份后删除）
│   │
│   └── harness/
│       ├── pipeline.md                          ← 单条 story 流水线手册（inline / lane / 调度三种模式共用；100% portable）
│       ├── architecture.md                      ← 设计单一权威来源（本文件；100% portable）
│       ├── architecture-parallel.md             ← 并行调度设计（100% portable）
│       ├── changelog.md                         ← 历史叙事（每条优化追加；100% portable）
│       ├── answer-policy.md                     ← 代答政策 / subagent 通用决策原则（100% portable）
│       ├── harness-project-config.yaml          ← ⚠️ 项目特定（BMad 提取字段 + 3 派生；/super-harness:init 自动同步）
│       ├── parallel.yaml                        ← ⚠️ 项目特定（并行调度配置，含 verify_command；只在不存在时投放，之后不覆盖）
│       │
│       ├── prompts/                             ← 并行调度的子 agent prompt（2 个；100% portable）
│       │   ├── worker.md                        headless worker 的 lane 模式 prompt（跑 B0–B3 后 superh.py report）
│       │   └── merge-fix.md                     合流代码冲突子 agent 的 prompt
│       │
│       ├── conventions/                         ← 数据格式约定（1 个；100% portable）
│       │   └── deferred-work-schema.md          deferred-work.md schema v1（4-tag header；v0.1.38 起无项目专属内容）
│       │
│       ├── git-hooks/                           ← 仓库追踪的 hook 源（1 个；100% portable）
│       │   └── pre-commit                       gate ① retro check（dev 阻 / harness WARN）+ gate ② deferred-work schema
│       │
│       ├── prompt-suffixes/                     ← BMad skill prompt 注入（3 个；100% portable；注入通道详 §十）
│       │   ├── bmad-build-auto-suffix.md        bmad-build-auto 规划契约（slug / context 挂载 / 白名单声明 / C7 继承段；v0.2.0 前名 bmad-create-story-suffix.md）
│       │   ├── bmad-build-implement-suffix.md   实现子 agent 清单（5q gate / mech-verify / Q6 / ledger 格式；v0.2.0 前名 bmad-dev-story-suffix.md）
│       │   └── bmad-retrospective-suffix.md     retro 格式契约（Form 1 + Category 声明 + pre-retro self-audit）
│       │
│       ├── templates/                           ← 投放模板（4 个；100% portable）
│       │   ├── harness-project-config.yaml.template
│       │   ├── deferred-work.md.template
│       │   ├── parallel.yaml                    init 首次投放到 .claude/harness/parallel.yaml
│       │   └── retro-self-audit.tsv.example     0.3.1；项目自查项样例，复制成 .claude/harness/retro-self-audit.tsv 才生效
│       │
│       │   （prompt-templates/ 已于 v0.1.38 停止分发——4 模板停留在 pre-schema-v1
│       │     语义且零运行时引用；下游旧副本由 update 的 manifest purge 对账清掉）
│       │
│       └── scripts/                             ← 71 个文件（运行时脚本 + *_test.sh 回归测试 + 2 个 fresh-agent _prompt.md；除标注 ⚠️ 外均 portable）
│           │
│           ├── [Python 核心 7 个 — 编排 + 状态]
│           │   ├── sprint-status.py             状态文件 CRUD（单行 + 多行块双格式；epic-* key 可读；next 按依赖挑 story；flatten-deps 把多行块改成单行 + 顶层 story_dependencies，0.3.1）
│           │   ├── harness-state.py             单 story 状态检视（build / legacy 双流水线）+ --story-md / --in-flight + halt-recovery-check
│           │   ├── harness_spec.py              spec-<key>.md 解析 / frontmatter 读取（PyYAML 可选）/ codex layer 探测 / spec deferred → FU 导入（v0.2.0）/ story_dependencies 与 ext- 外部条件解析（0.3.1）
│           │   ├── harness-commit.py            commit gate（黑名单双档 / 跨 story / schema 校验 / retro seed / auto-fix binary blob；exit 0/1/2）
│           │   ├── harness-prompt-suffix.py     subagent prompt suffix 注入器（代答政策 inline project_context + Q6 渲染）
│           │   ├── harness_config.py            yaml config reader（never-raise；`check` 子命令做 init 写后校验；get_parked_statuses，0.3.1）
│           │   └── superh.py                    并行调度 CLI（tick / prepare / launch / integrate 含 verify_command 门 / postmerge / board / watch；调度锁 start-run / end-run，0.3.1）
│           │
│           ├── [共享 bash 库 3 个（source 用）]
│           │   ├── read_harness_config.sh       bash 脚本 source 这个拿 config 字段
│           │   ├── deferred_work_schema_lib.sh  retro/deferred parser 文法 + 枚举单一来源（v0.1.38 四份并行实现收敛于此）
│           │   └── prompt_template_lib.sh       ${project_display_name} 占位符渲染共享库（v0.1.38；awk 字面替换）
│           │
│           ├── [Retro 流]
│           │   ├── check_retro_action_items.sh + _test.sh         gate（v2 dev/harness category 分流）
│           │   ├── grep_prev_retro_action_items.sh                上轮 retro action items 提取
│           │   ├── grep_pending_dev_retro_items.sh + _test.sh     §0.A.0 前置 gate 的 pending dev 项扫描（v0.1.33+）
│           │   ├── process_retro_residue.sh + _test.sh + _prompt.md  fresh agent 残留处理 → chore spec + MANIFEST
│           │   └── run_retro_self_audit.sh + run_retro_self_audit_test.sh  0.3.1 起通用化：检查项读项目侧 `.claude/harness/retro-self-audit.tsv`，没有就输出 `RETRO_SELF_AUDIT: no-config`
│           │
│           ├── [Deferred-work 流]
│           │   ├── grep_deferred_buckets.sh                       bucket 总账（含 §1 §1.1/§1.2/§1.3）
│           │   ├── grep_deferred_status.sh                        schema tag 状态查询
│           │   ├── grep_pending_deferred_for_story.sh + _test.sh  按 story key 找 pending FU
│           │   ├── backfill_resolved_markers.sh + _test.sh + _prompt.md  fresh agent backfill resolved（schema v1 后 deprecated；FORCE_LEGACY_BACKFILL=1 才跑）
│           │   ├── detect_deferred_work_schema.sh                 v0.1.13 新增；扫 deferred-work.md 算 v1 conformance（pristine/v1_clean/mixed/legacy）
│           │   ├── lint_deferred_work.sh + _test.sh               deferred-work.md schema lint
│           │   ├── diff_guardrail.sh                              backfill 改动越界守门
│           │   └── pre_commit_deferred_schema_test.sh             pre-commit gate ② 测试
│           │
│           ├── [codex 降级链（v0.1.27+）]
│           │   ├── run_codex_review.sh + _test.sh                 B2.2 codex 审查（0.3.1；主 agent 直接跑，600 s 超时，首行 CODEX_STATUS:，报告由脚本拼装）
│           │   ├── check_bmad_runtime.sh                          BMad 6.11+ 运行条件探测（uv / bmad-build-auto / render_skill.py / 嵌套子 agent；run §0.A 硬检查、init advisory，v0.2.0）
│           │   └── check_codex_availability.sh                    codex-in-cc 可用性探测（run.md B2.0 / codex-catchup 共用）
│           │
│           ├── [Plugin issue 直通管道（v0.1.26 替代 v0.1.14 upstream-feedback.md 中转）]
│           │   └── collect_issue_context.sh                       拼 issue body（plugin 版本 / sprint/story 状态 / halt 现场 / 近期 commits）；由 /super-harness:report-issue 调用 → gh CLI 直提
│           │
│           ├── [Spec 质量 gate]
│           │   ├── check_spec_length.sh                           spec 长度上限
│           │   ├── check_inheritance_block.sh + _test.sh          epic 第一 story 继承段约束
│           │   ├── check_q6_in_dev_record.sh + _test.sh           全栈贯通 review 段格式
│           │   └── extract_d_decisions.sh                         spec D-decisions 提取到独立文件
│           │
│           │   （Test harness 组的 check_test_harness_env.sh / bootstrap_test_harness.sh /
│           │     eval_test_stage_triggers.sh 已于 0.3.0 随测试阶段移除）
│           │
│           ├── [Bootstrap / install / 分发 / 发布]
│           │   ├── install_git_hooks.sh + _test.sh                hook 安装（幂等 + backup；exit 0=成功 / 3=hooksPath 良性拒装或保留项目自己的 hook / 1=真实失败）
│           │   ├── run_sprint_init_check_prereq.sh + run_sprint_init_test.sh  /super-harness:init 前置检查（exit 0/2/3）
│           │   ├── discover_plugin_root.sh                        init/update 探测 plugin 安装路径
│           │   ├── deploy_assets.sh                               资产投递（cmp/backup/overwrite + manifest + DEPLOY_PURGE 对账；备份放 .claude/harness/.backup/<TS>/，0.3.1）
│           │   ├── ensure_gitignore.sh + gitignore_policy_test.sh  补 .gitignore 规则：部署资产忽略、两份配置入库（0.3.1）
│           │   ├── release_check.sh                               发布前版本一致性门（CI source-tests 跑）
│           │   └── simulate_clone_test.sh                         clone 通用化回归测试（CI bootstrap-tests 实跑；run_all_tests 唯一 KNOWN_STALE）
│           │
│           └── [测试 runner + 横切回归测试]
│               ├── run_all_tests.sh                               glob sweep 全部 *_test.sh（--strict 模式；CI 三 job 详 §〇.6）
│               ├── harness_commit_issue5_test.sh                  issue #5 三连修回归（base-26 / locale 白名单等）
│               ├── harness_commit_blacklist_test.sh               安全门双档回归（v0.1.38）
│               ├── harness_commit_planning_artifacts_test.sh      planning_artifacts 白名单回归
│               ├── harness_commit_process_marker_test.sh          过程 marker 自动剔除回归
│               ├── harness_commit_rename_submodule_test.sh        改名新旧路径都检查、子模块未跟踪文件不 halt（0.3.1）
│               ├── pre_commit_gate_test.sh                        hook 大提交不被 SIGPIPE 绕过、首次 retro 前不误拦、产物路径来自配置（0.3.1）
│               ├── parked_deps_test.sh                            story_dependencies / ext- 外部条件 / parked_statuses / epic_barrier / flatten-deps（0.3.1，issue #14 #15）
│               ├── sprint_status_format_test.sh                   单行/多行块双格式回归（44 断言，v0.1.38）
│               ├── deploy_assets_purge_test.sh                    DEPLOY_PURGE manifest 删除路径回归（22 断言，v0.1.38）
│               ├── read_harness_config_issue7_test.sh             issue #7 _RHC_THIS 回归
│               ├── retro_category_round_trip_test.sh              Category 声明 → category 子键消费链回归（v0.1.38）
│               ├── retro_fulfill_stage_test.sh                    §0.A.0 retro-fulfill stage 回归
│               ├── harness_config_test.sh                         harness_config.py 回归
│               ├── harness_prompt_suffix_test.sh                  harness-prompt-suffix.py 回归
│               ├── build_pipeline_test.sh                         v0.2.0 build 流水线回归（build-verify / build-sync / 状态机 / action-status / runtime probe / gate ① 正则；0.3.0 加退役 stage 拒绝）
│               ├── orchestration_observations_test.sh             chore-harness-epic-4-orchestration 回归（0.3.0 去掉 stage 5.5 组后 23 项）
│               └── superh_test.sh                                 并行调度回归（假 claude 扮 worker：就绪判定 / 合流 / 合流验证门 / 冲突 / 收口；0.3.1 加中断计数、held 分类、进程组、调度锁、存活判断）
│
└── _bmad/
    ├── custom/                                  ← (B) BMad 的覆盖目录（installer 生成骨架；项目自己维护 <skill>.toml，harness 只读）
    │   ├── config.toml                          Team/enterprise BMad overrides（committed）
    │   ├── config.user.toml                     Personal BMad overrides（gitignored）
    │   └── bmad-build-auto.toml                 （可选）项目自定义 review layer，例如 codex-cross-model —— harness B2 据此决定是否跳过外部 codex
    │
    └── _config / bmb / bmm / cis / core / scripts / tea  ← (B) BMad upstream（installer 管；新项目自己跑 BMad install 重生）
```

**(A) harness-owned** = 必带 clone — `CLAUDE.md` + `.claude/` 全树（plugin 化之前的布局里还有 `_bmad/customize/` 2 个 toml；该目录名不是 BMad 的覆盖目录，从未被 BMad 加载，v0.2.0 起不再提）

**(B) BMad-installer-managed** = `_bmad/custom/` + `_bmad/_config / bmb / bmm / cis / core / scripts / tea` — 新项目可选两种姿势：① 把 `_bmad/custom/` 也整体 cp（图省事，simulate_clone_test 走的是这条）；② 在新项目跑 BMad install 重生（更干净，但需要新跑一遍 BMad onboarding）。其它 BMad 上游目录（`_config / bmb / bmm` 等）**强烈建议方式 ②** — cp 过去 + BMad 后续升级会冲突

**(C) project-specific** = `_bmad-output/`（项目产出区）+ 项目源码 + 项目自己的构建脚本 — 不进 harness clone（harness 自身不携带任何 just recipe / Justfile；所有入口都是 `bash .claude/harness/scripts/<name>.sh` 或 `python3 .claude/harness/scripts/<name>.py`）

### 12.2 Clone 拷贝清单（[`scripts/simulate_clone_test.sh`](scripts/simulate_clone_test.sh) 已实现）

| 拷 | 路径 |
|---|---|
| ✅ | `CLAUDE.md` |
| ✅ | `.claude/harness/`（整个目录；命令由 plugin 提供，不在项目里） |
| ✅ | `_bmad/custom/` |
| ❌ | `_bmad-output/`（项目产出区 — story specs / chore / retro / sprint-status / deferred-work） |
| ❌ | 项目源码与项目自身构建脚本（Justfile / Makefile 等 — 与 harness 无关，harness 不再有任何 just recipe） |

### 12.3 Clone 后必改文件（🔧）

| 文件 | 改什么 | 自动化 |
|---|---|---|
| `.claude/harness/harness-project-config.yaml` | BMad-sourced 字段（12 描述 + 2 注入语境：project_context / fullstack_review_steps；e2e 两个字段 0.3.0 退役）+ 3 派生字段 | ✅ `/super-harness:init` 自动从 BMad planning artifacts 提取 |
| `.claude/harness/retro-self-audit.tsv` | 0.3.1 起脚本本身不再写死检查项。需要 retro 前自查时按 `templates/retro-self-audit.tsv.example` 写这个文件；不写就跳过 | 可选 |

**不需要再改的文件**（已通过 yaml-driven 动态注入解耦项目特定）：
- `.claude/harness/answer-policy.md` — 项目语境段已删除；改 yaml `extra.project_context` 即可（subagent 通过 `harness-prompt-suffix.py` inline 注入拿到）
- `.claude/harness/prompt-suffixes/bmad-build-implement-suffix.md` Q6 段 — 项目特定 sub-bullet 清单已抽到 yaml；改 yaml `extra.fullstack_review_steps` 即可（实现子 agent 通过 `harness-prompt-suffix.py implement` 渲染拿到）

**新项目 onboarding 三步**：
1. clone 整个 `.claude/` + `_bmad/custom/` + `CLAUDE.md`
2. 跑 `/super-harness:init` 让主 agent 从 BMad planning artifacts 自动填字段到 `harness-project-config.yaml`
3. （0.3.1 起不需要）`run_retro_self_audit.sh` 已通用化，项目自查项写在 `.claude/harness/retro-self-audit.tsv`

# ${project_display_name} Harness 自动化架构

> **分发模型**：harness-zh 以 Claude Code plugin 形式分发（仓库 [`Niutie/my-cc-plugin`](https://github.com/Niutie/my-cc-plugin)）。每个项目通过 `/harness-zh:init` 把 plugin 资产投递到 `.claude/harness/` + `.claude/commands/`；详 §〇「Plugin 分发模型」。原"clone harness 到新项目"机制（§十一）已由 plugin 自动化替代，§十一 保留作 yaml schema 与字段提取设计的动机记录。
>
> **占位符替换**：本文档读 [`harness-project-config.yaml`](harness-project-config.yaml)（部署到项目侧 `.claude/harness/` 的副本）解析 `${project_display_name}` 等占位符；新项目跑 `/harness-zh:init` + BMad workflow 后该 yaml 自动填充。
>
> 本文档是 harness 元设计的**单一权威来源**——后续讨论"harness 自动化怎么走"先 reference 本文。

---

## 〇、Plugin 分发模型

### 〇.1 三层架构（marketplace → plugin store → project）

```
┌──────────────────────────────────────────────────────────────────┐
│            GitHub: Niutie/my-cc-plugin (private)                 │
│                                                                  │
│  .claude-plugin/marketplace.json  (列 plugin 清单)               │
│  README.md                                                       │
│  plugins/harness-zh/                                             │
│    ├─ .claude-plugin/plugin.json                                 │
│    ├─ commands/   ← init / update / run / run-test (.md)         │
│    ├─ scripts/    ← harness 运行时脚本（~40 个）                 │
│    ├─ conventions/ + prompt-suffixes/ + prompt-templates/        │
│    ├─ git-hooks/pre-commit                                       │
│    ├─ templates/harness-project-config.yaml.template             │
│    └─ architecture.md / answer-policy.md / changelog.md          │
└─────────────────────┬────────────────────────────────────────────┘
                      │ /plugin marketplace add Niutie/my-cc-plugin
                      │ /plugin install harness-zh@my-cc-plugin
                      ▼
┌──────────────────────────────────────────────────────────────────┐
│   ~/.claude/plugins/<...>/harness-zh/  (Claude Code plugin store)│
└─────────────────────┬────────────────────────────────────────────┘
                      │ /harness-zh:init  (一次/项目)
                      │ /harness-zh:update  (plugin 升级后)
                      ▼
┌──────────────────────────────────────────────────────────────────┐
│                       <user-project>/                            │
│  .claude/harness/                                                │
│    ├─ scripts/ + conventions/ + prompt-suffixes/ + ...           │
│    ├─ git-hooks/pre-commit                                       │
│    ├─ harness-project-config.yaml ← 项目特定，update 不覆盖     │
│    ├─ architecture.md / answer-policy.md / changelog.md          │
│    └─ test-stage-triggers.yaml                                   │
│  .claude/commands/                                               │
│    └─ init.md / update.md / run.md / run-test.md                 │
│  .git/hooks/pre-commit ← install_git_hooks.sh 装                 │
│  _bmad-output/  (用户跑 BMad workflow 后产出，harness 读)        │
└──────────────────────────────────────────────────────────────────┘
```

### 〇.2 为什么是 asset deployer 而不是 runtime container

理论上 plugin 可以让 commands 直接通过 `${CLAUDE_PLUGIN_ROOT}` 引用 plugin 内资产，runtime 无需项目副本。**但实际撞两堵墙**：

1. **Git pre-commit hook** 在 git 上下文跑（非 Claude Code），`${CLAUDE_PLUGIN_ROOT}` 不可用 → hook 必须用 project-relative 路径
2. **Markdown slash-command bash 块** 在 commands 上下文（per [Anthropic plugins docs](https://code.claude.com/docs/en/plugins.md)）**不保证**注入 `${CLAUDE_PLUGIN_ROOT}` —— 该变量明确文档化于 hooks 上下文，commands 上下文未提及

所以 harness-zh 走"plugin = 源；project = 部署副本"模式：
- Plugin 是 source of truth（marketplace 唯一升级路径）
- Project 是 deployed copy（runtime 实际操作的对象）
- Sync 通过 `/harness-zh:update`（cmp + backup + overwrite，不丢用户本地修改）

代价：每个项目带一份资产副本（增加少量磁盘占用）；好处：所有现有路径引用（`.claude/harness/scripts/...` 等）零改动可用，git hook + markdown command bash 都跑得了。

### 〇.3 六个命令的分工

| 命令 | 职责 | 何时跑 |
|---|---|---|
| `/harness-zh:init` | 首次 bootstrap — mkdir 项目目录 → 探测 plugin path → cmp/backup/overwrite copy 资产 → 投放 yaml template（仅当不存在）→ 装 git hooks → 检测 BMad → 齐则进 §十一 14 字段提取 / 缺则报告引导。**v0.1.13+** 半路接入项目时还检测 `deferred-work.md` schema state（§A.3.c 三档分支）；**v0.1.26+** §A.3.d 改为纯 advisory（不再迁移 category:harness 残余 — upstream-feedback.md 通道已退役，由 `/harness-zh:report-issue` 替代）。 | 1 次/项目；后续 BMad 补齐后可重跑（merge 模式补填 yaml 空字段） |
| `/harness-zh:update` | 升级后刷资产 — 同 init 部署逻辑但**不**投 yaml、**不**跑 BMad 提取；只 sync `.claude/harness/*` + `.claude/commands/*` + 重装 git hooks | 每次 `/plugin marketplace update my-cc-plugin` 后 |
| `/harness-zh:run` | runtime sprint loop — 详 §一-§五 | 日常开发主入口 |
| `/harness-zh:run-test` | runtime test sub-loop — 详 §一 | 由 run 触发或手工 |
| `/harness-zh:upgrade-deferred-work` | **v0.1.13+** 事后 deferred-work.md schema 复测 + mode 切换。跑 detector → 给三档（advisory / archive+greenfield / 手工 backfill 指南）→ 应用选择。供 init 时选 advisory 后想切回 strict、或手工 backfill 完想验证的场景。 | Ad-hoc，按需 |
| `/harness-zh:report-issue` | **v0.1.26+** 一键给 plugin 作者提 GitHub issue。自动收集 plugin 版本 / 当前 sprint+story 状态 / halt 现场 / 近期 commits 等上下文，gh CLI 直提到 `Niutie/my-cc-plugin`。halt 场景提完会附临时绕过方案，让用户不必等 plugin 修复就能继续推进项目。 | halt / 阶段收尾 / ad-hoc 任意时机 |
| `/harness-zh:codex-catchup` | **v0.1.27+** 补跑被 `/harness-zh:run` 因 codex-in-cc 不可用（未装 / 配额耗尽 / 未登录）跳过的 stage 3+4。扫 `_bmad-output/implementation-artifacts/*.codex-skipped.json` marker → 对每条 KEY 重跑 stage 3 codex review + stage 4 dev fix → 归档 marker 为 `*.codex-skipped.resolved.json`。本命令开头会再跑一次 `check_codex_availability.sh` 探测；codex 仍不可用直接 halt（不静默重跳过）。 | codex 恢复后 |

### 〇.4 与 §十一「通用化与项目 config」的关系

§十一 设计于 plugin 化之前，描述"clone harness 到新项目 + 改 5 必填字段 + 自填 extra map"的通用化方案。

- **用户层流程**已被 plugin 模型替代：不再 clone 文件，而是装 plugin + 跑 `/harness-zh:init`
- **底层数据契约**（14 字段 mapping、merge 模式 / `--dry-run` / `--force`、yaml schema）未变 —— `/harness-zh:init` §0-§6 直接复用 §十一 设计的提取逻辑

§十一 保留作设计动机 + schema 文档；运行机制以本节 + [`commands/init.md`](commands/init.md) + [`commands/update.md`](commands/update.md) 为准。

### 〇.5 依赖

`plugin.json` 声明的硬依赖（缺则装 harness-zh 时 Claude Code halt）：
- **`codex`**（marketplace `openai-codex`）— 提供 `/codex:rescue` 用于 §一 stage 3 对抗 review

未声明 plugin dep 但**前置必需**（README 列）：
- **BMad workflow toolset**（`/bmad-create-prd`、`/bmad-create-story`、`/bmad-dev-story`、`/bmad-retrospective` 等 ~30 命令）— 因为 BMad 在多数环境是项目 `.claude/skills/bmad-*` 形式而非 Claude Code plugin，无法用 `dependencies` 字段声明；缺则 `/harness-zh:init` §A.5 检测会报 "BMad artifacts 缺失" 早结束

---

## 一、三循环总览

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        solo-dev 触发器                                       │
└──────────┬─────────────────────────┬─────────────────────────┬───────────────┘
           │                         │                         │
           ▼                         ▼                         ▼
  ┌────────────────────┐   ┌────────────────────┐   ┌────────────────────┐
  │   /harness-zh:run       │   │   /harness-zh:run-test  │   │   主 agent 手工     │
  │   业务故事循环      │   │   测试循环 (新)     │   │   chore 循环 (元)   │
  │   5-stage + 6 + 6.5 │   │   T1 / T3 / T4      │   │   单 commit         │
  │                     │   │                     │   │                     │
  │   写: dev_status    │   │   写: test_status   │   │   写: retro_action_ │
  │        epic-seq-*   │   │        any key      │   │        items.epic-N │
  └─────────┬───────────┘   └──────────┬─────────┘   └──────────┬─────────┘
            │                          ▲                         ▲
            │ stage 5.5 调用 (Q2 ②)    │                         │
            └──────────────────────────┘                         │
            │ stage 6.5 生成 chore spec                          │
            └────────────────────────────────────────────────────┘

            ▲                                                    │
            │  pre-commit hook (C1)                              │
            │  gate [4-6]-*.md spec 创建                         │
            └────────────────────────────────────────────────────┘
            (retro_action_items 有 pending → 阻断主循环开新 epic)
```

**关键约束**：
- 路径 A 的 key 必须 `epic-seq-slug` 数字开头格式（sprint-status.py epic-of 硬假设）
- 路径 B 的 key 是 `retro_action_items` 的字母数字 code（A1 / B5 / C7 / D2）
- 路径 C 的 key 兼容前两者（test_status 字段不挑 key 格式）

---

## 二、单 epic 完整流水线（端到端展开）

```
solo-dev 跑: /harness-zh:run
   │
   ▼
┌─ epic-N backlog (12 / 9 / 11 stories) ──────────────────────────────────┐
│                                                                         │
│   for each story (N-1, N-2, ..., N-last):                               │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                                                                 │   │
│   │  stage 1: create spec                                           │   │
│   │    ┌──────────────────────────────────────────────────┐        │   │
│   │    │ prompt 头部注入 (C11):                            │       │   │
│   │    │   bash grep_pending_deferred_for_story.sh KEY     │       │   │
│   │    │   → "本 story 应消化 N 条 deferred FU"            │       │   │
│   │    └──────────────────────────────────────────────────┘        │   │
│   │  stage 2: dev (subagent)                                        │   │
│   │    └─ dev 顺手 resolve deferred → inline `Resolved by`         │   │
│   │  stage 3: codex adversarial review                              │   │
│   │  stage 4: dev fix                                               │   │
│   │  stage 5: bmad code-review                                      │   │
│   │                                                                 │   │
│   │  stage 5.5 (Q2 ②): 调 /harness-zh:run-test --story KEY              │   │
│   │    ├─ check_test_harness_env.sh                                 │   │
│   │    │   ├─ docker 可用 → 跑 T3 atdd + T4 e2e                    │   │
│   │    │   │     ├─ green: 写 test_status.KEY.atdd=green           │   │
│   │    │   │     └─ red:   写 deferred-work.md FU-Test-KEY-failing │   │
│   │    │   └─ sandbox 受限 → 写 FU-Test-KEY-sandbox + skip          │   │
│   │    └─ test 失败不阻 stage 6                                     │   │
│   │                                                                 │   │
│   │  → development_status.KEY = done                                │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│   epic-N 全 done 触发 stage 6:                                          │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │  stage 6: /bmad-retrospective --epic N (non-interactive)        │   │
│   │    → epic-N-retro-YYYY-MM-DD.md                                 │   │
│   │    (内含 D1-Dn 共 m 项 action items)                            │   │
│   │                                                                 │   │
│   │  stage 6.5 (C10): just process-retro-residue EPIC=N             │   │
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
   │  /harness-zh:run 主循环准备进 epic-(N+1)
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
              ┌─────────────────────────┐  /harness-zh:run 进 epic-(N+1)
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
                    /harness-zh:run 进 epic-(N+1) (循环到顶)
```

---

## 三、闭环关系（数据流）

```
┌──────────────┐                          ┌──────────────┐
│ run-sprint   │                          │ deferred-    │
│ stage 5.5    │  写 FU-Test-KEY-failing  │ work.md      │
│ test 失败    │ ────────────────────────►│              │
└──────────────┘                          │ 200+ FU 项   │
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
│   .development_status.<epic-seq-key> │ run-sprint stage 1-5    │ 5-stage 推进        │
│   .test_status.<key>.atdd            │ run-test-sprint T3      │ atdd 跑出 verdict  │
│   .test_status.<key>.e2e_last_run    │ run-test-sprint T4      │ e2e 完成           │
│   .retro_action_items.epic-N.<code>  │ stage 6.5 (C10) seed    │ epic 收尾自动       │
│     .chore_spec: <path>              │ stage 6.5 (C10) 写       │ chore 生成时        │
│     status: pending → done           │ 主 agent 手工翻         │ chore 实施完成     │
│                                      │                         │                    │
│ deferred-work.md                     │                         │                    │
│   FU-X.Y.Z bullet                    │ run-sprint stage 2/5    │ dev / review 留 FU │
│   ` — Resolved by Story X.Y` inline  │ run-sprint stage 2 dev  │ 顺手 resolve      │
│   ` — Resolved by ...` (回填)        │ C12 一次性 fresh agent  │ 单次 chore 跑      │
│   FU-Test-KEY-failing                │ run-sprint stage 5.5    │ 测试 fail         │
│   FU-Test-KEY-sandbox                │ run-sprint stage 5.5    │ sandbox skip      │
│                                      │                         │                    │
│ test_artifacts/                      │                         │                    │
│   epic-N-test-design.md              │ /bmad-testarch-test-    │ T1                │
│                                      │ design                  │                    │
│   <key>.atdd-checklist.md            │ /bmad-testarch-atdd     │ T3                │
│   <key>-test-result.json             │ run-test-sprint T4      │ T4 完成           │
│   skipped-<key>-<date>.md            │ stage 5.5 graceful skip │ sandbox 受限      │
│                                      │                         │                    │
│ console-web/tests/e2e/               │                         │                    │
│   <key>.spec.ts                      │ /bmad-testarch-atdd     │ T3                │
│   playwright-report/ (gitignore)     │ run-test-sprint T4      │ T4 跑 e2e         │
└──────────────────────────────────────┴─────────────────────────┴────────────────────┘
```

---

## 五、Skill / Hook 调用图

```
                   ┌──────────────────────────────────────┐
                   │ .claude/commands/run.md       │
                   │   (主 orchestrator)                   │
                   └─────┬────────────┬───────────┬────────┘
                         │            │           │
                         ▼            ▼           ▼
                ┌────────────┐ ┌────────────┐ ┌────────────┐
                │bmad-create-│ │bmad-dev-   │ │bmad-code-  │
                │story       │ │story       │ │review      │
                └────────────┘ └────────────┘ └────────────┘
                                                    │
                                                    ▼
                                            ┌────────────┐
                                            │codex:rescue│
                                            │(adversarial│
                                            │ review)    │
                                            └────────────┘
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
                   │ .claude/commands/run-test.md  │
                   │   (测试 orchestrator)                 │
                   └─────┬───────────┬───────────┬─────────┘
                         │           │           │
                         ▼           ▼           ▼
                ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
                │bmad-test-   │ │bmad-test-   │ │bmad-test-   │
                │arch-test-   │ │arch-atdd    │ │arch-automate│
                │design       │ │             │ │             │
                └─────────────┘ └─────────────┘ └─────────────┘

                   ┌──────────────────────────────────────┐
                   │ .claude/harness/git-hooks/pre-commit (C1)       │
                   │   gate [4-6]-*.md 创建                │
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

### Q2 ✅ RESOLVED: stage 5.5 嵌入 — 嵌入

`/harness-zh:run-test` 嵌入 run-sprint stage 5.5（每条 story bmad-code-review 完成后自动调）+ 保留独立入口 `/harness-zh:run-test --story <key>`。stage 5.5 graceful skip（sandbox 无 docker → 写 FU-Test-KEY-sandbox + exit 0）保证不阻 run-sprint 主循环。这是真扩展 run-sprint 5-stage 到 6-stage（不是为残留改主循环——测试本就是开发流水线一环）。

C-bootstrap spec 内部 Q4 已 2026-05-03 标 RESOLVED。

### Q3 ✅ RESOLVED: chore 实施 — 主 agent 自动续作

每次新会话起步主 agent 扫 `retro_action_items.<id>.{status,chore_spec}`，pending 项自动通知 solo-dev + 等指令决定是否进入 chore 实施流程。

具体协议见项目根 [`CLAUDE.md`](../CLAUDE.md)「会话起步约定（chore 自动续作）」段（2026-05-03 同 commit 落地）。

风险缓冲：主 agent **不**在 solo-dev 给其它指令时擅自跑；只在用户肯定回复"继续"时进入 chore 模式；任一步骤失败立即 halt + 报告状态。

### Q4 ✅ RESOLVED 2026-05-05 → SUPERSEDED 2026-05-07 by v0.1.14 → SUPERSEDED 2026-05-09 by v0.1.26：`category:harness` 通过 `/harness-zh:report-issue` 直提 GitHub issue（取消 upstream-feedback.md 中转）

> **Supersession note (v0.1.26)**：v0.1.14 的 `upstream-feedback.md` 中转通道实际运行 ~3 周后发现：用户 review 该文件 → 复制粘贴到 GitHub issue 创建页 → 手填 title / 标 label，仍是 5+ 步手工损耗，多数项目积累几条后就懒得提了，反馈到达率低。v0.1.26 改为**直通管道**：新命令 `/harness-zh:report-issue` 自动收集 plugin 版本 / 当前 sprint+story 状态 / halt 现场 / 近期 commits 拼好 issue body，gh CLI 一键直提到 `Niutie/my-cc-plugin/issues`；halt 场景提完还附临时绕过方案让用户继续推进项目。`upstream-feedback.md` / `extract_harness_feedback.sh` / `detect_harness_residue.sh` / `templates/upstream-feedback.md.template` 全删；retro skill 不再分流（`category: dev` 与 `category: harness` 都写 sprint-status.yaml，仅 pre-commit gate 行为不同 — dev 阻 commit / harness 仅 WARN + hint 跑 `/harness-zh:report-issue`）。`migrated-upstream` status enum 保留兼容（v0.1.14-0.1.25 残余视同 done）。Q4 B 方案的 schema/gate/process 决策仍在。详 changelog v0.1.26。

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
   just process-retro-residue EPIC=1   → ~6 chore-retro-c1-*.md
   just process-retro-residue EPIC=2   → ~8 chore-retro-c2-*.md
   just process-retro-residue EPIC=3   → ~7 chore-retro-c3-*.md
   = 共 ~21 个 chore spec 自动生成
   │
   ▼
5. 实施 C-test-harness-bootstrap
   testarch 三 skill 跑通 + /run-test.md 第一版
   单 commit + 翻 C-bootstrap=done
   (Q2 决策处)
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
/harness-zh:run (无参) 自动跑 epic-4 / 5 / 6
   每条 story 自动走 5-stage + 5.5 (如 Q2 选 ②) + 6 + 6.5
   每个 epic 收尾自动 process-retro-residue 生成新 chore
   主 agent 在新 epic 启动前自动消化 chore (闭环)
```

---

## 八、不在本架构 scope 内（已确认不做）

- ❌ **改 BMad 上游 skill**（`bmad-create-story` / `bmad-dev-story` / `bmad-retrospective`）— C11 用 prompt 拼接绕过
- ❌ **deferred-work.md schema 迁移**（每条 FU 加 frontmatter）— C12 inline 标记够用
- ❌ **为 chore 改 run-sprint 主循环**（让 run-sprint 支持 chore-* 命名空间）— chore 走路径 B 即可
- ❌ **husky / npm prepare 路径** — C1 raw `.git/hooks/` 已落
- ❌ **testarch 9 个 skill 全接通** — 第一版只接 test-design + framework + atdd 三个，automate / nfr / trace / ci / test-review / teach 留 v0.2+

---

## 九、引用

- 4 份 chore spec: `_bmad-output/implementation-artifacts/chore-retro-c10-*.md` / `c11-*.md` / `c12-*.md` / `chore-test-harness-bootstrap.md`
  - C11 / C12 已标 superseded by deferred-work-schema-v1（2026-05-04）— 脚本骨架保留, 解析路径切到 schema tag
- C1 pre-commit hook spec: `_bmad-output/implementation-artifacts/spec-retro-c1-pre-commit-hook-retro-action-items.md`
- run-sprint 主流程: `.claude/commands/run.md`
- 代答政策: `.claude/harness/answer-policy.md`
- sprint 状态机: `.claude/harness/scripts/sprint-status.py` + `.claude/harness/scripts/harness-state.py`
- commit 协议: `.claude/harness/scripts/harness-commit.py`
- **conventions（项目层格式契约）**:
  - `.claude/harness/conventions/deferred-work-schema.md` — deferred-work.md schema v1（FU bullet 4-tag 头 / status / bucket / target / source / 历史 audit log；C11/C12 取代）

---

## 十、Prompt 拼接约定（C11 / A3 / A7 / B2 / B3 / C2 / C3 / C7 / C9 沉淀）

CLAUDE.md 严格禁止动 `.claude/skills/bmad-*/`，因此所有 SKILL 级 enforce
都走 prompt 拼接路径：调 BMad skill 前主 agent 在 user prompt 内 inject
引用项目层 customize / customizations / single-source-of-truth 文件。

### 调 bmad-create-story 时 inject

主 agent 必须在 user prompt 首部 inject 以下引用：

- `_bmad-output/implementation-artifacts/dev-story-self-review-gate.md` — A3 5 问 single source（spec stage subtask 锚）
- `_bmad-output/implementation-artifacts/mech-verify-dry-run-protocol.md` — A7 4 项验证 protocol
- `_bmad/customize/bmad-create-story.toml` — workflow.activation_steps_prepend / tasks_append / finalize_steps_append
- `.claude/harness/prompt-suffixes/bmad-create-story-suffix.md` — Finalize sub-steps + Epic 第一个 story 继承段约束（C7）
- `.claude/harness/prompt-templates/self-review-5q-template.md` / `mech-verify-dry-run-template.md` / `data-visibility-review-template.md` / `deferred-import-status-template.md` — 段模板

### 调 bmad-dev-story 时 inject

- `_bmad-output/implementation-artifacts/dev-story-self-review-gate.md` — 5 问 dev stage 答复
- `.claude/harness/prompt-suffixes/bmad-dev-story-suffix.md` — Standard checklists（5q + mech-verify + Q6 全栈贯通 review）

### 调 bmad-retrospective 时 inject

- `.claude/harness/prompt-suffixes/bmad-retrospective-suffix.md` — Pre-retro hint：跑
  `bash .claude/harness/scripts/run_retro_self_audit.sh <prev_epic_num>` + paste
  到 §2 cross-reference 草稿基础

### Finalize sub-steps 顺序（spec creation）

主 agent 在 spec commit 前必须按顺序跑：

1. `bash .claude/harness/scripts/check_spec_length.sh <spec-path>` — 800 行 hard 上限
2. `bash .claude/harness/scripts/extract_d_decisions.sh <spec-path>` — D-decisions ≥ 5 提议 extract
3. `bash .claude/harness/scripts/check_inheritance_block.sh <spec-path>` — X-1-* 且 X > 1 触发继承段约束

---

## 十一、通用化与项目 config（chore-test-harness-conditional-triggers 沉淀）

Harness 现已 condition-driven + 项目特定字段解耦。clone 到任意新项目时改 1 个 yaml 即生效，不再需要全文 sed Aegis-specific 字符串。

### 关键文件

| 文件 | 作用 | 单一来源（SoT）字段 |
|---|---|---|
| `.claude/harness/harness-project-config.yaml` | 项目 config — 5 必填字段 + extra map 扩展 | `project_display_name` / `container_orchestrator` / `frontend_framework` / `backend_languages` / `e2e_framework` + extra（如 `frontend_dir` / `e2e_test_subdir` / `container_count` / `i18n_locales`） |
| `.claude/harness/test-stage-triggers.yaml` | 9 个 testarch skill 的触发条件配置 | `defaults.fallback_skills` + `skills.<name>.{trigger,conditions}` |
| `.claude/harness/scripts/eval_test_stage_triggers.sh` | 主评估器 — 读两个 yaml + 输出单行 JSON | I/O：`<story-key> <spec-path>` → `{"t1":bool, "t3":bool, ...}` |
| `.claude/harness/scripts/simulate_clone_test.sh` | self-test — mktemp + cp 三件套 + 改 config + 跑 eval | exit 0 = 通用化无遗漏 |

### 9 skill 触发逻辑（defaults + condition）

```
test-design  trigger: once_per_project   产物 epic-${EPIC}-test-design.md 缺则触发
framework    trigger: once_per_project   ${frontend_dir}/node_modules/@playwright/test 缺则触发
atdd         trigger: per_story          每条 story 触发（产物存在仍跑 — testarch-atdd 内部幂等）
automate     trigger: per_story          basic per-story e2e 实跑；dedupe 重构按 pattern_match
nfr          trigger: keyword_match      story spec 含 performance / load / NFR 等关键词
trace        trigger: keyword_match      含 compliance / audit / regulatory；或 atdd green ≥5 per epic
ci           trigger: any_match          首次 e2e spec 出现 OR per_epic_done（需 EVAL_CI_HINT 显式信号）
test-review  trigger: threshold          e2e_spec_count ≥ 50
teach        trigger: manual_only        永远不自动触发
```

### 评估流程（run-test-sprint 入口接通点）

```
/harness-zh:run-test --story $KEY 启动
   │
   ▼
0.0 参数解析（KEY / EPIC / DRY_RUN）
   │
   ▼
0.0.5 调 eval_test_stage_triggers.sh + 解析 JSON 写到工作记忆
   │  ├─ JSON.t1 → 决定 stage T1 跑或 skip
   │  ├─ JSON.t3 → 决定 stage T3 跑或 skip
   │  ├─ JSON.t4 → 决定 stage T4 跑或 skip
   │  └─ eval 失败 → fail-open 默认全跑 T1/T3/T4 + WARN（与 stage 5.5 graceful skip 同款）
   │
   ▼
0.1 环境探测（check_test_harness_env.sh）
   │
   ▼
1. 单 story 测试流水线（按 JSON 跳过未触发 stage，保持顺序不变）
```

### Fail-open 准则（不破坏 stage 5.5 嵌入）

```
eval 脚本 exit ≠ 0 / yaml 损坏 / project config 缺失
   ↓
吐 defaults JSON（t1/t3/t4=true, 其余 false）+ stderr WARN
   ↓
run-test-sprint 仍跑 T1/T3/T4 — 损失"自动跳过的优化"，不损失"测试不跑"
```

### 跨项目 clone 验证

`.claude/harness/scripts/simulate_clone_test.sh` 物理验证：mktemp -d → cp 三件套（CLAUDE.md / .claude / .claude/harness/scripts / .claude/harness/git-hooks）→ 写最小 project config → 跑 eval + install_git_hooks → assert harness 元文档零 Aegis 硬编码 + eval JSON 合理。落地后每条新 chore self-test 都过一遍此 simulate（CI 友好）。

### 路径与模块外化（chore-harness-path-externalization 沉淀）

C-path-externalization 落地后，三类项目特定值从脚本硬编码移出，进入 `harness-project-config.yaml`：

| 字段 | 位置 | 类型 | 说明 |
|---|---|---|---|
| `artifacts_root` | 一级 | 字符串（相对仓库根） | artifact 输出根（默认 `_bmad-output/implementation-artifacts`）；新项目可改 `docs/specs` 等 |
| `extra.path_classifiers` | 二级 | list of {label, regex} | `harness-state.py` resume-prompt 用，按改动文件路径打 label 桶；空 list 合法（全归 "other"） |
| `extra.verification_commands` | 二级 | 多行 `\|` 块字符串 | `harness-state.py` resume-prompt 引用的 verification 引导文本 |

**两个 helper（all scripts 唯一来源）**：

- `.claude/harness/scripts/harness_config.py` — Python 端，hand-rolled YAML 解析（no PyYAML dep，与 sprint-status.py / eval_test_stage_triggers.sh 同手法）。暴露 `get_artifacts_root() / get_sprint_status_path() / get_deferred_work_path() / get_path_classifiers() / get_verification_commands()` 5 函数。
- `.claude/harness/scripts/read_harness_config.sh` — bash 端，sources 后暴露 `read_harness_config_field <key> [default]` 函数 + `HARNESS_REPO_ROOT / HARNESS_ARTIFACTS_ROOT / HARNESS_SPRINT_STATUS_PATH / HARNESS_DEFERRED_WORK_PATH` env vars。

**Fallback 准则**：字段缺失 / yaml 文件缺失 / yaml 损坏 → fallback to hardcoded default + stderr WARN（与 `eval_test_stage_triggers.sh:62` `fail_open_default` 同款）。新项目第一次 clone 时不会因缺字段崩。

**不做**：① slash command（run-sprint.md / run-test-sprint.md）prose 不外化（散文级路径示例，模板化是后续 chore）；② commit message 模板 / 5-stage 状态机命名不外化（架构层硬约定）。

### `/harness-zh:init` — clone-time / mid-project 一次性 yaml 同步（chore C-run-sprint-init 沉淀）

`harness-project-config.yaml` 是 harness 跨脚本的项目配置 SoT，但其 14 字段（11 描述 + 3 派生）的事实源头是 BMad planning artifacts（`product-brief.md` / `prd.md` / `architecture/tech-stack.md` / `architecture/repo-structure.md`）。手填易漂移、新项目 clone 启动门槛高 — `/harness-zh:init` 一次性把 BMad → yaml 同步。

**触发场景**：
- ① clone harness 到全新项目（空 yaml + 完整 BMad 产物）→ 14 字段全填
- ② mid-project 启用 harness（部分手填 yaml + 完整 BMad）→ merge：5 既有保留 + 9 缺失补全

**调用形式（LLM-orchestrated；与 `/harness-zh:run` / `/harness-zh:run-test` 同款）**：

```
/harness-zh:init               # 默认 merge — 已存在字段不动 + 缺失字段补全
/harness-zh:init --dry-run     # 仅 stdout 列 diff，0 写入
/harness-zh:init --force       # 覆盖既有值（含手改字段）；先列 "field: old → new" + 二次确认
```

**Prerequisite gate（3 必需 + 1 可选 — 单文件 / sharded 任一形式都接受）**：

| 概念产物 | 必需性 | 接受的形式 | 引导 BMad skill |
|---|---|---|---|
| prd | **必需** | 单文件 `prd.md` 或 sharded `prd/` 目录 | `/bmad-create-prd`（亦 `/bmad:prd`） |
| architecture | **必需** | 单文件 `architecture.md` 或 sharded `architecture/` 目录 | `/bmad-create-architecture`（亦 `/bmad:architecture`） |
| sprint-status | **必需** | `_bmad-output/implementation-artifacts/sprint-status.yaml`（路径固定） | `/bmad-sprint-planning` |
| product-brief | **可选**（缺仅 WARN，不阻流）| `product-brief*.md`（glob — 上游含项目名后缀） | `/bmad-product-brief` |

> **单文件 vs sharded 都是 BMad 上游合法布局**：BMad 默认产单文件 `prd.md` / `architecture.md`；用户跑 `/bmad-shard-doc` 后切到 sharded 形式。harness-zh 对二者无偏好。
>
> ux-design / epics 等其他 BMad 产物（`ux-design-specification.md` 单文件 vs `ux-design-specification/` sharded、`epics.md` vs `epics/`）当前**未在 harness-zh 任何运行时路径引用**（不在 §A.5 检测、不在 §2 字段提取、不在 retro 审计）；信息从 sprint-status.yaml + prd.md + architecture.md 间接获取，未来若加 hard ref 需同步加 dual-form 检测。

helper：[`scripts/run_sprint_init_check_prereq.sh`](scripts/run_sprint_init_check_prereq.sh) — exit 0 / 2 / 3；JSON stdout（含 `optional_missing` 字段）+ 引导 stderr。

**14 字段 mapping 概要**（详 [`.claude/commands/init.md`](../commands/init.md) §2 — 表格用 sharded 路径写 source 列，LLM 提取时按"sharded 探测 → 单文件章节 grep" fallback；两形式都是一等公民）：

| yaml field | BMad source（sharded 形式 / 单文件章节）| 提取语义 |
|---|---|---|
| `project_display_name` | product-brief*.md / prd.md | 产品名 / 项目代号 |
| `container_orchestrator` | architecture/tech-stack.md / architecture.md §tech-stack | 容器编排（docker-compose / k8s） |
| `frontend_framework` | architecture/tech-stack.md / architecture.md §tech-stack | 前端框架（Next.js / SvelteKit） |
| `backend_languages` | architecture/tech-stack.md / architecture.md §tech-stack | 后端语言列表（Go / Python / Rust） |
| `e2e_framework` | architecture/tech-stack.md / architecture.md §testing-strategy | e2e 框架（Playwright / Cypress） |
| `extra.frontend_dir` | architecture/repo-structure.md / architecture.md §repo-structure | 前端代码目录 |
| `extra.e2e_test_subdir` | repo-structure.md / testing-strategy 章节 | e2e 测试目录 |
| `extra.container_count` | tech-stack.md / architecture.md §tech-stack | 服务容器数量 |
| `extra.i18n_locales` | architecture/i18n.md / architecture.md §i18n（NICE） | 前端国际化语种 |
| `extra.routing_pattern` | i18n.md / tech-stack.md（NICE） | 路由模式 |
| `extra.proxy_addon` | architecture/proxy*.md / architecture.md §proxy（NICE） | 代理插件 |
| `extra.sandbox_constraint` | architecture/nfrs.md / architecture.md §nfrs（NICE） | 沙箱资源约束 |
| `extra.resource_baseline` | architecture/nfrs.md / architecture.md §nfrs（NICE） | 资源 baseline |
| `extra.backend_modules` | architecture/repo-structure.md / architecture.md §repo-structure | 后端模块列表 |

派生字段（不读 BMad；基于上述 11 描述字段拼模板）：
- `artifacts_root` — 默认 `_bmad-output/implementation-artifacts`（yaml 已设则保留）
- `extra.path_classifiers` — 基于 `frontend_dir` + `backend_modules` + `backend_languages` 条件分支生成 list of regex；上游缺失 → fallback Aegis 默认 11 条 + WARN
- `extra.verification_commands` — Q5 三组合（Go/TS / Python/TS / Rust/TS）模板拼接；其它栈 fallback `# TODO: ...` placeholder + WARN

**LLM-driven 提取**（不写 grep/awk 解析）：BMad markdown 段标题 / 段位置不严格固定（中英文 / 编号前缀 / 同义词都漂移），LLM 用 Read 工具 + 语义检索（"找前端框架" 而非 "读 ## Frontend 段"）天然 robust。代价仅 init 一次性 token；平时所有 script call 仍是 grep yaml 零 LLM 成本。

**写入策略（Q2 / Q3 / Q6）**：
- Edit 工具逐字段替换（保留顶部 schema 文档注释）
- merge 模式：既有不动 + 缺失补全；force 模式：列 "field: old → new" + 二次确认 prompt → 全替换
- 写完跑 `harness_config.py` smoke + `simulate_clone_test.sh` 验证；fail → rollback yaml + halt
- **不**自动 commit yaml — solo-dev review 后自决（与 §-1.d "禁止主 agent 自己 git 操作"同精神）

**self-test**：[`scripts/run_sprint_init_test.sh`](scripts/run_sprint_init_test.sh) — 3 fixtures（全新 / mid-project / MUST-EXIST 缺失）；mechanically 测 §1 prereq gate 行为，§2-§4 LLM-driven 部分由人工 spot-check（`--dry-run` 真实跑 + 14 字段填值合理性）。

### 老 chore spec 的 frozen 边界

C-cond-triggers 落地前的老 chore spec（c1-A1 / c2-B5 等含 "7 容器栈" / "console-api" 硬编码）**不回填**——已 frozen done 的历史快照。通用化效力从本 chore 落地后下一条新生成 chore（如 epic-4 stage 6.5 输出的 c4-* spec）起；fresh agent prompt 加"用 placeholder"约束防止再次硬编码。

### 不做（决策边界）

- ❌ yq / Python / Node 依赖（与 C1 / C12 同款）— 纯 bash + grep + awk + sed
- ❌ teach skill 自动触发（永远 manual_only）
- ❌ 让 eval 失败阻 run-test-sprint 主流程（fail-open 是硬约束）
- ❌ 回填老 chore spec（c1-A1 等保留 Aegis 历史快照）
- ❌ 强制 sed pre-process 文档占位符（占位符按需替换 — 多数场景由阅读者上下文理解）

---

## 十二、目录布局（按功能分组；文件总数 ~60 个，随版本浮动）

> 维护契约：新增脚本 / convention / template / hook 时同步在本段加一行（位置 = 对应功能组末尾）。本段是 onboarding / 自查的功能视角索引，与 [`changelog.md`](changelog.md)（时间视角）+ [`scripts/simulate_clone_test.sh`](scripts/simulate_clone_test.sh)（clone 拷贝清单）三视角互补。
>
> **真实文件数请以 `ls plugins/harness-zh/scripts/ commands/ templates/` 为准** —— 本段树形图随 plugin 版本可能落后；如发现不一致以实际文件系统为准。最近 0.1.13-0.1.16 新增的若干 detector / extract / upgrade-deferred-work 资产可能未列在树形图里（见 `changelog.md`）。

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
│   ├── commands/                                5 个 slash command（user 入口）
│   │   ├── run.md                               主流程编排（5-stage + 6 retro + 6.5 residue）
│   │   ├── run-test.md                          测试流程编排（T1/T3/T4 + 5.5 嵌入）
│   │   ├── init.md                              一次性 bootstrap（BMad → yaml 14 字段同步 + §A.3.c 旧 deferred-work 检测 + §A.3.d harness-residue 迁移）
│   │   ├── update.md                            升级后资产同步（不动 yaml / 不跑 BMad 提取）
│   │   └── upgrade-deferred-work.md             事后 deferred-work schema 复测 + mode 切换（advisory / archive+greenfield / 手工 backfill）
│   │
│   └── harness/
│       ├── architecture.md                      ← 设计单一权威来源（本文件；100% portable）
│       ├── changelog.md                         ← 历史叙事（每条优化追加；100% portable）
│       ├── answer-policy.md                     ← 代答政策 / subagent 通用决策原则（100% portable）
│       ├── harness-project-config.yaml          ← ⚠️ 项目特定（clone 后第一件事改这里 — 16 字段；或 /harness-zh:init 自动同步）
│       ├── test-stage-triggers.yaml             ← 9 testarch skill 测试触发条件（100% portable）
│       │
│       ├── conventions/                         ← 数据格式约定（1 个；100% portable）
│       │   └── deferred-work-schema.md          deferred-work.md schema v1（4-tag header）
│       │
│       ├── git-hooks/                           ← 仓库追踪的 hook 源（1 个；100% portable）
│       │   └── pre-commit                       gate ① retro check（dev 阻 / harness WARN）+ gate ② deferred-work schema
│       │
│       ├── prompt-suffixes/                     ← BMad skill prompt 拼接（3 个；100% portable）
│       │   ├── bmad-create-story-suffix.md      story 创建段尾约束
│       │   ├── bmad-dev-story-suffix.md         dev 实施段尾约束（5q gate / mech-verify / Q6 全栈贯通格式）
│       │   └── bmad-retrospective-suffix.md     retro pre-hint（self-audit）
│       │
│       ├── prompt-templates/                    ← spec/chore 内嵌引用模板（4 个；100% portable）
│       │   ├── self-review-5q-template.md       dev-story 5 问自检
│       │   ├── mech-verify-dry-run-template.md  机械化 verify dry-run（3 类 tag）
│       │   ├── data-visibility-review-template.md  RBAC 4 问 review checklist
│       │   └── deferred-import-status-template.md  deferred-work 自动 import 状态
│       │
│       └── scripts/                             ← 全部脚本（~40 个；除标注 ⚠️ 外均 portable）
│           │
│           ├── [Python 核心 5 个 — 编排 + 状态]
│           │   ├── sprint-status.py             状态文件 CRUD（路径 A 5-stage 状态机）
│           │   ├── harness-state.py             单 story 状态检视 + halt-recovery-check
│           │   ├── harness-commit.py            commit gate（黑名单 / 跨 story / schema 校验 / auto-fix binary blob）
│           │   ├── harness-prompt-suffix.py     subagent prompt suffix 注入器（代答政策 inline project_context + Q6 渲染）
│           │   └── harness_config.py            yaml config reader + hardcoded fallback
│           │
│           ├── [Bash config helper 1 个]
│           │   └── read_harness_config.sh       bash 脚本 source 这个拿 config 字段
│           │
│           ├── [Retro 流]
│           │   ├── check_retro_action_items.sh + _test.sh         gate（v2 dev/harness category 分流）
│           │   ├── grep_prev_retro_action_items.sh                上轮 retro action items 提取
│           │   ├── process_retro_residue.sh + _test.sh + _prompt.md  fresh agent 残留处理 → chore spec + MANIFEST
│           │   └── ⚠️ run_retro_self_audit.sh + _test.sh          **项目特定**（hardcoded check_AN/BN/CN 函数体；clone 后必须重写或删除）
│           │
│           ├── [Deferred-work 流]
│           │   ├── grep_deferred_buckets.sh                       bucket 总账（含 §1 §1.1/§1.2/§1.3）
│           │   ├── grep_deferred_status.sh                        schema tag 状态查询
│           │   ├── grep_pending_deferred_for_story.sh + _test.sh  按 story key 找 pending FU
│           │   ├── backfill_resolved_markers.sh + _test.sh + _prompt.md  fresh agent backfill resolved（schema v1 后 deprecated；FORCE_LEGACY_BACKFILL=1 才跑）
│           │   ├── detect_deferred_work_schema.sh                 v0.1.13 新增；扫 deferred-work.md 算 v1 conformance（pristine/v1_clean/mixed/legacy）
│           │   ├── diff_guardrail.sh                              backfill 改动越界守门
│           │   └── pre_commit_deferred_schema_test.sh             pre-commit gate ② 测试
│           │
│           ├── [Plugin issue 直通管道（v0.1.26 替代 v0.1.14 upstream-feedback.md 中转）]
│           │   └── collect_issue_context.sh                       拼 issue body（plugin 版本 / sprint/story 状态 / halt 现场 / 近期 commits）；由 /harness-zh:report-issue 调用 → gh CLI 直提
│           │

│           ├── [Spec 质量 gate]
│           │   ├── check_spec_length.sh                           spec 长度上限
│           │   ├── check_inheritance_block.sh + _test.sh          epic 第一 story 继承段约束
│           │   ├── check_q6_in_dev_record.sh                      全栈贯通 review 段格式
│           │   └── extract_d_decisions.sh                         spec D-decisions 提取到独立文件
│           │
│           ├── [Test harness 接通]
│           │   ├── check_test_harness_env.sh + _test.sh           Playwright 环境探测（runtime ready）
│           │   ├── bootstrap_test_harness.sh                      手工 bootstrap manifest（fixtures + scaffold）
│           │   └── eval_test_stage_triggers.sh + _test.sh         9 testarch skill 条件评估（fail-open）
│           │
│           ├── [Bootstrap / install / clone]
│           │   ├── install_git_hooks.sh                           hook 安装到 .git/hooks/（幂等 + backup）
│           │   ├── run_sprint_init_check_prereq.sh + _test.sh     /harness-zh:init 前置检查
│           │   └── simulate_clone_test.sh                         clone 通用化回归测试（占位符化 + 拷贝清单）
│           │
│           └── [其它一次性 chore 回归测试]
│               ├── harness_commit_isolation_test.sh               harness-commit.py F1/F2 fix 回归
│               └── orchestration_observations_test.sh             chore-harness-epic-4-orchestration 回归
│
└── _bmad/
    ├── customize/                               ← (A) **harness-owned** BMad skill overrides（2 toml；C2/C3/C7 等 chore 落地）
    │   ├── bmad-create-story.toml               activation_steps_prepend 注入（grep prev retro / pending deferred）
    │   └── bmad-dev-story.toml                  dod_prepend_steps 注入（5q gate / mech-verify / Q6 全栈贯通 — 后者从 yaml 渲染）
    │
    ├── custom/                                  ← (B) **BMad-installer-managed**（不是 harness owned；BMad install 时生成）
    │   ├── config.toml                          Team/enterprise BMad overrides（committed）
    │   └── config.user.toml                     Personal BMad overrides（gitignored）
    │
    └── _config / bmb / bmm / cis / core / scripts / tea  ← (B) BMad upstream（installer 管；新项目自己跑 BMad install 重生）
```

**(A) harness-owned** = 必带 clone — `CLAUDE.md` + `.claude/` 全树 + `_bmad/customize/` 2 个 toml

**(B) BMad-installer-managed** = `_bmad/custom/` + `_bmad/_config / bmb / bmm / cis / core / scripts / tea` — 新项目可选两种姿势：① 把 `_bmad/custom/` 也整体 cp（图省事，simulate_clone_test 走的是这条）；② 在新项目跑 BMad install 重生（更干净，但需要新跑一遍 BMad onboarding）。其它 BMad 上游目录（`_config / bmb / bmm` 等）**强烈建议方式 ②** — cp 过去 + BMad 后续升级会冲突

**(C) project-specific** = `_bmad-output/`（项目产出区）+ 项目源码（`console-api/` / `console-web/` / `proxy/`）+ `Justfile`（混合 recipe）— 不进 harness clone

### 12.2 Clone 拷贝清单（[`scripts/simulate_clone_test.sh`](scripts/simulate_clone_test.sh) 已实现）

| 拷 | 路径 |
|---|---|
| ✅ | `CLAUDE.md` |
| ✅ | `.claude/`（整个目录 — commands + harness） |
| ✅ | `_bmad/customize/` + `_bmad/custom/` |
| ❌ | `_bmad-output/`（项目产出区 — story specs / chore / retro / sprint-status / deferred-work） |
| ❌ | 项目源码（`console-api/` / `console-web/` / `proxy/` 等） |
| ❌ | `Justfile`（混合：项目 recipe + harness recipe；clone 时由用户重写主 Justfile + import harness 部分） |

### 12.3 Clone 后必改文件（🔧）

| 文件 | 改什么 | 自动化 |
|---|---|---|
| `.claude/harness/harness-project-config.yaml` | 16 字段（11 BMad-sourced 描述 + 3 派生 + project_context + fullstack_review_steps） | ✅ `/harness-zh:init` 自动从 BMad planning artifacts 提取 |
| `.claude/harness/scripts/run_retro_self_audit.sh` | 重写所有 `check_AN/BN/CN()` 函数体（hardcoded 检查路径 + grep target，对应原项目 retro action items）；或整个删除 | ❌ 手工（脚本头已 ⚠️ 标注） |

**不需要再改的文件**（已通过 yaml-driven 动态注入解耦项目特定）：
- `.claude/harness/answer-policy.md` — 项目语境段已删除；改 yaml `extra.project_context` 即可（subagent 通过 `harness-prompt-suffix.py` inline 注入拿到）
- `.claude/harness/prompt-suffixes/bmad-dev-story-suffix.md` Q6 段 — 项目特定 sub-bullet 清单已抽到 yaml；改 yaml `extra.fullstack_review_steps` 即可（dev subagent 通过 `harness-prompt-suffix.py` stage 2 渲染拿到）
- `_bmad/customize/bmad-dev-story.toml` — Q6 描述已去掉具体组件名

**新项目 onboarding 三步**：
1. clone 整个 `.claude/` + `_bmad/{customize,custom}/` + `CLAUDE.md`
2. 跑 `/harness-zh:init` 让主 agent 从 BMad planning artifacts 自动填 16 字段到 `harness-project-config.yaml`
3. 删 `run_retro_self_audit.sh`（或按新项目 retro 重写 check_XN()）+ 验证 `bash .claude/harness/scripts/simulate_clone_test.sh` 退出 0

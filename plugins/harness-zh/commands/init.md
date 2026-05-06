---
description: Harness clone-time 一次性初始化 — 从 BMad planning artifacts 提取 14 字段写入 harness-project-config.yaml（merge 模式；--dry-run 预览；--force 覆盖带二次确认）
---

# /harness-zh:init — Harness 项目 config 初始化

你是这个 init 的**主 orchestrator**。当用户触发 `/harness-zh:init`，你必须按以下手册顺序执行 §0–§6，把 `.claude/harness/harness-project-config.yaml` 14 字段（11 描述 + 3 派生）从 BMad planning artifacts 自动同步。

**触发场景**：① clone harness 到全新项目（空 yaml + 完整 BMad 产物）；② mid-project 启用 harness（部分 yaml 已填 + 完整 BMad）。

**与 `/harness-zh:run` / `/harness-zh:run-test` 共享的行为契约**：

- **代答政策**：本命令不调度 BMad/codex 子 agent，直接由主 agent 读 BMad markdown + 写 yaml；无 prompt 后缀注入步骤。决策若不显然 → 按 `.claude/harness/answer-policy.md` 自决，不发问。
- **进度可视化**：用 TaskCreate 建任务 `Sprint Init: <project_display_name>`（启动时 in_progress；§6 完成时 completed）。
- **不自动 commit yaml（Q6）**：§6 报告完成后**不**调 `git add` / `git commit`；让 solo-dev review yaml 后自决。

---

## 0. 启动前置

### 0.0 参数解析

| 参数 | 行为 | 互斥 |
|---|---|---|
| `--dry-run` | 仅 stdout 打印 diff（will-write fields），yaml 文件 0 修改 | 与 `--force` 互斥 |
| `--force` | 覆盖 yaml 既有值（含手改字段）；先列 "field: old → new" + 二次确认 prompt | 与 `--dry-run` 互斥 |
| 无参数 | 默认 merge 模式：已存在字段保留，缺失字段补全 | — |

绑定到对话上下文：
- `MODE` = `dry-run` / `force` / `merge`（默认）
- 同时给 `--dry-run` 与 `--force` → 立即 halt + stderr "互斥 flag 不能同时传"

### 0.1 TaskCreate 建任务

`TaskCreate({ subject: "Sprint Init: <project>", description: "MODE=<mode>; 14 字段从 BMad → yaml 同步" })`，立刻 `in_progress`。

---

## 1. Prerequisite 检查（MUST-EXIST gate）

调 helper：

```bash
bash .claude/harness/scripts/run_sprint_init_check_prereq.sh
```

**按退出码处理**：
- **0**：进 §2
- **2**：BMad planning artifacts 缺失。**halt**：把 helper 的 stderr verbatim 贴给用户，TaskCreate 标 `cancelled`，退出。**不**继续读 BMad / 不写 yaml。引导文本（helper 已硬编码 Q4）含具体 BMad skill 名（`/bmad-product-brief` / `/bmad:prd` / `/bmad:architecture`）。
- **3**：sprint-status.yaml 缺失。**halt**：引导跑 `/bmad:sprint-planning`，TaskCreate 标 `cancelled`，退出。
- **其它**：halt + 报告 helper exit code（参数错误 / 内部错误 — 不应发生）。

**MUST-EXIST 清单**（helper 内）：
1. `_bmad-output/planning-artifacts/product-brief.md`
2. `_bmad-output/planning-artifacts/prd.md`
3. `_bmad-output/planning-artifacts/architecture/tech-stack.md`
4. `_bmad-output/planning-artifacts/architecture/repo-structure.md`
5. `_bmad-output/implementation-artifacts/sprint-status.yaml`

**NICE-TO-HAVE**（缺则相关字段静默用默认；不阻流）：
- `architecture/i18n.md` / `architecture/nfrs.md` / `architecture/proxy*.md`
- `testing-strategy.md`

---

## 2. BMad artifacts 字段提取（14 字段映射表）

按下表逐字段读 BMad markdown + 用**语义检索**（Q1）提取值。**不**依赖固定锚点（如 `## Frontend`）—— BMad-generated markdown 段标题 / 段位置不严格固定（中英文 / 编号前缀 / 同义词都可能漂移）。LLM 用 Read 工具读对应文件全文 + 按"提取语义提示"找信息。

| # | yaml field | BMad source | 提取语义提示 | 失败 fallback |
|---|---|---|---|---|
| 1 | `project_display_name` | `product-brief.md` 或 `prd.md` | 找产品名 / 项目代号 / 产品定位段第一句 | `'TODO: project name'` + WARN |
| 2 | `container_orchestrator` | `architecture/tech-stack.md` | 找容器编排技术（docker-compose / k8s / podman / nerdctl-compose） | `'docker-compose'` + WARN |
| 3 | `frontend_framework` | `architecture/tech-stack.md` | 找前端框架（Next.js / SvelteKit / Remix / Astro 含版本） | `'TODO: frontend framework'` + WARN |
| 4 | `backend_languages` (list) | `architecture/tech-stack.md` | 找后端语言列表（Go / Python / TypeScript / Rust 含版本） | `['TypeScript']` + WARN |
| 5 | `e2e_framework` | `architecture/tech-stack.md` 或 `testing-strategy.md` | 找端到端测试框架（Playwright / Cypress / WebdriverIO） | `'Playwright'` + WARN |
| 6 | `extra.frontend_dir` | `architecture/repo-structure.md` | 找前端代码顶层目录名 | `'frontend'` + WARN |
| 7 | `extra.e2e_test_subdir` | `architecture/repo-structure.md` 或 `testing-strategy.md` | 找 e2e 测试目录路径（相对前端目录或仓库根） | `'tests/e2e'` + WARN |
| 8 | `extra.container_count` | `architecture/tech-stack.md` 或 `deploy/` 段 | 找服务容器数量（整数） | `0` + WARN |
| 9 | `extra.i18n_locales` (list) | `architecture/i18n.md`（NICE-TO-HAVE） | 找前端国际化语种代码列表（zh-CN / en-US 等） | `['en-US']` + WARN |
| 10 | `extra.routing_pattern` | `architecture/i18n.md` 或 `architecture/tech-stack.md`（NICE-TO-HAVE） | 找路由模式描述（"Next.js i18n routing" 等） | `''` + WARN |
| 11 | `extra.proxy_addon` | `architecture/proxy*.md`（NICE-TO-HAVE） | 找代理 / 中间人插件名 | `''` + WARN |
| 12 | `extra.sandbox_constraint` | `architecture/nfrs.md` 或 PRD NFR 段（NICE-TO-HAVE） | 找资源约束 / 沙箱尺寸（"4C/8GB" 等） | `''` + WARN |
| 13 | `extra.resource_baseline` | `architecture/nfrs.md` 或 PRD NFR 段（NICE-TO-HAVE） | 找最低资源 baseline | `''` + WARN |
| 14 | `extra.backend_modules` (list) | `architecture/repo-structure.md` | 找后端服务 / 模块顶层目录列表 | `[]` + WARN |
| 15 | `extra.project_context` (multiline \| block) | `product-brief.md` 或 `prd.md` | 提取产品定位 + 关键决策原则段（开发模型 / 目标客户 / 交付形态 / 技术准则等）。每条原文一行 `- <key>：<value>` 形式，6-10 条；保留中英文。subagent 在按 answer-policy.md 自决时把这段当项目语境用 | `'项目语境未配置：clone 后请填 extra.project_context'` 多行块 + WARN |
| 16 | `extra.fullstack_review_steps` (list of {label, file_path}) | `architecture/data-model.md` 或 `architecture/component-architecture.md` 或 `architecture/repo-structure.md` | 找核心数据写入 / 序列化 / 渲染 / i18n 路径列表（按数据流"字段定义→写入→序列化→存储 mapping→hash chain canonical 验证→i18n→前端渲染"7 段；每条 `{label: 短描述, file_path: 具体文件路径或 module::symbol}`）。dev-story Q6 端到端追溯每项；新审计字段引入时按本表逐项打勾 | `[]` + WARN（list 为空时 dev-story Q6 整段降级跳过；不阻流） |

**提取协议**：
- 用 Read 工具读 BMad source 文件全文（每条 source 至多读一次，缓存到工作记忆）
- 对每个字段：在文件内容中按"提取语义提示"找信息；找到 → 记入 `EXTRACTED[<key>] = <value>`；找不到 → 记入 `WARN[<key>] = "BMad source <path> 未发现 <语义>; using fallback"`
- 提取完所有 16 字段后进 §3
- **禁止**：不写 grep/awk/sed 解析 BMad markdown（脆弱；spec Boundaries "Never"）

**字段 15-16 特殊语义**（2026-05-05 加 — L1+L2 yaml-driven 注入）：
- 字段 15（project_context）由 `harness-prompt-suffix.py` 在 prompt 注入时内联到代答政策块；缺失会导致 subagent 决策时缺项目语境（fallback 为通用决策原则）
- 字段 16（fullstack_review_steps）由 `harness-prompt-suffix.py` stage 2 渲染为 dev-story Q6 sub-bullet 注入到 dev subagent；list 为空时 Q6 整段降级跳过（不阻流）
- 这两字段 fallback 不阻 init / sprint，但实际跑 dev / review 时建议补全（subagent 决策质量与字段完整度强相关）

---

## 3. 派生字段计算（artifacts_root / path_classifiers / verification_commands）

### 3.1 artifacts_root

- yaml 已设 → 不动（merge 语义）
- yaml 未设 → 写默认 `'_bmad-output/implementation-artifacts'`

### 3.2 path_classifiers（基于 §2 提取的 frontend_dir + backend_modules + e2e_test_subdir）

按下面模板生成 list of {label, regex}。`<frontend_dir>` 等占位符按 §2 字段值代入；任一上游字段缺失 → 留 `harness-project-config.yaml` Aegis 默认 11 条 + WARN（spec I/O Matrix 表第 9 行 fallback 行为）。

**模板（条件分支按 §2 值挑选）**：

- 当 `Go` ∈ `backend_languages` 且 `backend_modules` 非空：
  - `{label: 'backend Go source', regex: '^<backend_modules[0]>/(?!.*_test\\.go$)'}`
  - `{label: 'backend Go tests',  regex: '^<backend_modules[0]>/.*_test\\.go$|^tests/integration/'}`
  - `{label: 'backend SQL/migrations', regex: '^<backend_modules[0]>/.*\\.sql$|^<backend_modules[0]>/internal/migrations/'}`
- 当 `Python` ∈ `backend_languages` 且 `backend_modules` 非空：
  - `{label: 'backend Python source', regex: '^<backend_modules[?]>/(?!.*test_.*\\.py$)'}`
  - `{label: 'backend Python tests',  regex: '^<backend_modules[?]>/.*test_.*\\.py$'}`
- 当 `Rust` ∈ `backend_languages` 且 `backend_modules` 非空：
  - `{label: 'backend Rust source', regex: '^<backend_modules[?]>/src/'}`
  - `{label: 'backend Rust tests',  regex: '^<backend_modules[?]>/tests/'}`
- 当 `frontend_dir` 非空：
  - `{label: 'frontend TS source', regex: '^<frontend_dir>/src/(?!.*\\.test\\.)'}`
  - `{label: 'frontend TS tests',  regex: '^<frontend_dir>/(tests|e2e)/'}`
  - `{label: 'frontend i18n',      regex: '^<frontend_dir>/locales/'}`
  - `{label: 'frontend config',    regex: '^<frontend_dir>/(eslint|vitest|next|package|pnpm|tsconfig)'}`
- 通用兜底：
  - `{label: 'infra/deploy', regex: '^(deploy|docker-compose|Justfile|scripts/)'}`
  - `{label: 'docs/spec',    regex: '^docs/'}`

### 3.3 verification_commands（Q5 三组合 — 多行 `|` 块）

按 `backend_languages` + `frontend_framework` 拼模板：

| backend 主语言 | frontend | verification_commands 模板 |
|---|---|---|
| Go (含版本) | TypeScript / Next.js 等 | `go vet/build/test ./<backend_modules[0]>/...\npnpm --filter <frontend_dir> typecheck/test/lint --max-warnings=0/build` |
| Python (含版本) | TypeScript / Next.js 等 | `cd <backend_modules[0]> && pytest && ruff check\npnpm --filter <frontend_dir> typecheck/test/lint --max-warnings=0/build` |
| Rust (含版本) | TypeScript / Next.js 等 | `cd <backend_modules[0]> && cargo check && cargo test\npnpm --filter <frontend_dir> typecheck/test/lint --max-warnings=0/build` |
| 其它栈 | 任意 | `# TODO: fill verification commands for your stack` + WARN |

`backend_modules` 为空 → 把 `<backend_modules[0]>` 替换为 `.` （仓库根）。`frontend_dir` 为空 → 把 `<frontend_dir>` 替换为 `frontend`。

---

## 4. yaml merge 写入

### 4.1 读当前 yaml + 解析既有字段

用 Read 读 `.claude/harness/harness-project-config.yaml` 全文，解析每个字段的当前值（保留原始行号 + 注释行）。

### 4.2 计算 diff

对 §2 + §3 算出的 17 个字段（14 BMad-sourced + 3 派生），对比 yaml 既有值：
- **既有 = 提取值** → no-op
- **既有 = 空 / 未设** → mark "to-fill"（merge 模式 + force 模式都写）
- **既有 = 非空 + 提取值 != 既有**：
  - merge 模式 → 保留既有（不动），加 stderr 提示 "field <key> 既有 '<old>' != BMad '<new>' — merge 模式保留既有"
  - force 模式 → mark "to-overwrite"
- **派生字段**：merge 同上；force 同上

### 4.3 模式分支

- **`--dry-run`**：stdout 列出 diff（"to-fill" / "to-overwrite" / "no-op"）+ 退出。**0 写入 yaml 文件**。退出码 0。
- **`--force` + 有 to-overwrite**：stdout 列出每条 "field: old → new"，**用 AskUserQuestion** 二次确认（"--force 会覆盖 yaml 既有 N 字段，确认吗？"）；用户选"是"→ 写；选"否"→ TaskCreate 标 `cancelled`，退出码 1。
- **`merge` 模式**：直接写 to-fill 字段（既有不动）。

### 4.3.5 备份 yaml（rollback 用 — F4 codex review fix 2026-05-05）

进 §4.4 写入之前，先把当前 yaml 的完整内容备份到 /tmp，以便 §4.5 / §5 失败时
**不依赖 git HEAD** 的 rollback。这避开了"用 `git checkout --` rollback 会丢
solo-dev 未提交本地编辑"的爆炸半径（用户 CLAUDE.md feedback memory：halt 时
先评估爆炸半径，别动不动整条撤回）。

```bash
BACKUP_PATH="/tmp/harness-project-config.yaml.preinit-$$"
cp .claude/harness/harness-project-config.yaml "$BACKUP_PATH"
```

把 `$BACKUP_PATH` 路径绑定到对话上下文（§4.5 / §5 rollback 时引用）。备份是
当前 worktree 内容（含 solo-dev 任何未提交编辑），与 git HEAD 解耦。

### 4.4 写入（Edit 工具，逐字段）

用 Edit 工具**逐字段替换**（保留注释 — Q2）：

```
old_string: "project_display_name: '<old>'"
new_string: "project_display_name: '<new>'"
```

对 list 字段（`backend_languages` / `i18n_locales` / `backend_modules` / `path_classifiers`）：把整个 list 块作为 `old_string` 替换为新 list 块。**保留**原 yaml 缩进 + 引号风格。

对多行 `|` 块（`verification_commands`）：替换块内行；不动 `verification_commands: |` 这行本身。

**禁止**：
- 不用 `Write` 工具整文件覆盖 — 会丢顶部 schema 文档注释（Q2 硬约束）
- 不用 sed 整文件 mutate — 多字段替换易错 + 注释脆弱

### 4.5 写入后语法 sanity

跑 `python3 .claude/harness/scripts/harness_config.py` smoke test：
- exit 0 + 输出含期望字段值 → §5 验证
- exit ≠ 0 / 输出含 `WARN [harness_config]:` → **rollback yaml from backup**（用 §4.3.5 绑定的 `$BACKUP_PATH`，**不**用 `git checkout --`）：
  ```bash
  cp "$BACKUP_PATH" .claude/harness/harness-project-config.yaml
  rm -f "$BACKUP_PATH"
  ```
  → halt + 报告失败字段（exit code 4 per spec I/O Matrix）。**为什么不用 `git checkout --`**：会把 yaml 翻成 git HEAD 状态，丢 solo-dev 未提交的本地编辑（mid-project 启用场景常见）。备份-恢复路径与 HEAD 解耦，安全。

---

## 5. 验证（simulate_clone_test.sh）

跑：

```bash
bash .claude/harness/scripts/simulate_clone_test.sh
```

**按退出码处理**：
- **0**：init 写入合法（yaml 解析正常 + helper 跑通 + 占位符在位）→ 清理备份（`rm -f "$BACKUP_PATH"`）→ 进 §6
- **非 0**：**rollback yaml from backup**（不用 `git checkout --`；同 §4.5 理由 — backup-restore 与 git HEAD 解耦，保 solo-dev 未提交本地编辑）：
  ```bash
  cp "$BACKUP_PATH" .claude/harness/harness-project-config.yaml
  rm -f "$BACKUP_PATH"
  ```
  → halt + 报告 simulate 失败步骤（exit code 5 per spec I/O Matrix）

---

## 6. 报告 + 引导（不自动 commit — Q6）

stdout 报告（按下表结构）：

```
✅ /harness-zh:init 完成

【写入字段】<N>/14 BMad 字段 + <M>/3 派生字段
  - project_display_name: '<value>'
  - container_orchestrator: '<value>'
  - ...

【保留字段（merge 模式不动）】<K>
  - field: '<existing>' (BMad 提议: '<bmad>')

【WARN】<W> 项
  - <key>: BMad source <path> 未发现 <语义>; using fallback '<default>'

【下一步】
  请 review yaml 改动后由 solo-dev 自决 commit：
    git diff .claude/harness/harness-project-config.yaml
    git add .claude/harness/harness-project-config.yaml
    git commit -m "chore: init harness config from BMad planning artifacts"
```

**`--dry-run` 模式报告**（无写入）：

```
🔍 /harness-zh:init --dry-run（0 写入）

【will-write】<N> 字段
  - field: <empty> → '<bmad-value>'

【will-overwrite (force-only)】<K> 字段（当前模式不会动；如需覆盖请加 --force）
  - field: '<existing>' → '<bmad-value>'

【no-op】<S> 字段（既有 = BMad 一致）

【WARN】<W> 项

提示：去掉 --dry-run 跑可写入 will-write 字段；加 --force 可覆盖 will-overwrite 字段（需二次确认）
```

完成后把 TaskCreate 任务标 `completed`，退出码 0。

---

## 7. 死循环 / 失控防护

下列**任一**命中立即 halt + 用户介入（与 `/harness-zh:run` §3 / `/harness-zh:run-test` §3 同款模板）：

1. helper `run_sprint_init_check_prereq.sh` 退出码非 0/2/3（参数错误 / 内部异常）
2. BMad markdown 提取语义后 `EXTRACTED[<key>]` 仍为空对**所有 14 字段** → 怀疑 BMad 产物为空文件 / 损坏 → halt + 提示用户检查 `_bmad-output/planning-artifacts/`
3. yaml 写入后 `harness_config.py` smoke test exit ≠ 0（yaml 语法破坏）→ rollback + halt
4. `simulate_clone_test.sh` exit ≠ 0 → rollback + halt
5. runtime quota 信号（`hit your limit` / `rate limit` 等）— 与 `/harness-zh:run` §3 同款配额专属模板

**Halt 模板**（与 `/harness-zh:run` 一致）：

> stage 失败：§<N> in /harness-zh:init
> 现场：[一两句话讲发生了什么]
> 违反规则：[贴 helper / harness_config / simulate_clone 的 stderr verbatim]
> yaml 当前状态：[`git diff --stat .claude/harness/harness-project-config.yaml`]
> 已采取动作：[rollback / 无变更 / 部分写入 N 字段]
> 待用户决断：是否 [选项 1] 撤回 yaml 改动 / [选项 2] 修复 BMad 产物后重跑 / [选项 3] 跳过本次 init

---

## 8. 参数（汇总）

| 参数 | 行为 |
|---|---|
| 无参数 | 默认 merge 模式 — 已存在字段不动 + 缺失字段补全；写 yaml + commit 由 solo-dev 自决 |
| `--dry-run` | 仅 stdout 列 diff，0 写入；与 `--force` 互斥 |
| `--force` | 覆盖 yaml 既有值（含手改字段）；先列 "field: old → new" + 二次确认（AskUserQuestion）；与 `--dry-run` 互斥 |

**v0.2+ 留口**（本版**不**实现）：
- `--reset-changelog`：清空 `_bmad-output/implementation-artifacts/changelog.md` 重启历史（A=a 决策当前不动）
- `--bmad-source <path>`：override 默认 `_bmad-output/planning-artifacts/` 路径（多项目共仓场景）

---

## 引用

- 关联 chore spec：`_bmad-output/implementation-artifacts/chore-harness-run-sprint-init.md`
- prereq helper：[`/scripts/run_sprint_init_check_prereq.sh`](../harness/scripts/run_sprint_init_check_prereq.sh)
- self-test：[`/scripts/run_sprint_init_test.sh`](../harness/scripts/run_sprint_init_test.sh)
- 写入目标：[`harness-project-config.yaml`](../harness/harness-project-config.yaml)
- yaml 解析 helper（写后 sanity）：[`/scripts/harness_config.py`](../harness/scripts/harness_config.py)
- 跨项目 clone 验证：[`/scripts/simulate_clone_test.sh`](../harness/scripts/simulate_clone_test.sh)
- 代答政策：[`../harness/answer-policy.md`](../harness/answer-policy.md)
- harness 通用化设计：[`../harness/architecture.md`](../harness/architecture.md) §十一

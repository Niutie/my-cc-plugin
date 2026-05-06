# harness-zh changelog

每次对 harness-zh plugin 的改动在这里追加一条记录。**新条目放最上面**。每条包含：

- 版本号 + 日期 + commit hash 段
- 改动范围（plugin 文件 / 段）
- 改动动机
- 后续注意事项 / 待办

> **历史接续说明**：harness 在 plugin 化之前作为 `.claude/harness/` 资产维护在 Aegis AI Audit 项目内（commits before plugin extraction）；plugin 提取前的 runtime 演化历史完整保留在该项目的 git history。本 changelog 仅记录 plugin 化之后的改动。

---

## v0.1.4 — 2026-05-06 — BMad 命令名改回 hyphen 形式（修 v0.1.3 过激改动）

### 触发

solo-dev 反馈 v0.1.3 把所有 BMad 命令改成 colon 形式（`/bmad:prd` 等）"好像不对" —— 实际 hyphen 形式（`/bmad-create-prd`）和 colon 形式（`/bmad:prd`）在用户环境**都存在且都可用**，他**通常用 hyphen**。

### 根因

v0.1.3 调研时 agent 报告 "上游用纯冒号"，但只看了 BMad 上游 README 的 docs 描述，没核实**实际装到本地后的命令注册**。两形式同时存在的实情：

- **hyphen 形式**（`/bmad-<name>`）= 直接对应 `.claude/skills/bmad-<name>/` 的 skill 名（`npx bmad-method install --tools claude-code` 写的就是这种）
- **colon 形式**（`/bmad:<name>`）= BMad workflow 别名 / namespace 命令；多数 PM 命令同时注册两种
- 部分命令名形式不同（`/bmad-create-prd` vs `/bmad:prd`、`/bmad-create-architecture` vs `/bmad:architecture` —— hyphen 带 "create-" 前缀，colon 没有）
- 较新 / meta 命令（`/bmad:workflow-init`、`/bmad:research`、`/bmad:tech-spec`、`/bmad:brainstorm`、`/bmad:create-workflow` 等）**仅** colon 形式

### 修

| 位置 | 改动 |
|---|---|
| `commands/init.md` §A.5 表格"来源命令"列 | colon → hyphen + 加两形式等价说明段 |
| `commands/init.md` §A.5 detection 块的 MISSING_LABELS hint | colon → hyphen |
| `commands/init.md` §A.7 早结束文案 | 4 个 PM 命令改 hyphen + 加 "命令名也可写 /bmad:xxx" 说明；保留 `/bmad:workflow-init` 标注"只有冒号形式" |
| `commands/init.md` §1 描述 | 同步 |
| `scripts/run_sprint_init_check_prereq.sh` MISSING_GUIDANCE 数组 | colon → hyphen；末尾 stderr 加两形式等价注脚 |
| `README.md` BMad 段命令清单 | colon → hyphen + 一行说明 colon 别名也可 |

### 注意

§A.5 表格"来源命令"列示例（修后）：
- product-brief → `/bmad-product-brief`
- prd → `/bmad-create-prd`（注意 hyphen 形式带 "create-" 前缀）
- architecture → `/bmad-create-architecture`（同上）
- sprint-planning → `/bmad-sprint-planning`

未来若 solo-dev 改习惯 colon 形式，重跑一次本档全局 sed 即可。

---

## v0.1.3 — 2026-05-06 — 对齐 BMad-METHOD 上游（命令名 + 路径）

### 触发

`/harness-zh:init` 早结束文案里硬编码了：

- `/bmad-product-brief`（连字符 — 旧命令命名约定）
- `_bmad-output/planning-artifacts/architecture/tech-stack.md` + `repo-structure.md`（sharded 路径）
- 跑 BMad install 没指引

但 BMad-METHOD 上游（github.com/bmad-code-org/BMAD-METHOD）当前实际：

- 命令统一冒号形式：`/bmad:product-brief` / `/bmad:prd` / `/bmad:architecture` 等
- architecture 默认产**单文件** `architecture.md`（含 tech-stack / repo-structure / nfrs / i18n / proxy 等章节）；只有跑过 `/bmad:shard-doc` 才切片到 subdir
- product-brief 文件名带项目后缀（`product-brief-{project_name}.md`）
- 5 模块：BMM / BMB / TEA / CIS / BMGD，前 4 个 harness-zh 都用得上，BMGD（game dev）不需要
- 装法：`npx bmad-method install --modules bmm,bmb,tea,cis --tools claude-code` + `/bmad:workflow-init`

### 修

| 位置 | 改动 |
|---|---|
| `commands/init.md` §A.5 | 检测改"4 类概念产物，单文件或 sharded 任一形式接受"；MISSING 列表精简到产物级别（不逐文件） |
| `commands/init.md` §A.7 早结束文案 | `/bmad-` → `/bmad:`；产物路径用单文件名（默认形式）；加 `npx bmad-method install` + `/bmad:workflow-init` 引导 |
| `commands/init.md` §1 描述 + MUST-EXIST 文本清单 | 同步上述变化 |
| `commands/init.md` §2 字段提取表 | 加前置说明（"sharded 路径优先 → fallback 读单文件章节"）；前 6 行 source 列加"或 architecture.md §section"备选 |
| `scripts/run_sprint_init_check_prereq.sh` | PLANNING_CHECKS 数组 → 4 个内联 if-else 块（支持 glob / 单文件 OR sharded 目录）；GUIDANCE 命令名全冒号；末尾加"首次使用 BMad" install + workflow-init 提示 |
| `README.md` BMad prereq 段 | 增加 5 模块对照表（BMGD 标 "Skip"）；改 install 命令为 `npx bmad-method install --modules bmm,bmb,tea,cis --tools claude-code`；增加 `/bmad:workflow-init` 首次步骤 |

### 注意

§2 字段提取表只更新了前 6 行的 source 列（加 "或 architecture.md §section" 备选）；后 10 行（i18n / nfrs / proxy / project_context / fullstack_review_steps）仍按 sharded 路径写但 LLM 在 §2 跑提取时会按表前的"sharded 优先 → fallback 单文件章节"自适应，不阻流。

---

## v0.1.2 — 2026-05-06 — 跨 marketplace 依赖语法修复

### 触发场景

solo-dev 跑 `/plugin install harness-zh@my-cc-plugin` 报错：

> Plugin "harness-zh@my-cc-plugin" is already installed — 1 dependency still unresolved: codex@my-cc-plugin.

### 根因

`plugin.json` 的 `dependencies` 用了 `{name: "codex", version: "*"}` 简写。Claude Code 默认把 `{name: "codex"}` 解析为 `codex@<当前 marketplace>` —— 即 `codex@my-cc-plugin`。但 codex 实际在 `openai-codex` marketplace，my-cc-plugin 里没有 codex plugin，所以 dep 永远 unresolved。

### 修法

**plugin.json** 用对象格式显式指定 marketplace：

```json
"dependencies": [
  { "name": "codex", "marketplace": "openai-codex", "version": "*" }
]
```

**marketplace.json** 加白名单（跨 marketplace 依赖默认禁，必须根 marketplace 显式 opt-in）：

```json
"allowCrossMarketplaceDependenciesOn": ["openai-codex"]
```

### 注意

用户装 harness-zh 前必须已 `claude plugin marketplace add openai/codex-plugin-cc`（让 Claude Code 知道 openai-codex marketplace 存在）。README 已列为前置；此处用 plugin.json 硬声明做兜底（自动检查 / 报错引导）。

---

## v0.1.1 — 2026-05-06 — PLUGIN_ROOT 探测修复（首次装载暴露的 bug）

1 commit（`38c799b`）：

- **`38c799b`** — `/harness-zh:init` §A.0 + `/harness-zh:update` §1 的 fallback 探测改用 `plugin.json` 扫描，替代失效的 `find -name harness-zh`

### 触发场景

solo-dev 首次在 `~/plugin-test` 跑 `/plugin install harness-zh@my-cc-plugin` 后，未跑 `/harness-zh:init`（先误以为 install 会自动部署）。但更深一层 bug：即便跑 init，§A.0 的 `find ~/.claude -type d -name harness-zh` fallback 在 Claude Code **实际**的安装布局下找到的是版本子目录的**父级**（`~/.claude/plugins/cache/my-cc-plugin/harness-zh/`），里面没 commands/ scripts/ 等 — 实际文件在 `harness-zh/0.1.0/` 下。

### 修法

两遍扫 `plugin.json`：
1. 第一遍优先 `cache/<marketplace>/<plugin>/<version>/`（官方版本化安装路径）
2. 第二遍 fallback 到任意命中（含 `marketplaces/<...>/plugins/<plugin>/` git-clone 副本）

匹配条件：plugin.json 内含 `"name": "harness-zh"`。

### 验证

在 zhenhua 实际安装路径上跑通 — 解析到 `/Users/zhenhuazhu/.claude/plugins/cache/my-cc-plugin/harness-zh/0.1.0`，含 commands/ 和 41 个 scripts。

---

## v0.1.0 — 2026-05-06 — 初始 plugin 提取

5 commits（commit `65148b1` → `2f782ae`）：

- **`65148b1`** — 把 Aegis 项目的 `.claude/harness/` + `.claude/commands/` 全量 copy 到 `my-cc-plugin/plugins/harness/`，加 `marketplace.json` + `plugin.json`（v0.1.0 scaffolding）
- **`0d82f82`** — 重命名 plugin 命名空间 `harness` → `harness-zh`（避通用名冲突）；commands 文件 reshuffle：
  - `run-sprint.md` → `run.md` (`/harness-zh:run`)
  - `run-test-sprint.md` → `run-test.md` (`/harness-zh:run-test`)
  - `run-sprint-init.md` → `init.md` (`/harness-zh:init`)
- **`6fd3a4e`** — `/harness-zh:init` 头部加 §A Plugin Asset Deployment 段：
  - §A.0 探测 `${CLAUDE_PLUGIN_ROOT}` / `find ~/.claude` fallback
  - §A.1-§A.2 mkdir + cmp/backup/overwrite 资产部署
  - §A.3 仅当不存在时投放 `harness-project-config.yaml`
  - §A.4 跑 `install_git_hooks.sh`
  - §A.5 BMad artifacts 检测 → 决定是否进 §0+ 字段提取
  - 新增 `/harness-zh:update` 命令（仅刷资产，不动 yaml，不跑 BMad 提取）
- **`1662600`** — `harness-project-config.yaml.template` 全清空（让 init merge 模式能填）+ 修漏掉的 `.yaml.template` sed（前一次重命名 find 过滤只匹配 `.yaml`）
- **`2f782ae`** — `/init` §A.2 + `/update` §3 用 `find` + process substitution 替代 `shopt -s nullglob` + glob（兼容 zsh — 不会因空子目录在默认 NOMATCH 下中止脚本）

### 设计要点

- **Plugin 是 asset deployer，不是 runtime container**：runtime 仍用 `.claude/harness/` project-resident 路径，因为：
  - git pre-commit hooks 在 git 上下文跑（非 Claude Code），`${CLAUDE_PLUGIN_ROOT}` 不可用
  - markdown commands 的 bash 块（per Anthropic docs）不保证注入 `${CLAUDE_PLUGIN_ROOT}`
  - 强行用 plugin-internal 路径会撞这两道墙
- **Asset deployment 幂等**：cmp 比较内容；相同 unchanged，不同 backup → overwrite（沿用 `install_git_hooks.sh` 模式）
- **yaml 永不被资产投递覆盖**：保 solo-dev 已填的 14 字段配置；只在缺失时从 template 投放
- **BMad ready 分叉**：init §A.5 检测 `_bmad-output/planning-artifacts/{product-brief,prd,architecture/{tech-stack,repo-structure}}.md` + `_bmad-output/implementation-artifacts/sprint-status.yaml` 都齐 → 进 §0+ 字段提取；缺则早结束 + 引导用户跑 BMad workflow

### 已知约束 / 待验证

- **依赖 `codex` plugin**（plugin.json 已声明）；缺则 Claude Code 装 harness-zh 时 halt
- **依赖 BMad workflow toolset**（**未声明 plugin dep**，因为 BMad 在多数环境是项目 `.claude/skills/bmad-*` 形式而非 plugin）；README 列为前置要求
- **未做真实 Claude Code 装载测试**：`/plugin marketplace add` + `/plugin install` + `/harness-zh:init` 端到端验证待 solo-dev 在干净项目跑
- **smoke-tested**：§A 部署逻辑在 zsh 临时目录跑通三轮（fresh / 幂等 / drift 恢复），含空子目录边界场景

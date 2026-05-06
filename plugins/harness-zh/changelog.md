# harness-zh changelog

每次对 harness-zh plugin 的改动在这里追加一条记录。**新条目放最上面**。每条包含：

- 版本号 + 日期 + commit hash 段
- 改动范围（plugin 文件 / 段）
- 改动动机
- 后续注意事项 / 待办

> **历史接续说明**：harness 在 plugin 化之前作为 `.claude/harness/` 资产维护在 Aegis AI Audit 项目内（commits before plugin extraction）；plugin 提取前的 runtime 演化历史完整保留在该项目的 git history。本 changelog 仅记录 plugin 化之后的改动。

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

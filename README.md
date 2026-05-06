# my-cc-plugin

Personal Claude Code plugin marketplace by [zhenhua zhu](https://github.com/Niutie). Currently distributes one plugin:

| Plugin | Version | Purpose |
|---|---|---|
| **harness-zh** | 0.1.0 | BMad-driven sprint orchestration harness for solo-dev + AI workflows |

---

## harness-zh

A 5-stage TDD-flavored development loop (`/harness-zh:run`) plus test-automation loop (`/harness-zh:run-test`) layered on top of [BMad Method](https://github.com/BMad-Code/bmad) planning artifacts. Designed for **solo developer + AI agent** workflows where:

- One developer drives multiple AI subagents (BMad agents, Codex review, etc.)
- BMad produces planning artifacts (PRD / architecture / epics / sprint-status)
- harness-zh then drives sprint execution: backlog story → create-story → dev-story → adversarial review → fix → final review → retrospective, with state machine rooted in `sprint-status.yaml`

### Prerequisites

harness-zh **orchestrates** other tools and requires the following installed in your environment:

#### 1. BMad-METHOD toolset

[BMad-METHOD](https://github.com/bmad-code-org/BMAD-METHOD) provides `/bmad-product-brief`, `/bmad-create-prd`, `/bmad-create-architecture`, `/bmad-create-story`, `/bmad-dev-story`, `/bmad-retrospective`, `/bmad-sprint-planning`, and ~30 other slash commands across 5 modules. Most commands also have a colon-form alias (e.g. `/bmad:prd` ≡ `/bmad-create-prd`); a few newer/meta commands (`/bmad:workflow-init`, `/bmad:research`, `/bmad:tech-spec`) are colon-only.

| Module | Purpose | Required for harness-zh? |
|---|---|---|
| **BMM** (Method) | Core PM workflow — PRD / architecture / story / sprint planning | **Required** |
| **BMB** (Builder) | Custom agent / workflow authoring | Recommended |
| **TEA** (Test Architect) | Risk-driven test strategy + atdd / trace / nfr / ci | Recommended |
| **CIS** (Creative Intelligence) | Brainstorming / design thinking / storytelling / innovation | Recommended |
| **BMGD** (Game Dev Studio) | Unity / Unreal / Godot game-dev workflows | **Skip** unless game-dev project |

**Install** (Node.js v20+, Python 3.10+, `uv` required):

```bash
# 推荐：装 4 个核心模块（除 game-dev studio 外都装）
npx bmad-method install --modules bmm,bmb,tea,cis --tools claude-code

# 或交互式（首次推荐 — 会问要装哪些模块）
npx bmad-method install
```

`--tools claude-code` 让 BMad 把 skills 写到项目的 `.claude/skills/bmad-*/`，installer 同时**自动**建 `_bmad/` 配置目录（`config.toml` + 各模块 yaml）—— 这就是 harness-zh 期望的布局（项目-resident skills），**不需要**额外的 init 步骤。装完后直接跑 `/bmad-product-brief` 等命令即可。

Without BMad, the planning artifacts (`_bmad-output/planning-artifacts/`) that `/harness-zh:init` depends on cannot be generated.

#### 2. codex plugin

Provides `/codex:rescue` and `/codex:setup` (adversarial review subagent invoked from `/harness-zh:run` stage 3 — story implementation review).

```
/plugin marketplace add openai/codex-plugin-cc
/plugin install codex@openai-codex
```

`harness-zh`'s `plugin.json` declares `codex` as a hard dependency — Claude Code blocks installation if codex is not present.

---

### Install

```
/plugin marketplace add Niutie/my-cc-plugin
/plugin install harness-zh@my-cc-plugin
```

Then in any project where you want to use harness-zh:

```
/harness-zh:init
```

This one-time bootstrap deploys plugin assets into the project's `.claude/harness/` + `.claude/commands/` directories, installs the git pre-commit hook, and (if BMad planning artifacts already exist) auto-fills the 14 fields of `harness-project-config.yaml`.

---

### Commands

| Command | Purpose | Phase |
|---|---|---|
| `/harness-zh:init` | First-time bootstrap — deploy plugin assets + (optional) BMad-driven `harness-project-config.yaml` filling | Once per project |
| `/harness-zh:update` | After plugin upgrade — refresh project-side asset copies (does **not** touch yaml or run BMad extraction) | After each `/plugin marketplace update` |
| `/harness-zh:run` | Main sprint loop — automatically processes `sprint-status.yaml` backlog stories through 5 stages (create-story → dev-story → codex adversarial review → dev fix → bmad final review), with retrospectives and retro-residue handling | Daily |
| `/harness-zh:run-test` | Test automation sub-loop — single-story ATDD + E2E real-run (invoked by run-sprint stage 5.5 or directly) | As triggered |

Run `/harness-zh:run --help` (or read `commands/run.md`) for flag reference (`--story`, `--epic`, `--continue`, etc.).

---

### Design model

harness-zh is an **asset deployer**, not a runtime container:

- The plugin distributes harness scripts / slash-commands / conventions / prompt-suffixes / templates / docs.
- `/harness-zh:init` deploys those assets into your project's `.claude/harness/` and `.claude/commands/` directories.
- All runtime behavior (`/harness-zh:run` etc.) operates on the **deployed copy in your project**, using project-relative paths (`.claude/harness/scripts/...`, `.claude/harness/harness-project-config.yaml`).
- This sidesteps two real Claude Code constraints:
  1. Git pre-commit hooks run in git's context (not Claude Code's), so `${CLAUDE_PLUGIN_ROOT}` is unavailable
  2. Markdown slash-command bash blocks are not guaranteed to receive `${CLAUDE_PLUGIN_ROOT}` injection
- Trade-off: each project carries a deployed copy of harness assets. Sync via `/harness-zh:update` after plugin upgrades.

For full runtime architecture (5-stage state machine, sprint-status.yaml schema, retro residue / chore tracking, prompt-suffix injection, etc.) see [`plugins/harness-zh/architecture.md`](plugins/harness-zh/architecture.md).

---

### Versioning

| Version | Date | Highlights |
|---|---|---|
| 0.1.0 | 2026-05-06 | Initial plugin extraction from Aegis AI Audit project's `.claude/harness/` |

See [`plugins/harness-zh/changelog.md`](plugins/harness-zh/changelog.md) for detailed per-commit history.

---

## License

Personal-use marketplace. No license declared at repo level — assume "all rights reserved" by default. If this changes for a particular plugin, that plugin's `plugin.json` will declare its own license.

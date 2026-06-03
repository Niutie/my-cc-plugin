# my-cc-plugin

Personal Claude Code plugin marketplace by [zhenhua zhu](https://github.com/Niutie). Currently distributes one plugin:

| Plugin | Version | Purpose |
|---|---|---|
| **harness-zh** | 0.1.36 | BMad-driven sprint orchestration harness for solo-dev + AI workflows |

---

## harness-zh

A 5-stage TDD-flavored development loop (`/harness-zh:run`) plus test-automation loop (`/harness-zh:run-test`) layered on top of [BMad Method](https://github.com/BMad-Code/bmad) planning artifacts. Designed for **solo developer + AI agent** workflows where:

- One developer drives multiple AI subagents (BMad agents, Codex review, etc.)
- BMad produces planning artifacts (PRD / architecture / epics / sprint-status)
- harness-zh then drives sprint execution: backlog story → create-story → dev-story → adversarial review → fix → final review → retrospective, with state machine rooted in `sprint-status.yaml`

### Prerequisites

harness-zh **orchestrates** other tools and requires the following installed in your environment:

#### 1. BMad-METHOD toolset

[BMad-METHOD](https://github.com/bmad-code-org/BMAD-METHOD) provides `/bmad-product-brief`, `/bmad-create-prd`, `/bmad-create-architecture`, `/bmad-create-story`, `/bmad-dev-story`, `/bmad-retrospective`, `/bmad-sprint-planning`, and **~66 other skills** across 5+ modules. Most commands also have a colon-form alias (e.g. `/bmad:prd` ≡ `/bmad-create-prd`); a few newer/meta commands (`/bmad:research`, `/bmad:tech-spec`) are colon-only.

| Module | Latest version | Purpose | Required for harness-zh? |
|---|---|---|---|
| **BMad Core** | v6.6.0 | Shared utilities + cross-module config used by all other modules | **Required** (auto pulled by BMM) |
| **BMM** (Method) | v6.6.0 | Core PM workflow — PRD / architecture / story / sprint planning | **Required** |
| **BMB** (Builder) | v1.7.0 | Custom agent / workflow authoring | Recommended |
| **CIS** (Creative Innovation Suite) | v0.2.0 (early) | Brainstorming / design thinking / storytelling / innovation | Recommended |
| **TEA** (Test Architect) | v1.15.1 | Risk-driven test strategy + atdd / trace / nfr / ci | Recommended |
| **BMGD** (Game Dev Studio) | (community) | Unity / Unreal / Godot game-dev workflows | **Skip** unless game-dev project |

(Versions snapshot 2026-05-06; installer always shows current latest.)

**Install**（Node.js v20+，`uv` 可选）— 交互式（推荐）：

```bash
cd /path/to/your/project
npx bmad-method install
```

按提示回答（默认值都是合理的，敲回车即可）：

| 提示 | 推荐回答 |
|---|---|
| Installation directory | 当前项目路径（默认即可） |
| Select official modules | **全选 5 个**：BMad Core / BMM / BMB / CIS / TEA（默认就是；不要勾 BMGD 除非做游戏开发） |
| Browse community modules? | No |
| Install from a custom source? | No |
| Ready to install? | Yes |
| Integrate with | **Claude Code** （必选，否则 skills 不写到 `.claude/skills/`） |
| Module configuration | Express Setup（推荐快速默认） |
| What should agents call you? | 你的名字 |
| What is your project called? | 项目名（会写到 `_bmad/bmm/config.yaml` 的 `project_name`） |
| What language should agents use? | Chinese / English |
| Where should output files be saved? | `_bmad-output`（默认即可，harness-zh 也用这个路径） |

装完得到 ~66 skills + 4 个输出目录（`planning-artifacts/` / `implementation-artifacts/` / `test-artifacts/` / `docs/`） + `_bmad/` 配置目录。**不需要**额外的 init 步骤，直接跑 `/bmad-product-brief` 等命令即可。

非交互（CI / 自动化），一键脚本：

```bash
npx bmad-method install \
  --directory "$PWD" \
  --modules core,bmm,bmb,cis,tea \
  --tools claude-code \
  --yes
```

Without BMad, the planning artifacts (`_bmad-output/planning-artifacts/`) that `/harness-zh:init` depends on cannot be generated.

#### 2. codex plugin (optional — v0.1.28+)

Provides `/codex:rescue` and `/codex:setup` (adversarial review subagent invoked from `/harness-zh:run` stage 3 — story implementation review).

```
/plugin marketplace add openai/codex-plugin-cc
/plugin install codex@openai-codex
```

**Optional since v0.1.28.** harness-zh no longer declares codex as a hard dependency — install works without it. If codex isn't present, `/harness-zh:run` will pre-flight detect this, **skip stages 3+4** for each story, and drop a `<KEY>.codex-skipped.json` marker. Once you've installed codex later, run `/harness-zh:codex-catchup` to retroactively replay the skipped adversarial-review + dev-fix passes for all backlog markers.

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
| `/harness-zh:init` | First-time bootstrap — deploy plugin assets + (optional) BMad-driven `harness-project-config.yaml` filling. Mid-project install also detects existing `deferred-work.md` schema state and `category:harness` retro residue, prompting solo-dev to migrate. | Once per project |
| `/harness-zh:update` | After plugin upgrade — refresh project-side asset copies (does **not** touch yaml or run BMad extraction) | After each `/plugin marketplace update` |
| `/harness-zh:run` | Main sprint loop — automatically processes `sprint-status.yaml` backlog stories through 5 stages (create-story → dev-story → codex adversarial review → dev fix → bmad final review), with retrospectives and retro-residue handling | Daily |
| `/harness-zh:run-test` | Test automation sub-loop — single-story ATDD + E2E real-run (invoked by run-sprint stage 5.5 or directly) | As triggered |
| `/harness-zh:upgrade-deferred-work` | Re-detect `deferred-work.md` schema-v1 conformance + 3-tier mode switch (advisory ↔ strict). For solo-dev who picked advisory at init time and later wants to flip back, or migrated history manually and wants to verify. | Ad-hoc |
| `/harness-zh:report-issue` | One-shot bug/feedback channel — auto-collect plugin version + current sprint/story state + halt site + recent commits, then open a GitHub issue against `Niutie/my-cc-plugin` via `gh` CLI. Halt-mode submissions also include a temporary workaround so you don't have to wait for the plugin fix to keep moving. Replaces the v0.1.14-0.1.25 `upstream-feedback.md` channel. Requires `gh` CLI installed + `gh auth login` done. | Halt / sprint wrap-up / ad-hoc |
| `/harness-zh:codex-catchup` | **v0.1.27+** Catch up on stages 3+4 (codex adversarial review + dev fix) that were auto-skipped during `/harness-zh:run` because codex-in-cc was unavailable (plugin not installed / quota exhausted / not logged in). Scans `*.codex-skipped.json` markers, re-runs review + fix per story, archives marker as `*.codex-skipped.resolved.json`. Refuses to run if codex still unavailable. | After codex availability is restored |

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
| 0.1.36 | 2026-06-03 | `harness-commit.py::_seed_retro_action_items` 顶层 `retro_action_items:` 父键缺失时自动 bootstrap (closes #6)。v0.1.35 放开 epic > 26 seeding 后，首个真正 seed retro_action_items 的 epic（epic 54）撞上「父键从未被 bootstrap」→ stage 6 `raise` halt + 建议 `/bmad-sprint-planning`（会重生成整个 236-story sprint，代价不成比例）。改为：父键缺失时在 EOF 自动补 `retro_action_items:` 行（脚本自管换行，规避「手工补键漏尾随换行 → 父键与 `  epic-N-retro:` 并行同物理行 → YAML 失效」的人工坑）再落子块，与既有子块自动创建对称；不再 halt、不再触发 sprint-planning。顺带修 `orchestration_observations_test.sh` T1.f9 陈旧断言（issue #5 后 epic 27→`AA` 不再 None，retarget 到非法 epic arg），新增 T1.f14 覆盖 #6 自动 bootstrap + 无尾随换行坑。 |
| 0.1.35 | 2026-05-31 | `harness-commit.py` 三连修 (closes #5)，均为 epic 52/53 实跑暴露。**①** `_epic_letter()` 此前 epic > 26 返回 None → retro_action_items seeding + stage ⑥.5 residue pipeline 对 50s 编号 epic 静默失效；改双射 base-26（27→AA、52→AZ、53→BA），epic ≤ 26 完全向后兼容。**②** 凭证 BLACKLIST `**/*-credentials.json` 误伤 i18n 语言包（`web/src/i18n/locales/zh-CN/personal-credentials.json` 纯 UI 翻译文本）→ stage 2 halt；新增 i18n/locale 目录段 `.json` 豁免（真实凭证文件仍拦）。**③** `_bmad-output/` 下非 `implementation-artifacts/` 文件（如并行 `/bmad-brainstorming` 产出的 `brainstorming/*.md`）被当 project code 误 `git add` 进 story commit；新增 OUT_OF_SCOPE_BMAD gate 拦截 + 提示单独提交。新增 `harness_commit_issue5_test.sh`（5 fixture，源树直跑）。 |
| 0.1.34 | 2026-05-29 | `sprint-status.py` 兼容 BMad 多行块 `sprint-status.yaml` (closes #4). `STORY_KEY_RE` 旧逻辑只匹配单行 `key: status`，把 BMad v6.7.1 多行块格式（`key:` 换行接 `status:`/`depends_on:`）里 nested 的 `status:` 行误当成名叫 "status" 的 story → `next` 吐 "status"、`status`/`epic-all-done` 全失效，`harness-zh:run` 在所有 BMad 多行块项目上跑不起来。修复双格式兼容（向后兼容单行）：`_iter_dev_status` 改 base_indent 状态机 + `BLOCK_KEY_RE`/`NESTED_STATUS_RE`，多行块 entry 读 nested status 子键、line_index 指向承载 status 值的行；`cmd_set` 改通用 field 匹配（单行=key 行；多行块=status 行），保留行尾 inline 注释，`depends_on` 等块内子键不受影响。单行/多行块/混合三格式回归全 PASS；真实 232-story 多行块 yaml 上 next/status/epic-all-done/set 均正确。 |
| 0.1.33 | 2026-05-29 | `/harness-zh:run` 启动前置自动兑现 retro DEV items (fixes #3). 新增 §0.A.0 gate：起跑首条 story 命中 `^[4-6]-` 时，先用 `grep_pending_dev_retro_items.sh` 枚举未兑现 `category: dev` retro 项 → 对每个有 chore_spec 的项 spawn fresh subagent 实现 → Edit 翻 status done → 新 `retro-fulfill` commit stage 收口，全清后才 spawn stage ①。避免「stage-1 subagent 干完活 → commit 撞 pre-commit gate ① → halt」的 token 浪费。缺 chore_spec 的项不臆造，列给用户走 `process_retro_residue.sh` 补 spec 或 `--no-verify` 留痕。范围限启动那一刻；mid-run epic 切换的新 seed dev 项沿用既有手工路径。 |
| 0.1.32 | 2026-05-28 | BLACKLIST_PATTERNS `**/*credentials*` 太宽误伤业务命名 (fixes #2). 替换为精确凭证文件命名集合（`**/credentials[.{json,yaml,yml,ini,txt}]` / `**/*-credentials[.ext]` / `**/*.credentials`）；matches_blacklist 加防御层 2 — BMad artifacts/ 路径下 md/json/yaml/yml 一律豁免 blacklist。caller 仓库 epic 53 的 `53-1-db-migration-credentials-表-...md` 等合法 spec 不再被拦；`credentials_service.go` / `V53_create_credentials_table.sql` 等业务源码也不再误伤。真正凭证文件（`aws-credentials.json` / `.aws/credentials` / `kong.credentials`）继续被拦。 |
| 0.1.31 | 2026-05-28 | retro_action_items parser 兜底放宽 + follow-through filter (fixes #1). `_parse_retro_action_items` 现接受 4 种 Form 2 col 1 变体（letter-suffix sub-id / bold-wrap / paren annotation）+ 4 种 Form 3 whole-bold 变体（em-dash / hyphen / CJK paren sep）。section detection 增加 follow-through / carryover 关键字过滤，prev-epic recap section 不再被误抢 → canonical §"Action items" 取 last。Form 2 + Form 3 改为共存合并（按 code 去重），处理 §8.1-§8.4 表格 + §8.5 bullets 混合 retro 布局。Closes the 3-epic-in-a-row halt cycle by adapting to BMad retrospective skill 's empirical output 而非 fail-loud 死等 skill 转向。 |
| 0.1.30 | 2026-05-27 | Hostile-env hardening for plugin-discovery pipelines: switch to `command grep` inside `find \| while ... done` loops (5 critical-path locations across init / update / upgrade-deferred-work commands + `discover_plugin_root.sh` + `collect_issue_context.sh`). Closes a class of bugs where shell-function wrappers around `grep` (Claude Code injects one on some Linux dev envs) `exec`-replace the pipeline's subshell, killing the loop after one iteration. Bootstrap now survives the wrapped-grep environment. |
| 0.1.29 | 2026-05-27 | inline bootstrap 改 2-tier（cache 优先 + marketplaces 兜底）— 修复 fresh dev env 上 `/harness-zh:init` / `update` / `upgrade-deferred-work` 探测不到 plugin 路径 halt（Claude Code 在某些 fresh install 场景直接从 `marketplaces/<name>/plugins/<plugin>/` 服务 plugin，不 populate `cache/`，老的硬 `*/cache/*` filter 误杀这条命中）。 |
| 0.1.28 | 2026-05-27 | Drop hard `codex@openai-codex` dependency from `plugin.json` — plugin now installs cleanly without codex. `/harness-zh:init` adds §A.4.d codex availability probe (advisory only; surfaces install hint if missing). Existing graceful-skip / `codex-skipped.json` marker / `/harness-zh:codex-catchup` flow already handles the runtime side. |
| 0.1.27 | 2026-05-09 | Engineering hardening pass (codex multi-round review): release-gate script (`release_check.sh`) catches version drift + bad command frontmatter; manifest-based `/harness-zh:update` purge no longer touches user-owned `.claude/commands/*` files; new `/harness-zh:codex-catchup` plus stage-3 graceful skip when codex-in-cc unavailable; central `run_all_tests.sh` + GitHub Actions CI with bootstrap fixture; shared `deferred_work_schema_lib.sh` (pre-commit ↔ lint dedup); `harness_config.py --get` CLI eliminates 3 hand-rolled YAML parsers; UTF-8 `encoding=` everywhere. |
| 0.1.26 | 2026-05-09 | New `/harness-zh:report-issue` — auto-context bug/feedback channel that opens GitHub issues via `gh` CLI; halt mode also yields a temporary workaround. Retires `upstream-feedback.md` (extract/detect scripts + template removed); retro skill no longer splits `category:harness` into a separate file. |
| _(0.1.17 – 0.1.25)_ | – | Internal iteration only — squash-merged into 0.1.26; no public marketplace release. See `changelog.md` for detail. |
| 0.1.16 | 2026-05-07 | Codex adversarial review fixes: detector exit code propagation / upgrade-deferred-work safe `mv`-after-source-verify / atomic + idempotent migration writes |
| 0.1.15 | 2026-05-07 | `argument-hint` frontmatter for slash-command autocomplete (`/harness-zh:run [--story ...]` etc.) |
| 0.1.14 | 2026-05-07 | `category:harness` retro items split off `sprint-status.yaml` into `.claude/harness/upstream-feedback.md` (plugin-maintainer feedback channel) |
| 0.1.13 | 2026-05-07 | Mid-project `deferred-work.md` schema v1 detection + 3-tier migration (advisory / archive+greenfield / manual backfill); new `/harness-zh:upgrade-deferred-work` command |
| 0.1.11 - 0.1.12 | 2026-05-06/07 | CJK story-key support (sprint-status regex + git quotepath + utf-8 decode-safe) |
| 0.1.0 | 2026-05-06 | Initial plugin extraction from Aegis AI Audit project's `.claude/harness/` |

See [`plugins/harness-zh/changelog.md`](plugins/harness-zh/changelog.md) for detailed per-commit history.

---

## License

Personal-use marketplace. No license declared at repo level — assume "all rights reserved" by default. If this changes for a particular plugin, that plugin's `plugin.json` will declare its own license.

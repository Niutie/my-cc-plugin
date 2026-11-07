# my-cc-plugin

Personal Claude Code plugin marketplace by [zhenhua zhu](https://github.com/Niutie). Distributes five plugins:

| Plugin | Version | What it does |
|---|---|---|
| **[article-maker](plugins/article-maker/README.md)** | 0.1.1 | Turn any source (URL / PDF / DOCX / Markdown / text / screenshots) into a beautiful, share-ready single-file HTML article (optional PDF) |
| **[super-harness](plugins/super-harness/README.md)** | 0.5.0 | BMad-driven sprint orchestration for solo-dev + AI workflows: run stories one at a time in-session, or in parallel with one worktree + headless Claude worker per story (harness-zh merged in) |
| **[harness-zh](plugins/harness-zh/README.md)** | 0.2.2 | Deprecated: merged into super-harness 0.2.0, kept only so existing installs can migrate |
| **[ppt-maker](plugins/ppt-maker/README.md)** | 1.1.0 | Turn source material into an offline web deck **and** a genuinely editable `.pptx`, from one `deck.json` source of truth |
| **[video-maker](plugins/video-maker/README.md)** | 1.11.0 | Turn scripts / articles / lessons into click-driven 16:9 web presentations you can screen-record as cinematic videos |

---

## Install

Add the marketplace once, then install whichever plugin you want:

```
/plugin marketplace add https://github.com/Niutie/my-cc-plugin.git
/plugin install article-maker@my-cc-plugin
/plugin install super-harness@my-cc-plugin
/plugin install ppt-maker@my-cc-plugin
/plugin install video-maker@my-cc-plugin
```

`/plugin marketplace update my-cc-plugin` pulls later releases.

---

## Plugins

### super-harness

A sprint orchestration plugin layered on top of [BMad Method](https://github.com/bmad-code-org/BMAD-METHOD), built for **solo developer + AI agent** workflows. BMad produces the planning artifacts; super-harness then works through the backlog in `sprint-status.yaml`. Each story goes through one `bmad-build-auto` run (plan, implement, multi-layer review, commit), an audit of the committed range, an external codex review when codex is not already a build review layer, an optional follow-up review, then status sync and the epic retrospective. Unit and integration tests are written and run inside `bmad-build-auto`; e2e and acceptance testing is left to the test team. The per-story steps live in one manual, `pipeline.md`, which both run modes follow.

- `/super-harness:run-inline` runs one story at a time in the current session, so every step is visible. Use it to debug or tune the pipeline.
- `/super-harness:run` runs independent stories in parallel. Dependencies come from `deps_overrides`, the top-level `story_dependencies` map in `sprint-status.yaml` (works with BMad 6.12.4's single-line layout), or block-style `depends_on`; `ext-*` entries mark outside conditions, and statuses listed in `parked_statuses` are kept on the board without blocking the epic barrier or the retro. Each ready story gets its own git worktree and a headless `claude -p` worker; finished lanes are rebased onto the sprint branch one at a time and fast-forwarded in, with conflicts in the shared ledgers resolved automatically. If `verify_command` is set in `parallel.yaml`, it runs on the merged code before each fast-forward and a failure holds that lane. The main session then runs build-sync and the epic retro serially.
- **Commands:** `/super-harness:init`, `:update`, `:run`, `:run-inline`, `:board`, `:codex-catchup`, `:report-issue`, `:upgrade-deferred-work`
- **Requires:** [BMad-METHOD](https://github.com/bmad-code-org/BMAD-METHOD) ≥ 6.11 and [uv](https://docs.astral.sh/uv/); for `:run` also git ≥ 2.38 and the `claude` CLI. The codex plugin is optional (cross-model review)
- **Migrating from harness-zh:** install super-harness, run `/super-harness:init` in the project (config, tags and sprint state carry over), then `/plugin uninstall harness-zh`. `/harness-zh:run` maps to `/super-harness:run-inline` with the same flags
- **Full docs:** [`plugins/super-harness/README.md`](plugins/super-harness/README.md)（中文）· [`pipeline.md`](plugins/super-harness/pipeline.md) · [`architecture.md`](plugins/super-harness/architecture.md) · [`architecture-parallel.md`](plugins/super-harness/architecture-parallel.md)

### harness-zh (deprecated)

Merged into super-harness 0.2.0 and frozen at 0.2.1. It stays in the marketplace only so existing installs can still update and migrate; see the migration steps above.

### video-maker

Turns a script, article, or lesson into a click-driven 16:9 web presentation you can screen-record as a cinematic video ("dynamic PPT, but not PPT"). Each click advances one narration beat, every step owns the full 1920×1080 stage, and the progress chrome stays hidden so recordings come out clean. Bundles the **web-video-presentation** skill: a Vite + React + TypeScript scaffold, a `(chapter, step)` cursor model, 24 themes (including a `training-center` enablement-course style), a provider-agnostic TTS audio pipeline (MiniMax + OpenAI + free no-key edge-tts built in), and hard collaboration checkpoints.

- **Genre-aware:** defaults to the **training-center** genre (structure-driven L0–L3 enablement / certification courses); switches to a commentary / entertainment register only when you ask. Output language (zh / en) is always confirmed up front.
- **One-take recording:** once audio is synthesized, open `?auto=1` and the whole film auto-plays, advancing on each clip's end — screen-record it in a single pass with no clicking.
- **Two ways to drive it:** ask in natural language (the bundled skill is model-invoked as `video-maker:web-video-presentation`), or use the commands below.
- **Commands:** `/video-maker:plan`, `:scaffold`, `:chapter`, `:chapters`, `:audio`, `:record`, `:themes`, and the one-click `:make`
- **Full docs:** [README](plugins/video-maker/README.md)（中文）

### ppt-maker

Turns source material into an **offline-openable web deck** and a **genuinely editable `.pptx`** — the one thing hand-written tsx pages can't give you, because colleagues need to keep editing the deck in PowerPoint. One `deck.json` is the source of truth: it compiles to a 12×8 composition DSL, then dual-renders through a single shared geometry engine — React for the browser, pptxgenjs for PowerPoint — at an exact 144 px/inch (`pt = px / 2`), with a verifier that unzips the `.pptx` and checks every box landed on the same EMU coordinate.

- **Editable, not a screenshot:** 18 chart kinds — 7 export as native PowerPoint charts with an editable data sheet, 11 as real vector shapes (including custGeom sankey ribbons).
- **Structure on tap:** 23 layout skeletons, 8 of them analysis frameworks (SWOT / Porter / PEST / Business Model Canvas / BCG / Double Diamond / AARRR / Flywheel), plus 24 themes whose chart palettes are generated and validated for CVD separation and contrast.
- **Edit in the browser:** an in-console editor writes text and typed controls straight back into `deck.json`, and exports the `.pptx` in one click (dev server only — it saves first, then shells out to the same exporter the CLI runs); a deck validator catches overflow and dropped required facts.
- **Commands:** `/ppt-maker:source`, `:plan`, `:scaffold`, `:build`, `:review`, `:deliver`, `:export`, `:themes`, and the one-click `:make`
- **Full docs:** [README](plugins/ppt-maker/README.md)（中文）

### article-maker

Turns a URL, PDF, DOCX, Markdown file, screenshot, or pasted notes into a **beautiful single-file HTML article** that opens offline and is easy to share, with an optional companion PDF. Built on the reacticle component protocol — semantic components plus a theme-constrained Raw escape hatch rather than hand-written HTML/CSS — and driven through a small harness: source → plan → checkpoint → build → final review → repair, defaulting to a long-form article with 100% of the source's information preserved.

- **Commands:** `/article-maker:source`, `:plan`, `:scaffold`, `:first-spread`, `:build`, `:review`, `:deliver`, `:themes`, and the one-click `:make`
- **Full docs:** [README](plugins/article-maker/README.md)（中文）

---

## License

Personal-use marketplace. No license declared at repo level — assume "all rights reserved" by default. If this changes for a particular plugin, that plugin's `plugin.json` will declare its own license.

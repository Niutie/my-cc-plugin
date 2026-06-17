# my-cc-plugin

Personal Claude Code plugin marketplace by [zhenhua zhu](https://github.com/Niutie). Distributes two plugins:

| Plugin | Version | What it does |
|---|---|---|
| **[harness-zh](plugins/harness-zh/README.md)** | 0.1.39 | BMad-driven sprint orchestration harness for solo-dev + AI workflows |
| **[video-maker](plugins/video-maker/skills/web-video-presentation/README.md)** | 1.8.1 | Turn scripts / articles / lessons into click-driven 16:9 web presentations you can screen-record as cinematic videos |

---

## Install

Add the marketplace once, then install whichever plugin you want:

```
/plugin marketplace add https://github.com/Niutie/my-cc-plugin.git
/plugin install harness-zh@my-cc-plugin
/plugin install video-maker@my-cc-plugin
```

`/plugin marketplace update my-cc-plugin` pulls later releases.

---

## Plugins

### harness-zh

A 5-stage TDD-flavored development loop (`/harness-zh:run`) plus a test-automation loop (`/harness-zh:run-test`) layered on top of [BMad Method](https://github.com/bmad-code-org/BMAD-METHOD) planning artifacts. Built for **solo developer + AI agent** workflows: BMad produces the planning artifacts, then harness-zh drives sprint execution — backlog story → create-story → dev-story → adversarial review → fix → final review → retrospective, with the state machine rooted in `sprint-status.yaml`.

- **Commands:** `/harness-zh:init`, `:run`, `:run-test`, `:update`, `:upgrade-deferred-work`, `:report-issue`, `:codex-catchup`
- **Requires:** [BMad-METHOD](https://github.com/bmad-code-org/BMAD-METHOD) (planning artifacts); the codex plugin is optional (adversarial review)
- **Full docs:** [`plugins/harness-zh/README.md`](plugins/harness-zh/README.md) · architecture + changelog live alongside it

### video-maker

Turns a script, article, or lesson into a click-driven 16:9 web presentation you can screen-record as a cinematic video ("dynamic PPT, but not PPT"). Each click advances one narration beat, every step owns the full 1920×1080 stage, and the progress chrome stays hidden so recordings come out clean. Bundles the **web-video-presentation** skill: a Vite + React + TypeScript scaffold, a `(chapter, step)` cursor model, 24 themes (including a `training-center` enablement-course style), a provider-agnostic TTS audio pipeline (MiniMax + OpenAI + free no-key edge-tts built in), and hard collaboration checkpoints.

- **Genre-aware:** defaults to the **training-center** genre (structure-driven L0–L3 enablement / certification courses); switches to a commentary / entertainment register only when you ask. Output language (zh / en) is always confirmed up front.
- **One-take recording:** once audio is synthesized, open `?auto=1` and the whole film auto-plays, advancing on each clip's end — screen-record it in a single pass with no clicking.
- **Two ways to drive it:** ask in natural language (the bundled skill is model-invoked as `video-maker:web-video-presentation`), or use the commands below.
- **Commands:** `/video-maker:plan`, `:scaffold`, `:chapter`, `:chapters`, `:audio`, `:record`, `:themes`, and the one-click `:make`
- **Full docs:** [README](plugins/video-maker/skills/web-video-presentation/README.md)（中文）

---

## License

Personal-use marketplace. No license declared at repo level — assume "all rights reserved" by default. If this changes for a particular plugin, that plugin's `plugin.json` will declare its own license.

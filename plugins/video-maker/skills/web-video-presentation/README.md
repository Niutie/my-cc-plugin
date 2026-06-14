# video-maker — Web Video Presentation

**A Claude Code plugin that turns scripts and articles into click-driven 16:9 web presentations you can screen-record as cinematic videos.** It bundles the `web-video-presentation` skill — a method-driven design + collaboration workflow.

[中文文档](./README.zh-CN.md) · [Back to marketplace root](../../../../README.md)

---

## What Is This?

The `video-maker` plugin helps an agent build a Vite + React + TypeScript presentation that behaves like a video production surface rather than a slide deck. Each click advances one narration beat, each step owns the whole 1920×1080 stage, and the progress UI stays hidden unless hovered so the output is clean for screen recording.

It is designed for:

- Turning a written article into a Bilibili / YouTube / video-channel narration script
- Turning an existing voiceover script into a cinematic web presentation
- Building product demos, tutorials, keynote-style explainers, and visual talks
- Creating “dynamic PPT, but not PPT” experiences with strong motion and pacing
- Optionally synthesizing narration audio after the visual outline is approved

The plugin is primarily a **methodology and collaboration workflow**. The scaffold supplies reusable tokens, stage primitives, themes, and examples, but each project should still choose a visual language that fits the topic.

---

## Core Ideas

- **Fixed 16:9 stage** — content is authored in a stable 1920×1080 coordinate system and scaled to the viewport.
- **One global step cursor** — click or keyboard advances `(chapter, step)`, with the cursor persisted locally.
- **One step, one idea** — every beat gets a focused full-screen scene instead of accumulating slide bullets.
- **Script beats drive structure** — narration rhythm maps directly to visual steps.
- **Hidden chrome** — progress controls are hover-only, keeping recordings clean.
- **Motion first** — each scene needs a moving visual anchor; static paragraphs are treated as a smell.
- **Theme tokens** — visual decisions flow through semantic tokens so themes can change the whole feel.
- **Pluggable TTS** — provider-agnostic audio runner ships **two built-in providers** (MiniMax `mmx-cli` and OpenAI TTS via curl); swap to ElevenLabs / edge-tts / Azure / Google Cloud / macOS `say` / any self-hosted TTS by dropping a single shell file into `tts-providers/`.
- **Hard checkpoints** — the agent pauses after script/theme alignment, after outline approval, and before optional audio synthesis.

---

## Workflow

```text
Phase 1.1  Identify input
Phase 1.2  Article -> narration script
   |
Checkpoint A1  Script, theme, and rough asset plan
   |
Phase 1.3  Script + article -> outline.md
   |
Checkpoint A2  Outline approval + development mode
   |
Phase 2    Build the Vite / React / TS presentation
   |
Checkpoint B   Ask whether to synthesize audio
   |
Phase 3    Optional audio synthesis
Phase 4    Recording and post-production
```

The checkpoints are part of the plugin's contract: the agent should not silently rush from raw article to finished code. Theme choice influences motion design, and outline approval keeps chapter pacing from drifting.

---

## What It Ships

```text
video-maker/                             # the plugin
├── .claude-plugin/
│   └── plugin.json                      # plugin manifest — auto-discovers the skill below
└── skills/
    └── web-video-presentation/          # the bundled skill
        ├── SKILL.md
        ├── README.md / README.zh-CN.md
        ├── references/
        │   ├── CHAPTER-CRAFT.md
        │   ├── OUTLINE-FORMAT.md
        │   ├── SCRIPT-STYLE.md
        │   ├── THEMES.md
        │   ├── AUDIO.md
        │   ├── RECORDING.md
        │   └── EXAMPLES/
        ├── scripts/
        │   └── scaffold.sh
        ├── templates/
        │   ├── index.html
        │   ├── vite.config.ts
        │   ├── scripts/
        │   │   ├── extract-narrations.ts
        │   │   ├── synthesize-audio.sh       # provider-agnostic runner
        │   │   └── tts-providers/            # 1 file = 1 TTS backend
        │   │       ├── README.md             # contract + ready-to-paste ElevenLabs / edge-tts / Azure / Google / say snippets
        │   │       ├── minimax.sh            # default — uses mmx-cli
        │   │       └── openai.sh             # built-in — uses OPENAI_API_KEY via curl
        │   └── src/
        └── themes/                    # 23 themes, each with its own signature
            ├── midnight-press/
            ├── warm-keynote/
            ├── newsroom/
            ├── bauhaus-bold/
            └── ...                     # full list in references/THEMES.md
```

---

## Quick Start

Install the plugin from the marketplace:

```
/plugin marketplace add Niutie/my-cc-plugin
/plugin install video-maker@my-cc-plugin
```

Once enabled, the bundled skill is **model-invoked** — just ask Claude to "turn this article/script into a web-video presentation" and it picks up `video-maker:web-video-presentation`, then walks you through the workflow above.

To scaffold manually from inside a project (the plugin runs this for you):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/web-video-presentation/scripts/scaffold.sh" ./presentation --theme=paper-press
```

List available themes:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/web-video-presentation/scripts/scaffold.sh" --list-themes
```

The generated `presentation/` project is a normal Vite + React + TypeScript app. Run it like any other Vite project, then record the 16:9 stage with your screen recorder.

---

## Reference Map

- [CHAPTER-CRAFT.md](./references/CHAPTER-CRAFT.md) — core rules, chapter implementation, and visual checklist (Part 0 is the ten principles)
- [OUTLINE-FORMAT.md](./references/OUTLINE-FORMAT.md) — required outline structure
- [SCRIPT-STYLE.md](./references/SCRIPT-STYLE.md) — article-to-narration rewrite guidance
- [THEMES.md](./references/THEMES.md) — theme token contract + 23 built-in themes + how to derive your own
- [EXAMPLES/](./references/EXAMPLES/) — optional chapter-structure references (hook / list-reveal / case-tech-review)
- [AUDIO.md](./references/AUDIO.md) — optional narration synthesis workflow (provider-agnostic)
- [tts-providers/README.md](./templates/scripts/tts-providers/README.md) — TTS provider contract + 2 built-ins (minimax / openai) + ready-to-paste snippets for ElevenLabs / edge-tts / Azure / Google Cloud / macOS say
- [RECORDING.md](./references/RECORDING.md) — screen recording and post-production notes


# video-maker — Web Video Presentation

**一个 Claude Code 插件：把文章或口播稿做成点击驱动的 16:9 网页演示，并通过录屏产出有电影感的视频。** 它内置 `web-video-presentation` skill —— 一套方法论驱动的设计 + 协作流程。

[English](./README.md) · [返回集合首页](../../../../README.md)

---

## 这是什么？

`video-maker` 插件帮 Agent 构建一种 Vite + React + TypeScript 演示：它看起来不是传统幻灯片，而更像为录屏设计的视频舞台。每次点击推进一个口播节拍，每一步独占 1920×1080 舞台，进度 UI 平时隐藏，只有悬浮时出现，方便录出干净画面。

它适合：

- 把文章改写成 B 站 / YouTube / 视频号风格口播稿
- 把已有口播稿做成有节奏的网页演示
- 做产品演示、教程、keynote 式讲解、视觉 talk
- 做“动态 PPT，但不要像 PPT”的演示体验
- 在视觉 outline 对齐后，可选合成口播音频

这个插件的核心是**方法论 + 协作流程**。脚手架提供 token、舞台原语、主题和示例，但每个项目仍然应该根据主题重新选择视觉语言。

---

## 核心理念

- **固定 16:9 舞台**：内容写在稳定的 1920×1080 坐标系里，再按视口缩放。
- **一个全局 step 游标**：点击或键盘推进 `(chapter, step)`，游标本地持久化。
- **一步一个想法**：每个节拍独占整屏，不堆叠项目符号。
- **口播节拍驱动结构**：讲述节奏直接映射为视觉 step。
- **隐藏 chrome**：进度控制悬浮才出现，录屏画面保持干净。
- **动效优先**：每一步都需要一个移动的视觉锚点，静态正文是坏味道。
- **主题 token**：视觉属性通过语义 token 驱动，换主题不只是换颜色。
- **可插拔 TTS**：provider-agnostic 音频 runner，**内置 2 个 provider**（MiniMax `mmx-cli` + OpenAI TTS via curl）；往 `tts-providers/` 丢一个 `.sh` 就能换成 ElevenLabs / edge-tts / Azure / Google Cloud / macOS `say` / 任何自部署 TTS。
- **硬 checkpoint**：稿子/主题、outline、音频合成前都必须停下来与用户确认。

---

## 工作流

```text
Phase 1.1  识别用户输入
Phase 1.2  文章 -> 口播稿
   |
Checkpoint A1  稿子、主题、粗略素材计划
   |
Phase 1.3  口播稿 + 原文 -> outline.md
   |
Checkpoint A2  outline 确认 + 开发模式选择
   |
Phase 2    构建 Vite / React / TS 演示
   |
Checkpoint B   询问是否合成音频
   |
Phase 3    可选音频合成
Phase 4    录屏与后期
```

这些 checkpoint 是插件契约的一部分：Agent 不应该从原文一路闷头做到成品。主题选择会影响动效气质，outline 确认能避免章节节奏跑偏。

---

## 内含内容

```text
video-maker/                             # 插件
├── .claude-plugin/
│   └── plugin.json                      # 插件清单 —— 自动发现下面这个 skill
└── skills/
    └── web-video-presentation/          # 内置的 skill
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
        │   │   └── tts-providers/            # 一个文件 = 一个 TTS 后端
        │   │       ├── README.md             # 三函数契约 + ElevenLabs / edge-tts / Azure / Google / say 的现成片段
        │   │       ├── minimax.sh            # 默认 provider（mmx-cli）
        │   │       └── openai.sh             # 内置：OpenAI TTS（curl + OPENAI_API_KEY）
        │   └── src/
        └── themes/                    # 23 套主题，每套独立设计签名
            ├── midnight-press/
            ├── warm-keynote/
            ├── newsroom/
            ├── bauhaus-bold/
            └── ...                     # 完整列表见 references/THEMES.md
```

---

## 快速上手

从 marketplace 安装插件：

```
/plugin marketplace add https://github.com/Niutie/my-cc-plugin.git
/plugin install video-maker@my-cc-plugin
```

启用后，内置的 skill 由**模型自动触发** —— 直接让 Claude「把这篇文章 / 口播稿做成网页视频演示」，它会接管 `video-maker:web-video-presentation` 并带你走上面的工作流。

如果要手动脚手架（插件内部也是跑这个）：

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/web-video-presentation/scripts/scaffold.sh" ./presentation --theme=paper-press
```

查看可用主题：

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/web-video-presentation/scripts/scaffold.sh" --list-themes
```

生成的 `presentation/` 是普通 Vite + React + TypeScript 项目。启动后用录屏工具录制 16:9 舞台即可。

---

## Reference Map

- [CHAPTER-CRAFT.md](./references/CHAPTER-CRAFT.md)：核心原则 + 章节实现规则 + 视觉 checklist（Part 0 即十条原则）
- [OUTLINE-FORMAT.md](./references/OUTLINE-FORMAT.md)：outline 必须遵循的结构
- [SCRIPT-STYLE.md](./references/SCRIPT-STYLE.md)：文章转口播稿规则
- [THEMES.md](./references/THEMES.md)：主题 token 契约 + 23 套内置主题 + 创作新主题流程
- [EXAMPLES/](./references/EXAMPLES/)：可选章节结构参考（钩子型 / 列举型 / 技术评测案例）
- [AUDIO.md](./references/AUDIO.md)：可选口播音频合成流程（provider-agnostic）
- [tts-providers/README.md](./templates/scripts/tts-providers/README.md)：TTS provider 三函数契约 + 内置 2 个 (minimax / openai) + ElevenLabs / edge-tts / Azure / Google / macOS say 的现成代码片段
- [RECORDING.md](./references/RECORDING.md)：录屏与后期注意事项


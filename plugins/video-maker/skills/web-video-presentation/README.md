# video-maker — Web Video Presentation

**一个 Claude Code 插件：把文章或口播稿做成点击驱动的 16:9 网页演示，并通过录屏产出有电影感的视频。** 它内置 `web-video-presentation` skill —— 一套方法论驱动的设计 + 协作流程。

[返回集合首页](../../../../README.md)

---

## 这是什么？

`video-maker` 插件帮 Agent 构建一种 Vite + React + TypeScript 演示：它看起来不是传统幻灯片，而更像为录屏设计的视频舞台。每次点击推进一个口播节拍，每一步独占 1920×1080 舞台，进度 UI 平时隐藏，只有悬浮时出现，方便录出干净画面。

它适合：

- 把文章改写成 B 站 / YouTube / 视频号风格口播稿
- 把已有口播稿做成有节奏的网页演示
- 做产品演示、教程、keynote 式讲解、视觉 talk
- 做企业培训 / 认证 / Partner 赋能课程视频（默认的**培训中心**体裁——用 L0–L3 给课程定位，再按粒度选章节结构）
- 做“动态 PPT，但不要像 PPT”的演示体验
- 在计划对齐后，可选合成口播音频

这个插件的核心是**方法论 + 协作流程**。脚手架提供 token、舞台原语、主题和示例，但每个项目仍然应该根据主题重新选择视觉语言。

---

## 核心理念

- **固定 16:9 舞台**：内容写在稳定的 1920×1080 坐标系里，再按视口缩放。
- **一个全局 step 游标**：点击或键盘推进 `(chapter, step)`，游标本地持久化。
- **一步一个想法**：每个节拍独占整屏，不堆叠项目符号。
- **口播节拍驱动结构**：讲述节奏直接映射为视觉 step。
- **先定成片语言**：在动笔前先锁定中文 / 英文（决定口播稿、屏幕文案、TTS 音色），**无论原文中 / 英都要问**，不预设跟随原文。
- **体裁驱动结构**：默认走**培训中心**体裁（目标先行、能力边界、阶段小结）。L0–L3 是给课程**定位**的 scoping 框架，章节结构按**粒度**（课程总览 vs 单模块深讲）选——**不是逐章风格开关**，plugin 也不会自动识别这条属于哪一层；只有用户明确要解说 / 娱乐向才切。
- **隐藏 chrome**：进度控制悬浮才出现，录屏画面保持干净。
- **动效优先**：每一步都需要一个移动的视觉锚点，静态正文是坏味道。
- **主题 token**：视觉属性通过语义 token 驱动，换主题不只是换颜色。
- **一镜到底自动播放**：合成音频后，`?auto=1` 全程自动播放、每段音频播完自动推进，全程不用点鼠标；每次加载都从头开始，录废了刷新页面即可重来。
- **可插拔 TTS**：provider-agnostic 音频 runner，**内置 3 个 provider**（MiniMax `mmx-cli` + OpenAI TTS via curl，均收费；外加 **edge-tts 免费 / 无 key**，不传音色时按语言自动挑自然男声——中文 Yunxi / 英文 Andrew）；往 `tts-providers/` 丢一个 `.sh` 就能换成 ElevenLabs / Azure / Google Cloud / macOS `say` / 任何自部署 TTS。
- **硬 checkpoint**：在统一的「计划对齐」节点（稿子 + outline + 主题 + 素材 + 开发模式）停一次，第 1 章做完再停一次验收，音频合成前再停一次。

---

## 工作流

```text
Phase 1   内容编写（一次产出）
  1.1  识别用户输入 + 确认成片语言（中 / 英，无论原文语言都要问、不预设跟随原文）+ 确认体裁（默认培训中心）
  1.2  一次产出 script.md 和 outline.md（按确认的语言）
   |
Checkpoint Plan   <- 硬节点。一次对齐 5 件事：
                     稿子 · outline · 主题 · 素材 · 开发模式
   |
Phase 2   构建 Vite / React / TS 演示
  2.1  用选定主题脚手架
  2.2  第 1 章主线程做完整、可直接验收的样板  ->  硬节点，停下验收
  2.3  第 2~N 章（模式 A 逐章 · B 顺序 · C 并行 subagent）
   |
Checkpoint Audio  <- 硬节点。是否合成口播音频？
   |
Phase 3   可选音频合成
Phase 4   录屏与后期
```

这些 checkpoint 是插件契约的一部分：Agent 不应该从原文一路闷头做到成品。**script.md 和 outline.md 现在一次产出**，并在单一的 **Checkpoint Plan** 上统一对齐——用户在一个节点同时确认 5 件事（稿子、outline、主题、素材、开发模式），不再分成两道关。第 1 章永远在主线程做完并验收后才放量，先把设计语言锚定再扩展。

---

## 内含内容

```text
video-maker/                             # 插件
├── .claude-plugin/
│   └── plugin.json                      # 插件清单 —— 自动发现下面这个 skill
└── skills/
    └── web-video-presentation/          # 内置的 skill
        ├── SKILL.md
        ├── README.md
        ├── references/
        │   ├── SCRIPT-STYLE.md
        │   ├── TRAINING-CENTER.md            # 默认体裁的 L0–L3 框架
        │   ├── OUTLINE-FORMAT.md
        │   ├── CHAPTER-CRAFT.md
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
        │   │       ├── README.md             # 三函数契约 + ElevenLabs / Azure / Google / say 的现成片段
        │   │       ├── minimax.sh            # 默认 provider（mmx-cli，收费）
        │   │       ├── openai.sh             # 内置：OpenAI TTS（curl + OPENAI_API_KEY，收费）
        │   │       └── edge-tts.sh           # 内置：免费 / 无 key（pip install edge-tts）
        │   └── src/
        └── themes/                    # 24 套主题，每套独立设计签名
            ├── training-center/        # 默认体裁推荐的样式
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

- [SCRIPT-STYLE.md](./references/SCRIPT-STYLE.md)：文章转口播稿规则（信息保留度 + 去 AI 味通用层，对所有体裁适用）
- [TRAINING-CENTER.md](./references/TRAINING-CENTER.md)：**默认体裁**框架——产品无关的 L0–L3 分层、课程总览 vs 单模块两种粒度、中英双语 + 时长预算约定
- [OUTLINE-FORMAT.md](./references/OUTLINE-FORMAT.md)：outline 必须遵循的结构（章节 / step 切分 + 章节级信息池；**刻意不规划动画**）
- [CHAPTER-CRAFT.md](./references/CHAPTER-CRAFT.md)：写章节的单一必读入口——核心原则、视觉演示要求、逐步揭示、双源原则、反 AI 味、代码红线、完工自检
- [THEMES.md](./references/THEMES.md)：主题 token 契约 + 24 套内置主题 + 创作新主题流程
- [EXAMPLES/](./references/EXAMPLES/)：可选章节结构参考（钩子型 / 列举型 / 技术评测案例）
- [AUDIO.md](./references/AUDIO.md)：可选口播音频合成流程（provider-agnostic）
- [tts-providers/README.md](./templates/scripts/tts-providers/README.md)：TTS provider 三函数契约 + 内置 3 个 (minimax / openai / edge-tts 免费) + ElevenLabs / Azure / Google / macOS say 的现成代码片段
- [RECORDING.md](./references/RECORDING.md)：录屏（含 `?auto=1` 一镜到底路径）与后期注意事项

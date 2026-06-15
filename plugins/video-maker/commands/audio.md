---
description: 音频合成（可选）— 扫所有 narrations.ts 出 segments，review 后用 TTS provider 逐 step 合成 mp3
argument-hint: '[--provider=minimax|openai|edge-tts|…]'
allowed-tools: Bash, Read, Edit, Write
---

你在执行 video-maker 的 **Phase 3 音频合成**。参数：$ARGUMENTS
必读：`${CLAUDE_PLUGIN_ROOT}/skills/web-video-presentation/references/AUDIO.md`
（换 / 加 provider 看 `${CLAUDE_PLUGIN_ROOT}/skills/web-video-presentation/templates/scripts/tts-providers/README.md` —— 三函数契约 + 现成片段）。

步骤（在 `presentation/` 下）：

1. `npm run extract-narrations` → 扫所有章节 `narrations.ts` 出 `audio-segments.json`。
2. 让用户扫一眼 `audio-segments.json` 确认文本对（这也是 Checkpoint Audio 的落点）。
3. 合成（增量；音色按 Phase 1.1.5 确认的成片语言走 —— edge-tts 不传 --voice 时按文本自动挑自然男声：中文 `zh-CN-YunxiNeural` / 英文 `en-US-AndrewNeural`）：
   - 默认 `npm run synthesize-audio`（minimax，中文音色稳，收费）；
   - **免费免 key**：`PRESENTATION_TTS=edge-tts npm run synthesize-audio`
     （先 `pip install edge-tts`；音色按语言自动挑自然男声 —— 中文 `zh-CN-YunxiNeural` / 英文 `en-US-AndrewNeural`，换音色才加 `-- --voice=…`）；
   - 内置 openai：`PRESENTATION_TTS=openai npm run synthesize-audio`（需 `OPENAI_API_KEY`）；
   - 其它后端（ElevenLabs / Azure / Google / macOS say）按 tts-providers/README.md 加一个 `.sh`。
4. 报告：输出位置 `public/audio/<id>/<step>.mp3`、总段数、时长异常段
   （太长 = 该 step 拆分；太短 = 文案太薄），给最后一次校准节奏的机会。

下一步：`/video-maker:record`（有音频 → Auto 一镜到底）。

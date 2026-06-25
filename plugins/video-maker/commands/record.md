---
description: 录屏 + 后期 — 按是否已合成音频，给 Auto 一镜到底 / Manual 手动录的路径并起 dev server
argument-hint: ''
allowed-tools: Bash, Read
---

你在执行 video-maker 的 **Phase 4 录屏 + 后期**。
必读：`${CLAUDE_PLUGIN_ROOT}/skills/web-video-presentation/references/RECORDING.md`。

1. 探测 `presentation/public/audio/` 有没有合成音频。
2. 按情况给用户**三条路径**（从省事到费事）：
   - **① 一键出片（有音频时首推）**：`cd presentation && npm run record-video` → 无人值守
     直接出 `output/video.mp4`（无头驱动 `?capture=1`、音轨离线拼回、ffmpeg 合成，
     音画天然同步，**不用手动录屏 / 不用后期对轨**）。要 ffmpeg + ffprobe。
     这步等价于 `/video-maker:capture` —— 细节走那个命令。
   - **② Auto 一镜到底（想自己掌控录制时）**：`npm run dev` → 浏览器开 `localhost:5174/?auto=1`
     → 按 SPACE → 整片自动播完 → 自己用屏幕录制软件录 → 裁头尾即成片。按 M 切三种模式。
     **`?auto=1` 每次刷新都从头开始** —— 录废了刷新再按 SPACE 重来。
   - **③ Manual（没合成音频时）**：开 `localhost:5174` 点击 / 方向键推进，后期任意剪辑工具配音。
3. 给录屏工具 + 后期建议（见 RECORDING.md）。

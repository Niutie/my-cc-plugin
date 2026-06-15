---
description: 录屏 + 后期 — 按是否已合成音频，给 Auto 一镜到底 / Manual 手动录的路径并起 dev server
argument-hint: ''
allowed-tools: Bash, Read
---

你在执行 video-maker 的 **Phase 4 录屏 + 后期**。
必读：`${CLAUDE_PLUGIN_ROOT}/skills/web-video-presentation/references/RECORDING.md`。

1. 探测 `presentation/public/audio/` 有没有合成音频。
2. 起服务（`cd presentation && npm run dev`），按情况告诉用户：
   - **有音频 → Auto 一镜到底**：浏览器开 `localhost:5173/?auto=1` → 按 SPACE → 整片自动播完 →
     停录 → 裁头尾即成片（音视频天然同步，**无需后期对轨**）。按 M 可切三种模式。
     **`?auto=1` 每次刷新都从头（第 1 章第 1 步）开始** —— 录废了刷新页面再按 SPACE 重来即可。
   - **无音频 → Manual**：开 `localhost:5173` 点击 / 方向键推进，后期用任意剪辑工具配音。
3. 给录屏工具 + 后期建议（见 RECORDING.md）。

---
description: 列出 / 推荐 video-maker 的 23 套内置主题（含 bestFor 适配场景）
argument-hint: ''
allowed-tools: Bash, Read
---

读全部 `${CLAUDE_PLUGIN_ROOT}/skills/web-video-presentation/themes/*/theme.json`
（**动态读，不要硬编码清单**），列出每套：`id` / `nameZh` / `mood` / `bestFor` / `descriptionZh`。

若当前目录已有 `./script.md` 或 `./outline.md`，按内容主动推荐 2~3 套最匹配的（命中 `bestFor`）。
想了解主题 token 体系或自创主题 → 指向
`${CLAUDE_PLUGIN_ROOT}/skills/web-video-presentation/references/THEMES.md`。

选定后用 `/video-maker:scaffold --theme=<id>`。

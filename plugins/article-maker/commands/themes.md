---
description: 列出 / 推荐 article-maker 的内置主题（每套是一份给 AI 读的 Markdown authoring profile，非 CSS）
argument-hint: ''
allowed-tools: Bash, Read
---

读 `${CLAUDE_PLUGIN_ROOT}/skills/article-maker/theme-profiles/index.json`
（**动态读，不要硬编码清单**），列出每套主题的 `id` / `label` / `mood`。也可以直接跑：

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/article-maker/scripts/scaffold.sh" --list-themes
```

每套主题是一份**给 AI 写作时读的 authoring profile**（`theme-profiles/<id>.md`），不是 CSS 文件——
CSS token 由组件库提供，profile 告诉 Agent 在该主题下怎么写、怎么排版。

若当前工作区已有 `plan/plan.md` 或 `source/source.md`，按内容主动推荐 1~2 套最匹配的主题并写一句理由
（技术 / 证据优先 `tufte`，叙事 / 评论优先 `press`）。主题选择规则、density 与 theme 解耦见
`${CLAUDE_PLUGIN_ROOT}/skills/article-maker/references/theme-selection.md`。

选定后用 `/article-maker:scaffold --theme=<id>` 建工作区。

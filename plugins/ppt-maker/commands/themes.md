---
description: 列出 / 推荐 24 套主题
argument-hint: '[题材关键词，用于推荐]'
allowed-tools: Bash, Read
---

参数：$ARGUMENTS

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/ppt-maker/scripts/scaffold.sh --list-themes
```

读所有 `themes/*/theme.json` 的 `nameZh` / `descriptionZh` / `bestFor` / `preview`，
**不要硬编码清单**。按用户内容的题材和语气主动推荐 2~3 套，说明命中了哪条
`bestFor`。

每套主题的图表配色都已生成并通过 CVD 与对比度校验；新造主题后必须跑
`scripts/gen-chart-palettes.mjs`，否则图表用的是未经校验的兜底色。

下一步：/ppt-maker:scaffold --theme=<选定 id>

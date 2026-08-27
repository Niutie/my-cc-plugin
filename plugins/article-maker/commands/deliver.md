---
description: Delivery — 停在 Checkpoint 3 确认交付决策，再构建自包含 article.html（可选 zero-npm 无头 HTML → PDF）+ 简短编辑说明
argument-hint: '[--pdf=yes|no]'
allowed-tools: Bash, Read, Edit, Write, AskUserQuestion
---

你在执行 article-maker 的 **Checkpoint 3（★交付确认）+ Phase 8 Delivery**。前置：终审已完成、修复已改完
（没有 → 先 `/article-maker:review`）。命令见 `${CLAUDE_PLUGIN_ROOT}/skills/article-maker/references/html-output.md`
（PDF 见 `references/pdf-output.md`）。

步骤：

1. **Checkpoint 3 · 必须停**：用 AskUserQuestion 问**交付决策**（无工具则编号列出、停下等答复）——
   选项：`通过 · 导出 HTML 交付` / `通过 · 同时导出 HTML + PDF` / `还有局部修复 · 我会列出具体修哪里` /
   `先停一停 · 我要再看看`。**不要静默走默认导出 HTML**。`--pdf=yes|no` 给了就当该决策已确认、直接采纳并说明。
2. 构建主交付物：`npm run html` → `article/article.html`（自包含单页，CSS + JS 内联，断网可打开）。
   （注：`npm run build` 只产出 `dist/index.html`；`npm run html` 会在 build 之后把它复制成交付物 `article/article.html`。）
3. **仅当**用户选了"HTML + PDF"：
   `bash "${CLAUDE_PLUGIN_ROOT}/skills/article-maker/scripts/html-to-pdf.sh"`
   （探测系统 chromium-family 浏览器，注入 `@media print` 覆盖，headless 打印，零 npm 依赖）
   → `article/article.pdf`。不选则不动。
4. 给一段**简短编辑说明**：文章类型 / 信息保留比例 / 主题 / 配图策略 / 主要编辑取舍。

> Colophon（`article/Article.tsx` 末尾的 `Made with article-maker · <主题> theme`）与封面外壳是契约的一部分，
> 交付前确认仍在、未被删除 / 移位。

---
description: Source → Markdown — 把 URL / PDF / DOCX / MD / 文本 / 截图 抽取成 source/source.md，主 Agent 内联 5 条自检（仅复杂 / 低置信源升级 SubAgent）
argument-hint: '[素材路径 | URL | 直接粘贴内容] [--lang=<目标语言>]'
allowed-tools: Bash, Read, Edit, Write, Task, WebFetch
---

你在执行 article-maker 的 **Phase 1 Source → Markdown**。bundled skill 的方法论在
`${CLAUDE_PLUGIN_ROOT}/skills/article-maker/`。

输入：$ARGUMENTS
（没给就用当前对话里用户提供的素材；都没有 → 按 SKILL.md Phase 0 **反问**索取素材或大纲，
不要替用户凭空构思内容。明显是要应用 / dashboard / 工具 → 停下澄清，不要进入本流程。）

步骤：

1. 先读 `${CLAUDE_PLUGIN_ROOT}/skills/article-maker/references/source-to-markdown.md`。
2. 识别输入类型（URL / PDF / DOCX / Markdown / 纯文本 / 截图 / 粘贴材料）。复杂 PDF / DOCX / HTML
   走 MarkItDown 主路径 `scripts/source-to-markdown-markitdown.py`；简单 Markdown / TXT / HTML
   或 MarkItDown 不可用时走轻量 fallback `scripts/source-to-markdown.py`。
3. 在工作区 `source/` 下产出 `source.md`，不确定项写进 `source/extraction-notes.md`
   （工作区在 Phase 4 才脚手架；此处先建目标目录的 `source/` 占位，scaffold 后续接管同一目录）。
4. **语言处理**：`--lang` 给了或用户在前文指定了目标语言、且与源语言不一致 → 先产出**地道翻译版**
   `source/source.<lang>.md`（去翻译腔，术语 / 数字 / 代码 / 公式 / 引用保持准确），作为后续事实底座，
   原文 `source.md` 保留备查；未指定或与源一致 → 不翻译，最终文章语言 = 源语言。翻译说明写进
   `extraction-notes.md`。
5. **主 Agent 内联**走 `source-to-markdown.md` 的 5 条 checklist 自查，按 fail 项改完再汇报。
   **仅当** `extraction-notes.md` 标记低置信 / 复杂源，才升级 Source Reviewer SubAgent 对照
   `original.*` 做 diff，写 `review/source-review.md`。

下一步：`/article-maker:plan` 出 plan.md（Phase 2 + Checkpoint 1）。

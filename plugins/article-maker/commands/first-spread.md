---
description: First Spread — 做封面（若开）+ 首屏 + 第一个独立 Section + 一个代表性视觉块，过 First Spread Reviewer，停在 Checkpoint 2 验收 + 选开发模式
argument-hint: ''
allowed-tools: Bash, Read, Edit, Write, Task, AskUserQuestion
---

你在执行 article-maker 的 **Phase 4 First Spread（文章版"第一章验收"）+ Checkpoint 2（★硬节点）**。
前置：工作区已脚手架（没有 → 先 `/article-maker:scaffold --theme=<id>`）。

开工前先读：`${CLAUDE_PLUGIN_ROOT}/skills/article-maker/references/section-build.md` ·
`references/component-policy.md` · `references/raw-policy.md` · 选定主题 `theme-profiles/<id>.md` ·
封面 `references/cover.md`。

步骤：

1. 首屏（Hero / Lead）写进 assembler `article/Article.tsx`；**第一个 Section 必须写成独立组件**
   `article/sections/01-*.tsx`（这是后续并行的代码锚点，铁律：一节一文件）。
2. 封面（若开）：把 `article/Cover.tsx` 里的 `<CoverPlaceholder />` 替换为按**主题 + 文章主旨**定制的
   图文构图。**外壳（3:4 容器 + 打印分页）不要动**，只用 `--ra-*` token，不要远程图片，不要重复 Hero。
3. `npm run dev` 预览。它决定标题气质 / 字号 / 内容密度 / Raw 风格 / 配图方式 / 主题是否合适。
4. 第一个 Section 完成后，按硬性质检协议起 **First Spread Reviewer SubAgent**，写
   `review/first-spread-review.md`（**含封面 5 条自检**，见 `cover.md`）；**先按 fail 项改完**再继续。
   探测不到 SubAgent 环境才由主 Agent 兜底，并在文件首注明。
5. 进入 **Checkpoint 2**：先发简短消息（dev 预览地址 + 质检已改完列出修了啥），**然后**用
   AskUserQuestion 传 **2 个独立 question**：① 验收结论（通过 / 局部改 / 回 Checkpoint 1）
   ② 后续开发模式（**A 单 Agent 顺序 · 默认最稳** / **B 多 Agent 并行 · 最快**）。

**铁律 · 禁止打包**：不要把两件事并成"通过 + A，OK 吗"——用户可能"通过但想用 B"或反之。
两题都收齐答复才能继续。

下一步：`/article-maker:build --mode=A|B` 生成完整文章。

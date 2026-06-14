---
description: 脚手架 — 用选定主题跑 scaffold.sh 建 Vite+React+TS 项目，并删掉自带的 example 章
argument-hint: '--theme=<主题id> [目标目录，默认 ./presentation]'
allowed-tools: Bash, Read, Edit, Write
---

你在执行 video-maker 的 **Phase 2.1 脚手架**。

参数：$ARGUMENTS
（解析 `--theme=<id>` 和可选目标目录；没给 theme 就读 `presentation/.theme` 或问用户 ——
**主题必须明确**才能脚手架。想看有哪些主题用 `/video-maker:themes`。）

步骤：

1. 跑：
   `bash "${CLAUDE_PLUGIN_ROOT}/skills/web-video-presentation/scripts/scaffold.sh" <目标目录|./presentation> --theme=<id>`
   （脚本自带 `npm create vite` + 装依赖 + 拷模板 + typecheck。）
2. 按 SKILL.md 2.1 删掉 `presentation/src/chapters/01-example`，并从
   `presentation/src/registry/chapters.ts` 移除 `EXAMPLE_CHAPTER` 的 import 和数组项。
3. 报告：项目目录、所用主题、`cd <dir> && npm run dev` 怎么起。

下一步：`/video-maker:chapter 1` 做第 1 章（主线程完整样板 + 强制验收）。

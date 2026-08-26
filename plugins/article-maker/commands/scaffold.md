---
description: 脚手架 — 用选定主题跑 scaffold.sh 建 Vite + React + TS 工作区（装最新 reacticle + 记忆目录 + assembler + 示例 section + 默认封面）
argument-hint: '--theme=<主题id> [目标目录，默认 ./article] [--no-cover] [--accent=<hex>]'
allowed-tools: Bash, Read, Edit, Write
---

你在执行 article-maker 的 **Phase 4 脚手架**（First Spread 的前置）。

参数：$ARGUMENTS
（解析 `--theme=<id>`、可选目标目录、可选 `--no-cover`；**主题必须明确**才能脚手架——
来自 Checkpoint 1 的确认结果。想看有哪些主题用 `/article-maker:themes`。Checkpoint 1 选了"封面 · 关"
就带 `--no-cover`。）

步骤：

1. 跑：
   `bash "${CLAUDE_PLUGIN_ROOT}/skills/article-maker/scripts/scaffold.sh" <目标目录|./article> --theme=<id> [--no-cover] [--accent=<hex>]`
   （脚本创建工作区 + 从 npm 装**最新发布版 reacticle** + 写入 runtime theme + 建 `source/ plan/ review/`
   记忆目录 + assembler `article/Article.tsx` + 示例 `article/sections/01-opening.tsx` + 默认
   `article/Cover.tsx`，并跑一次 typecheck。详见 `${CLAUDE_PLUGIN_ROOT}/skills/article-maker/references/scaffold.md`。）
   - **`--accent=<hex>`（可选）**：把主题强调色（accent + info）换成该色，写进 `article/theme-overrides.css`
     （强 / 浅变体自动派生，risk / warn 警示红不变）。培训模版与 video-maker `training-center` 视频对齐 royal 蓝：
     `--theme=vignelli --accent="#2b3f9e"`。
2. 如果之前已在别处产出了 `source/source.md`、`plan/plan.md`，把它们放进这个工作区对应目录（scaffold
   只 seed 空目录，不会覆盖你的已有内容）。
3. 报告：工作区目录、所用主题、实际安装的 reacticle 版本、`cd <dir> && npm run dev` 怎么起。

下一步：`/article-maker:first-spread` 做首屏 + 第一节 + 一个代表性视觉块（含封面），并走 Checkpoint 2 验收。

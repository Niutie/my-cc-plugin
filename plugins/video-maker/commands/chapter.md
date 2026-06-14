---
description: 实现单章 — 按 CHAPTER-CRAFT 做一章完整版（第 1 章做完必须停下验收），完工自检 + 必要时 bump STORAGE_KEY
argument-hint: '<章号或章 id，如 1 或 02-intro>'
allowed-tools: Bash, Read, Edit, Write, Task
---

你在执行 video-maker 的 **Phase 2.4 实现单章**。目标章节：$ARGUMENTS

**每章单一必读入口**：`${CLAUDE_PLUGIN_ROOT}/skills/web-video-presentation/references/CHAPTER-CRAFT.md`
（Part 0 十条原则 / Part 1 开工 5 问 / Part 2 关系→动作决策树 / Part 3 视觉工具箱 /
Part 4 时长 / Part 5 反 AI 味 / Part 6 代码硬规则含 narrations.ts 约束 / Part 7 完工自检 /
Part 8 反馈速查）。

同时读：当前主题 `${CLAUDE_PLUGIN_ROOT}/skills/web-video-presentation/themes/<id>/theme.json`（id 看 `presentation/.theme`）、本章在 `./outline.md`
的段落（含信息池）、`./article.md` 本章对应段落、outline 末尾素材清单。

步骤：

1. 按 CHAPTER-CRAFT 实现 `presentation/src/chapters/<NN>-<id>/`：`<Chapter>.tsx` + `.css` +
   **必须有 `narrations.ts`**（数组长度 = step 数 = 音频/Auto 的唯一真相源；最大 `step===N` 的
   N+1 必须等于 `narrations.length`）。在 `presentation/src/registry/chapters.ts` 注册。
2. 跑 `npx tsc --noEmit`。若动了 `chapters.ts` 结构（增删/重排章）或某章 narrations 长度变化 →
   按 2.5 bump `presentation/src/hooks/useStepper.ts` 的 `STORAGE_KEY`。
3. 完工自检（CHAPTER-CRAFT Part 7，优先 Agent Teams → subagent → 自检），**按 fail 改完再汇报**。
4. **若这是第 1 章：做完必须停下来等用户验收**（SKILL.md 2.2 验收清单：视觉气质 / 节奏 /
   内容驱动动画 / 双源细节 / 反 AI 味），**不可跳过**。验收提示里要带上**怎么预览节奏**
   （Manual 逐步看；M→M→SPACE 切 AUTO 用字数估算节奏通播一遍），并 **offer 一个可选的
   第 1 章音频 demo**（用户想要才做：`npm run extract-narrations` +
   `PRESENTATION_TTS=edge-tts npm run synthesize-audio`，此时天然只合第 1 章、Phase 3
   增量复用 —— 完整说明见 SKILL.md 2.2）。其余章做完正常汇报，提示继续。

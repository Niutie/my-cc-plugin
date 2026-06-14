---
description: 编排第 2~N 章 — 按开发模式 A 逐章 / B 顺序 / C 并行(subagent) 把剩余章节做完
argument-hint: '--mode=A|B|C [--parallel=N（仅 C）]'
allowed-tools: Bash, Read, Edit, Write, Task
---

你在执行 video-maker 的 **Phase 2.3 第 2~N 章编排**。参数：$ARGUMENTS

前置：第 1 章必须已主线程做完并通过验收（强制 anchor）。从
`presentation/src/registry/chapters.ts` + `./outline.md` 算出尚未实现的章节列表。

每章都遵循 `/video-maker:chapter` 的同一套要求（CHAPTER-CRAFT 单一入口 + 必有 narrations.ts +
完工自检）。按 `--mode`（没给就用 SKILL.md 默认 **A**）：

- **A 逐章**：做一章 → 停下验收 → 下一章。风险最低、节奏最稳。
- **B 顺序**：主线程顺序做完第 2~N 章，最后统一验收。
- **C 并行**：用 subagent 并行，每次并行数 = `--parallel`（没给就问用户「一次几章」）。
  每个 subagent 的 prompt **必带**：本章 outline 段落 + 信息池、
  `${CLAUDE_PLUGIN_ROOT}/skills/web-video-presentation/references/CHAPTER-CRAFT.md` 路径、
  当前主题 `theme.json` 的 `descriptionZh`/`mood`/`bestFor`（仅参考气质）、第 1 章代码作"代码风格"
  参考（非视觉抄袭）、硬规则（每章独立 CSS 前缀 / 不互改 `chapters.ts` 造冲突 / 完工
  `npx tsc --noEmit`）。风格各章有差异是预期（主题 token 兜底统一）。

全部做完后按 2.5 bump `STORAGE_KEY`。Phase 2 到此结束 → 进入 **Checkpoint Audio（硬节点，必须停）**：
**停下**问用户要不要合成音频 —— 要 → `/video-maker:audio`;不要 → 跳过音频直接 `/video-maker:record`。
不要静默往下走。用户随时可中途切换开发模式。

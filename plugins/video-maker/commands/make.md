---
description: 一键自动化 — 端到端串起 plan→scaffold→chapters→audio→record，保留 3 个硬节点（可用参数预答减少停顿）
argument-hint: '[article 路径] [--lang=zh|en] [--theme=<id>] [--mode=A|B|C] [--audio=yes|no] [--assets=placeholder|mine] [--yolo]'
allowed-tools: Bash, Read, Edit, Write, Task, AskUserQuestion
---

你在执行 video-maker 的**一键自动化编排**。参数：$ARGUMENTS
全流程方法论见 `${CLAUDE_PLUGIN_ROOT}/skills/web-video-presentation/SKILL.md`。

**总原则**：自动往前推，但 3 个硬节点不能静默跳过。参数预答只是把「停下等开放式输入」变成
「直接采纳 + 告知选择」，**不是取消质量门**。开跑前先探测现有产物
（`./script.md` / `./outline.md` / `presentation/.theme` / `chapters.ts` / `narrations.ts` /
`audio-segments.json`）决定从哪个 phase **续跑**，不要重头来。每个产物完成后照常走「硬性自检协议」。

编排（每步等价于对应拆分命令，复用同一套自检 / CHAPTER-CRAFT 要求）：

1. **Phase 1 = `/video-maker:plan`**：**先定成片语言**（SKILL.md 1.1.5）→ 产出 script.md + outline.md + 自检 → 打印 Checkpoint Plan（带成片语言 + 5 件事）。
   - 成片语言：`--lang=zh|en` 给了就直接用；没给 → 默认跟随原文，并用一句话确认（给反悔机会）。语言决定 script/narration/TTS 音色，**必须在产出 script.md 前定**。
   - `--theme` / `--mode` / `--assets` 给了就直接采纳并**说明选择**；任一没给 → **停下**让用户对齐（硬节点）。
2. **Phase 2.1 = `/video-maker:scaffold`**：用选定主题脚手架 + 删 example 章。
3. **Phase 2.2 = `/video-maker:chapter 1`**：做第 1 章完整样板 → **停下验收**（硬节点，除非显式 `--yolo`）。
4. **Phase 2.3 = `/video-maker:chapters --mode=…`**：按模式做完第 2~N 章。
5. **Checkpoint Audio**：`--audio=yes` → 跑 `/video-maker:audio`；`--audio=no` → 跳过；
   都没给 → **停下**问（硬节点）。
6. **Phase 4 = `/video-maker:record`**：按有无音频给录屏路径。

`--yolo` 仅跳过第 1 章验收（其余硬节点若已用参数预答则自然不停），是逃生口、默认不用。

---
description: 内容编写 — 把文章/口播稿产出成 script.md + outline.md（各自走自检），停在 Checkpoint Plan 让你一次对齐 5 件事
argument-hint: '[article 文件路径 | 直接粘贴/描述内容] [--lang=zh|en]'
allowed-tools: Bash, Read, Edit, Write, Task, AskUserQuestion
---

你在执行 video-maker 的 **Phase 1 内容编写**。bundled skill 的方法论在
`${CLAUDE_PLUGIN_ROOT}/skills/web-video-presentation/`。

输入：$ARGUMENTS
（没给路径就用当前对话里用户提供的文章/口播稿；都没有 → 按 SKILL.md 1.1 的「啥都没有」分支
**反问**，不要替用户编内容。）

步骤：

1. 先读（全部在 skill 根 `${CLAUDE_PLUGIN_ROOT}/skills/web-video-presentation/` 下）：
   - `${CLAUDE_PLUGIN_ROOT}/skills/web-video-presentation/SKILL.md` 的「Phase 1」节
   - `${CLAUDE_PLUGIN_ROOT}/skills/web-video-presentation/references/SCRIPT-STYLE.md`
   - `${CLAUDE_PLUGIN_ROOT}/skills/web-video-presentation/references/OUTLINE-FORMAT.md`
2. 识别输入类型（原始文章 / 现成口播稿 / 无）。**默认按培训中心体裁**
   （结构驱动，L0–L3，SKILL.md 1.1.6）；只有用户明确要解说 / 娱乐向才切，切了要说明。
3. **产出 script.md 前必须确认成片语言**（SKILL.md 1.1.5）：`--lang=zh|en` 给了就当已确认直接用；
   没给 → **无论原文中 / 英都把「中文 / 英文」作为明确选择问出来**（判定原文语言只用于给提示，不预设答案），
   例如「这篇原文是中文，成片你要中文还是英文？」。用户选跨语言（如中文文章做英文片）→ 按目标语言写 script/narration。
4. 按确认的语言 **一次产出** `./script.md` + `./outline.md`；
   用户给了原文就落盘 `./article.md` 并保留（双源原则，开发阶段画面信息源）。
5. 对 `script.md` / `outline.md` 分别走 SKILL.md 的「硬性自检协议」
   （优先 Agent Teams → subagent → 自检），**按 fail 项改完再汇报**。
6. 读全部 `${CLAUDE_PLUGIN_ROOT}/skills/web-video-presentation/themes/*/theme.json`
   （动态读，不要硬编码），按 script 内容主动推荐 2~3 套最匹配的（命中 `bestFor`）。
7. 输出 SKILL.md「Checkpoint Plan」的对齐总结：**先带出已确认的成片语言**，
   再让用户一次对齐 5 件事 —— 稿子 / outline / 主题推荐 / 素材清单 /
   开发模式（A 逐章 · B 顺序 · C 并行），然后**停下**。

**这是硬节点 —— 不要自动往 Phase 2 走。** 用户确认后用
`/video-maker:scaffold --theme=<id>` 继续，或用 `/video-maker:make` 一键串联。

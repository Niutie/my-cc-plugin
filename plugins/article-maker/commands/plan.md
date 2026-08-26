---
description: Editorial Planning — 产出单一 plan.md（Brief / Outline / Theme / Assets），主 Agent 内联自查，停在 Checkpoint 1 让你逐项确认 5 件事
argument-hint: '[--type=<文章类型>] [--theme=<id>] [--width=narrow|regular|wide|full] [--images=none|user-assets|placeholders|ai-generated] [--cover=on|off]'
allowed-tools: Bash, Read, Edit, Write, AskUserQuestion
---

你在执行 article-maker 的 **Phase 2 Editorial Planning + Phase 3 Plan Checkpoint（★Checkpoint 1）**。
方法论在 `${CLAUDE_PLUGIN_ROOT}/skills/article-maker/`。前置：`source/source.md` 应已就绪
（没有 → 先 `/article-maker:source`）。

步骤：

1. 先读（全在 skill 根下）：`references/article-types.md` · `references/information-density.md` ·
   `references/plan-template.md` · `references/theme-selection.md` · `references/layout.md` ·
   `references/asset-policy.md` · `references/cover.md`；选定类型后再查 `references/article-types/<type>.md`。
2. **只产出一份** `plan/plan.md`，四段：**Brief / Outline / Theme / Assets**（模板见 `plan-template.md`），
   **不写 HTML**。文章类型自带标配信息保留比例（longform ~100% … visual-essay ~40%）。
3. **自检方式 · 强约束**：写完 plan.md 后由**主 Agent 内联**对照 `references/review-checklist.md` 的
   Plan 自查段（5 条）核查，按结论改完 `plan/plan.md`——**禁止开 SubAgent，禁止写 review 文件**。
4. 读 `theme-profiles/index.json` + 候选 `<id>.md`，按 source 内容主动推荐一个主题并写一句理由。
5. 进入 **Checkpoint 1**：先发 SKILL.md「Plan Checkpoint 开场消息模板」那条简短说明（带上你的推荐，
   声明默认项可推翻），**然后立刻**用 AskUserQuestion 传 **5 个独立 question** 逐项确认 ——
   **① 文章类型（含标配保留比例）② 主题 ③ 版式宽度 ④ 配图模式 ⑤ 封面开 / 关**。

**铁律 · 禁止静默替用户选择**：可以推荐（"我推荐 X，因为…"），**不能**打包成"全选我推荐的 / 全部 OK 吗"
yes/no，也不能"已经替你定了 X，不对再说"。`--type/--theme/--width/--images/--cover` 给了就当该项已确认、
直接采纳并**说明选择**；没给的项仍要独立问。信息保留比例如要偏离类型标配，让用户在自由文本里写一句
覆盖（如"longform 但只要 60%"），收到后记进 `plan/plan.md` Brief 段。

**这是硬节点 —— 5 项全部收齐答复才能继续。** 确认后用
`/article-maker:scaffold --theme=<id>`（封面关加 `--no-cover`）建工作区。

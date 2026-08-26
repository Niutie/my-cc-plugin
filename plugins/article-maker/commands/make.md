---
description: 一键编排 — 端到端串起 source→plan→scaffold→first-spread→build→review→deliver，保留 3 个硬 Checkpoint（可用参数预答减少停顿）
argument-hint: '[素材路径 | URL] [--lang=<语言>] [--type=<类型>] [--theme=<id>] [--accent=<hex>] [--width=…] [--images=…] [--cover=on|off] [--mode=A|B] [--pdf=yes|no] [--yolo]'
allowed-tools: Bash, Read, Edit, Write, Task, AskUserQuestion, WebFetch
---

你在执行 article-maker 的**一键编排**。参数：$ARGUMENTS
全流程方法论见 `${CLAUDE_PLUGIN_ROOT}/skills/article-maker/SKILL.md`。

**总原则**：自动往前推，但 **3 个硬 Checkpoint 不能静默跳过**。参数预答只是把「停下等开放式输入」变成
「直接采纳 + 告知选择」，**不是取消质量门 / 决策确认**。开跑前先探测现有产物
（`source/source.md` · `plan/plan.md` · 工作区是否已脚手架 · `article/sections/*` · `review/*`）决定从哪个
Phase **续跑**，不要重头来。每个产物完成后照常走「硬性质检协议」。

编排（每步等价于对应拆分命令，复用同一套自检与铁律）：

1. **Phase 1 = `/article-maker:source`**：抽取 → `source/source.md` + 5 条内联自检。
   `--lang` 给了且与源不一致 → 先产出地道翻译版底座。素材都没有 → **停下反问**，不替用户编内容。
2. **Phase 2 + Checkpoint 1 = `/article-maker:plan`**：出 `plan/plan.md`（Brief/Outline/Theme/Assets）+ 内联自查
   → **★Checkpoint 1 逐项确认 5 件事**（类型 / 主题 / 版式 / 配图 / 封面）。`--type/--theme/--width/--images/--cover`
   给了就该项直接采纳并说明；任一没给 → **停下**逐项问（硬节点）。
3. **Phase 4 脚手架 = `/article-maker:scaffold`**：用选定主题（+ 封面开关）建工作区。
   `--accent=<hex>` 给了就把强调色换成该色（培训模版对齐 video-maker `training-center` royal 蓝：
   `--theme=vignelli --accent="#2b3f9e"`）。
4. **Phase 4 First Spread + Checkpoint 2 = `/article-maker:first-spread`**：做封面 + 首屏 + 第一节 + 代表性视觉块
   → First Spread Reviewer 改完 → **★Checkpoint 2 验收 + 选开发模式**（除非显式 `--yolo` 跳过验收）。
   `--mode` 给了就采纳；没给且非 yolo → **停下**问。
5. **Phase 5 = `/article-maker:build --mode=…`**：按模式 A/B 生成完整文章，每节过 Section Reviewer（消息返回，不写文件）。
6. **Phase 6 + 7 = `/article-maker:review`**：三视角终审写 `review/final-review.md` + 最小切片修复。
7. **Checkpoint 3 + Phase 8 = `/article-maker:deliver`**：**★Checkpoint 3 确认交付决策** → 构建 `article/article.html`，
   `--pdf=yes` 再导 `article/article.pdf`；`--pdf` 没给 → **停下**问（硬节点）。

`--yolo` 仅跳过 Checkpoint 2 的首屏验收（其余硬节点若已用参数预答则自然不停），是逃生口、默认不用。
**禁止静默替用户选择**：可推荐，不可打包成"全部 OK 吗"yes/no，不可"已替你定了 X 不对再说"。

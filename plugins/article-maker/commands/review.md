---
description: Final Review + Repair — Editorial / Visual / Technical 三视角终审（写 review/final-review.md）+ Phase 7 最小切片修复
argument-hint: ''
allowed-tools: Bash, Read, Edit, Write, Task
---

你在执行 article-maker 的 **Phase 6 Final Review + Phase 7 Repair**。前置：完整文章已生成
（没有 → 先 `/article-maker:build`）。读 `${CLAUDE_PLUGIN_ROOT}/skills/article-maker/references/review-checklist.md`
+ `references/repair-policy.md`。

步骤：

1. 起三个 Reviewer SubAgent（无 Teams 时至少一个独立 SubAgent；探测不到 SubAgent 环境才主 Agent 兜底并注明）：
   - **Editorial Reviewer**：文章性、信息取舍、结构。
   - **Visual Reviewer**：主题、Raw、配图、移动端。
   - **Technical Reviewer**：构建（`npm run build`）、控制台、代码 / 公式、可访问性。
2. 汇总写 `review/final-review.md` + 修复列表。核心红线：它仍是一篇**文章**（不是应用）· 信息保留比例符合 Plan ·
   必须保留的信息没丢 · 主题气质统一 · Raw 无野生样式 · 没有明显 AI 味 · 桌面 + 移动端可读 · HTML 可构建可打开可分享。
3. **Phase 7 修复 · 最小切片**：按最小单位修复（见 `repair-policy.md`）。**禁止**：只反馈一处就重写整篇 /
   为修视觉改动已确认的文章结构 / 为压缩信息删掉用户指定必须保留的内容。**有修复才写** `review/repair-log.md`
   （一次过 / 无修复则不写）。
4. **先按 fail 项改完**，再汇报"做完了 + 终审结论 + 改了什么"。

下一步：`/article-maker:deliver` —— Checkpoint 3 确认交付决策后构建 article.html（可选 PDF）。

---
description: Full Article Build — 按 Checkpoint 2 选定的模式生成完整文章（A 单 Agent 顺序 / B 多 Agent 并行），每节过 Section Reviewer（消息返回 pass/fail，不写文件）
argument-hint: '[--mode=A|B]'
allowed-tools: Bash, Read, Edit, Write, Task
---

你在执行 article-maker 的 **Phase 5 Full Article Build**。前置：First Spread 已验收、开发模式已选
（没有 → 先 `/article-maker:first-spread`）。参数：$ARGUMENTS（`--mode` 取 Checkpoint 2 的选择；没给则默认 A）。

**每节开工前回看**（长会话易遗忘）：`${CLAUDE_PLUGIN_ROOT}/skills/article-maker/references/section-build.md` ·
`references/component-policy.md` · `references/raw-policy.md` · 当前主题 `theme-profiles/<id>.md`。

铁律：

- **一个 Section = 一个独立组件文件** `article/sections/NN-*.tsx`，**坚决不允许把多个 Section 写进一个文件**。
  大型 Raw 同样隔离到 `article/raw-blocks/NN-*.tsx`。`article/Article.tsx` 只是 **assembler**（import + 排序），
  由**主 Agent 拥有**。文件级隔离是多 Agent 并行的前提。
- **A · 单 Agent 顺序（默认）**：主 Agent 顺序写每个 `sections/NN-*.tsx`，最稳、风格最统一。
- **B · 多 Agent 并行**：subagent 各**拥有一个** section 文件并行开发；**主 Agent 负责合并与稳定性**——
  维护 `Article.tsx` 的 import 与顺序、跑 `npm run typecheck` / `build`、兜底主题与风格一致、解决冲突。
  subagent prompt 模板见 `references/section-build.md`。
- 正文是主体；所有 Raw 用 `--ra-*` 主题 token，禁止野生颜色 / 字体；按 Plan 的信息保留比例写。

每个 Section 完成后**必须**起 **Section Reviewer SubAgent**（是否完成 outline 任务 / 是否符合保留比例 /
是否与前后衔接 / 是否过度组件化 / 是否有足够正文 / Raw 与配图是否有明确目的 / 序号自洽）。
**SubAgent 以消息返回 pass/fail + 修复点，不要写 `review/section-NN-review.md` 文件**；主 Agent 收到 fail
项后**先直接修对应 section 文件**，再汇报本节交付。

下一步：`/article-maker:review` 走三视角终审 + 最小切片修复。

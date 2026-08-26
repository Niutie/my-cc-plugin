# article-maker — 任意素材 → 漂亮的单页 HTML 文章

**一个 Claude Code 插件：把任意素材（网页 URL / PDF / DOCX / Markdown / 纯文本 / 截图 / 粘贴材料）编辑、设计成一篇美丽的、可离线打开和分享的单文件 HTML 网页文章。** 它内置 `article-maker` skill —— 一套以编辑方法论 + 协作流程为核心的设计流程。

[返回集合首页](../../README.md)

---

## 这是什么？

`article-maker` 插件帮 Agent 把枯燥、线性、难以消化的文字材料，重新编辑成视觉体验更漂亮、阅读节奏更清晰、也更容易审阅和分享的网页文章。它**不是** Web App 生成器 —— 关注点始终是**文章**本身：更好的阅读、更好的节奏、更好的审美。成品是一份自包含、断网可开的 HTML 文件（可选配套 PDF），但那只是交付形态，不是目标。

它适合：

- 把长 URL / PDF / DOCX / Markdown 重新打包成漂亮的 HTML 长文
- 产出 briefing、解释文、教程、事故复盘、方案 / 设计审阅
- 视觉文章、对话 / 访谈实录、交互式学习解释文
- 任何你想要一个**比裸 Markdown 更好的阅读媒介**的场景 —— 表格、SVG、代码、公式、复制 / 导出按钮都内建

这个插件的核心是**方法论 + 协作流程**。脚手架基于 [`reacticle`](https://www.npmjs.com/package/reacticle) 组件协议提供 token、语义组件和主题 —— Agent **不手写裸 HTML / CSS**，而是组合 prose-first 的语义组件，加上一个受主题约束的 `Raw` 自由层。

---

## 核心理念

- **先是文章，不是应用** —— 关注点是文章。Raw 自由层、SVG、小工具都必须服务阅读 / 解释 / 节奏 / 审美，不能自成一体。
- **Source → Plan → Build → Review harness** —— 每个项目走一条编号阶段流水线，中间有 3 个硬 Checkpoint。
- **`reacticle` 组件协议** —— 语义 prose 组件（Hero、Lead、Section、Quote、Callout、Image、Formula、CodeBlock、Table…）+ 一个 `Raw` 逃生口，Raw 必须只用主题 token（`--ra-*`）。
- **主题驱动设计** —— 从注册表里选一套 authoring profile（`tufte` / `press` / `bayer` / `bodoni` / `vignelli` / `sottsass` / `freddie` / `andy` / `fuller` / `knuth` / `shannon`）。每套是给 Agent 读的 **Markdown 契约**，不是 CSS 文件。
- **培训 / 赋能模版** —— 做企业培训 / 认证课 / Partner 赋能 / 产品 onboarding 文章时优先 `vignelli`（净白 + 双语无衬线 + 网格 + 高信息密度的机构气质，对标 video-maker 的 `training-center` 视频主题，让「培训视频 + 配套讲义」气质统一）。要与视频对齐 royal 蓝，脚手架加一个参数即可：`--theme=vignelli --accent="#2b3f9e"`（把强调色 accent + info 换蓝、警示红不变、非破坏性，写进 `article/theme-overrides.css`）。
- **默认 100% 信息保留** —— 文章类型自带推荐保留比例（longform `~100%`、briefing `~50%`、visual-essay `~40%`…），用户可一句话覆盖。
- **硬协作 Checkpoint** —— Agent 在「计划」「首屏样张」「最终交付」三处停下；**每个决策都必须逐项确认，绝不静默打包**。
- **默认带封面** —— 一张 3:4 书封式题图位于 TOC 之上，外壳锁定、只用主题 token、不要远程图片。
- **可选 PDF 导出** —— 主交付物是自包含 HTML；PDF 是 opt-in，由一个零 npm 依赖的 `html-to-pdf.sh` 无头浏览器脚本生成。

---

## 工作流

```text
Phase 0  Intake            判断要不要进本流程 + 初步文章类型
   │
Phase 1  Source → Markdown URL / PDF / DOCX / MD / 文本 → source/source.md
   │
Phase 2  Editorial Planning 一份 plan.md（Brief / Outline / Theme / Assets）
   │
★ Checkpoint 1  Plan        逐项确认 5 件事：类型 / 主题 / 版式 / 配图 / 封面
   │
Phase 4  First Spread       封面 + 首屏 + 第一个独立 Section + 一个代表性视觉块
   │
★ Checkpoint 2  First Spread 验收结论 + 开发模式 A / B
   │
Phase 5  Full Article Build 单 Agent 顺序 或 多 Agent 并行（每节一个文件）
   │
Phase 6  Final Review       Editorial / Visual / Technical 三视角终审
   │
Phase 7  Repair             最小切片修复
   │
★ Checkpoint 3  Delivery    导出 HTML / HTML + PDF / 继续修 / 暂停
   │
Phase 8  Delivery           article/article.html（可选 article/article.pdf）
```

这些 Checkpoint 是插件契约的一部分：Agent 不应该从原文一路闷头做到成品。`script` 在每个 Checkpoint 都**逐项独立确认**用户决策 —— 可以推荐，但不能"已经替你定了 X，不对再说"。质检按节点区分：**Plan 内联自查（不开 SubAgent、不写文件）**，**First Spread / Final 用 SubAgent + 写 review 文件**，**Section 用 SubAgent + 消息返回 pass/fail**。

Agent 拥有一个按项目独立的工作区目录，作为它的**长期记忆**：

```text
<workspace>/
  source/   original.*   source.md   source.<lang>.md（翻译时）   extraction-notes.md
  plan/     plan.md
  article/  Cover.tsx   Article.tsx   sections/   raw-blocks/   assets/   article.html（产物）
  review/   first-spread-review.md   final-review.md
            （source-review.md 仅复杂源 · repair-log.md 仅有修复时）
  index.html  package.json  vite.config.ts  tsconfig*.json   （构建工装）
```

---

## 内含内容

```text
article-maker/                           # 插件
├── README.md                            # 本文件（插件文档）
├── .claude-plugin/
│   └── plugin.json                      # 插件清单 —— 自动发现下面这个 skill
├── commands/                            # 9 个斜杠命令（source / plan / … / deliver / make）
└── skills/
    └── article-maker/               # 内置的 skill
        ├── SKILL.md
        ├── manifest.json
        ├── references/
        │   ├── harness.md
        │   ├── source-to-markdown.md
        │   ├── article-types.md  +  article-types/   # 10 种文章类型
        │   ├── information-density.md
        │   ├── plan-template.md
        │   ├── theme-selection.md
        │   ├── layout.md
        │   ├── cover.md
        │   ├── asset-policy.md
        │   ├── component-policy.md
        │   ├── raw-policy.md
        │   ├── section-build.md
        │   ├── html-output.md
        │   ├── pdf-output.md
        │   ├── review-checklist.md
        │   └── repair-policy.md
        ├── theme-profiles/              # 11 套 authoring profile（给 AI 读，非 CSS）
        │   ├── index.json
        │   └── tufte / press / bayer / bodoni / vignelli / sottsass /
        │       freddie / andy / fuller / knuth / shannon
        ├── scripts/
        │   ├── scaffold.sh              # 一键创建文章工作区
        │   ├── html-to-pdf.sh           # 可选 HTML → PDF（无头浏览器，零 npm 依赖）
        │   ├── pdf-print-overrides.css  # 注入到 HTML 的 @media print 覆盖
        │   ├── source-to-markdown-markitdown.py  # 主抽取路径（PDF / DOCX / HTML）
        │   └── source-to-markdown.py    # 轻量 fallback（Markdown / TXT / 简单 HTML）
        └── assets/
            └── scaffold-template/       # 脚手架复制的 Vite + React + TS 模板
```

---

## 快速上手

从 marketplace 安装插件：

```
/plugin marketplace add https://github.com/Niutie/my-cc-plugin.git
/plugin install article-maker@my-cc-plugin
```

启用后，内置的 skill 由**模型自动触发** —— 直接让 Claude「把这篇文章 / 这个 PDF 做成可分享的网页文章」，它会接管 `article-maker:article-maker` 并带你走上面的工作流。

也可以用斜杠命令手动驱动每个阶段（见下）。手动脚手架（插件内部也是跑这个）：

```bash
# 默认开封面
bash "${CLAUDE_PLUGIN_ROOT}/skills/article-maker/scripts/scaffold.sh" ./my-article --theme=tufte

# 封面关
bash "${CLAUDE_PLUGIN_ROOT}/skills/article-maker/scripts/scaffold.sh" ./brief --theme=press --no-cover

# 查看可用主题
bash "${CLAUDE_PLUGIN_ROOT}/skills/article-maker/scripts/scaffold.sh" --list-themes
```

生成的工作区是普通 Vite + React + TypeScript 项目。写完各 Section 后构建出自包含单页 HTML：

```bash
cd my-article
npm run build        # → article/article.html（CSS + JS 内联，断网可打开）
```

可选 PDF 导出（仅当 Checkpoint 3 选了 HTML + PDF）：

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/article-maker/scripts/html-to-pdf.sh"
```

---

## 斜杠命令

9 个命令对应工作流的各阶段，保留 3 个硬 Checkpoint：

| 命令 | 阶段 | 作用 |
|---|---|---|
| `/article-maker:source` | Phase 1 | 把素材抽取成 `source/source.md`，主 Agent 内联 5 条自检 |
| `/article-maker:themes` | Phase 2 | 列出 / 推荐内置主题 authoring profile |
| `/article-maker:plan` | Phase 2 + ★CP1 | 出 `plan/plan.md` + 内联自查 → 逐项确认 5 件事 |
| `/article-maker:scaffold` | Phase 4 | 用选定主题跑 `scaffold.sh` 建工作区 |
| `/article-maker:first-spread` | Phase 4 + ★CP2 | 封面 + 首屏 + 第一节 + 视觉块 → 验收 + 选开发模式 |
| `/article-maker:build` | Phase 5 | 按模式 A / B 生成完整文章，每节过 Section Reviewer |
| `/article-maker:review` | Phase 6 + 7 | 三视角终审 + 最小切片修复 |
| `/article-maker:deliver` | ★CP3 + Phase 8 | 确认交付决策 → 构建 `article.html`（可选 PDF） |
| `/article-maker:make` | 全流程 | 端到端编排，参数可预答以减少停顿 |

---

## Reference Map

- [SKILL.md](./skills/article-maker/SKILL.md)：主 skill —— 工作流、硬性质检协议、各阶段读取指南、默认策略
- [references/harness.md](./skills/article-maker/references/harness.md)：Skill 的 harness 视角、状态文件约定
- [references/source-to-markdown.md](./skills/article-maker/references/source-to-markdown.md)：各类输入 → `source.md` 规则 + 5 条抽取自检 + 脚本用法
- [references/article-types.md](./skills/article-maker/references/article-types.md)：10 种文章类型路由（含逐类型结构 / 组件 / 保留比例）
- [references/information-density.md](./skills/article-maker/references/information-density.md)：信息密度等级与组件 / 视觉比例关系
- [references/plan-template.md](./skills/article-maker/references/plan-template.md)：单一 `plan.md` 模板（Brief / Outline / Theme / Assets）
- [references/theme-selection.md](./skills/article-maker/references/theme-selection.md)：主题选择、density 与 theme 解耦、新增主题约束
- [references/cover.md](./skills/article-maker/references/cover.md)：书封式封面设计指南（5 条自检 + 5 个构图模板 + 各主题封面起手）
- [references/component-policy.md](./skills/article-maker/references/component-policy.md) · [raw-policy.md](./skills/article-maker/references/raw-policy.md)：组件协议 prose-first + Raw 允许 / 禁止 + token 驱动
- [references/section-build.md](./skills/article-maker/references/section-build.md)：一节一文件铁律、单 / 多 Agent 模式、并行 subagent prompt
- [references/review-checklist.md](./skills/article-maker/references/review-checklist.md) · [repair-policy.md](./skills/article-maker/references/repair-policy.md)：各阶段 Reviewer 清单 + 最小切片修复对照表
- [references/html-output.md](./skills/article-maker/references/html-output.md) · [pdf-output.md](./skills/article-maker/references/pdf-output.md)：构建 / 交付命令 + 可选 PDF 导出原理与故障排除
- [theme-profiles/](./skills/article-maker/theme-profiles/)：11 套主题 authoring profile（给 AI 读，非 CSS）

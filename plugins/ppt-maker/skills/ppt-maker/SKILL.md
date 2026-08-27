---
name: ppt-maker
description: 把素材做成可离线打开的网页版 PPT，并导出成真·可编辑的 PPTX。单一 deck.json 事实源 + 12×8 构图 DSL 双渲染（网页 / PowerPoint 坐标精确对齐，机器校验）：18 种图表（7 种导出为原生 PowerPoint 图表带可编辑数据表、11 种导出为矢量形状）、23 个版式骨架（含 SWOT / 波特五力 / PEST / 商业模式画布 / BCG / 双钻 / AARRR / 飞轮）、24 套主题（图表配色逐套通过 CVD 与对比度校验）、浏览器内控制台（改文字 / 拖控件 / 写回 deck.json）。适用：业务复盘、方案汇报、投融资路演、行业研究、竞品分析、项目结项 —— 尤其是「同事要拿去接着改」的场合。
---

# PPT Maker

把素材做成**网页版 PPT**，并导出成**真·可编辑的 PPTX**。

> **skill 根目录**：本文里的 `${CLAUDE_PLUGIN_ROOT}/skills/ppt-maker` 就是
> 本 `SKILL.md` 所在目录。作为 plugin 安装时该变量由 Claude Code 注入；
> 直接拿仓库用时，换成这个目录的实际绝对路径 —— **不要让它展开成空串**，
> 那会得到一个 `/skills/ppt-maker/...` 的错路径且不报错。

## 什么时候用它，什么时候不用

| 需求 | 用 |
|---|---|
| 汇报稿，同事要在 PowerPoint 里接着改 | **ppt-maker** |
| 长文、要读的 | `article-maker` |
| 讲解视频、节拍驱动、要录屏 | `video-maker` |

三者共享同一套 24 主题和 16:9 舞台。ppt-maker 的根本差别：**产物要能落进
PowerPoint**，所以页面不能自由手写，必须落到受约束的 DSL。这是限制，也是
它唯一的存在理由。

## 🔴 三条红线

动手前读 [`references/DECK-DSL.md`](references/DECK-DSL.md)。三条不可越过：

1. **不许夹带自由 HTML / JSX / CSS。** 表达不了就扩 DSL。一旦某页带裸标记，
   PPTX 导出就退化成 DOM walker，整个架构塌掉。
2. **不许出现 `vw` / `vh` / `clamp()` / `em`。** 舞台是固定 1920×1080 整体
   缩放的画布，视口单位在屏幕上二次缩放、在 PowerPoint 里毫无意义。
3. **渲染器不许自己算坐标。** 一律来自 `deck/layout.ts` + `deck/blocks.ts`。

## 工作流

```
Phase 1  素材 → source/source.md              /ppt-maker:source
   ▼
Phase 2  内容规划 → plan.md（含 canonical 文案包）  /ppt-maker:plan
   ▼
[Checkpoint Plan]  ← 硬节点。一次对齐 4 件事：
                     大纲 / 主题 / 图表选型 / 页数
   ▼
Phase 3  脚手架 + 首屏三页                     /ppt-maker:scaffold
   ▼
[Checkpoint First]  ← 硬节点。看真页面验收视觉，再决定铺不铺
   ▼
Phase 4  铺完全部页面                          /ppt-maker:build
   ▼
Phase 5  终审 + 修复                           /ppt-maker:review
   ▼
[Checkpoint Deliver] ← 硬节点。确认交付格式
   ▼
Phase 6  交付 HTML / PPTX / PDF                /ppt-maker:deliver
```

工作目录：

```
my-deck/
├── source/source.md      素材抽取结果（Phase 1）
├── plan.md               大纲 + canonical 文案包（Phase 2）
└── deck/                 脚手架产出
    ├── deck.json         ★ 唯一事实源
    ├── src/              渲染器（一般不用改）
    └── dist/             deck.pptx / deck.pdf
```

## Phase 1 —— 素材 → Markdown

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/skills/ppt-maker/scripts/source-to-markdown.py <file|URL> -o source/source.md
```

抽完自己过一遍：数字有没有丢、表格有没有塌、图注还在不在。**素材里的每个
数字都要保留原值和单位** —— 后面 canonical 文案包要靠它。

用户直接给文字/大纲时跳过本 Phase。

## Phase 2 —— 内容规划（产出 plan.md）

读 [`references/PLANNING.md`](references/PLANNING.md)。核心是写出
**canonical 文案包**：每页一份事实源，所有方案共享。

写完停在 **Checkpoint Plan**，一次问清 4 件事：

```
内容规划写完：
  📄 plan.md   {N} 页 / {M} 个必含事实

页面速览：
  1. <role>  <标题>            <archetype 候选>
  ...

一次对齐 4 件事：
  1. 大纲要不要改？（页序 / 详略 / 有没有该砍的页）
  2. 选哪套主题？我的推荐：
     ★ <推荐 1>（nameZh）—— 因为 <bestFor 命中>
     ★ <推荐 2 / 3>
     完整清单：bash ${CLAUDE_PLUGIN_ROOT}/skills/ppt-maker/scripts/scaffold.sh --list-themes
  3. 图表选型对不对？<列每页打算用什么图，一句话说为什么>
  4. 页数与密度：现在 {N} 页，够不够 / 要不要拆？
```

## Phase 3 —— 脚手架 + 首屏三页

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/ppt-maker/scripts/scaffold.sh ./deck --theme=<id>
cd deck && npm run dev
```

**先只做三页**：封面 + 一页数据页 + 一页结构页。这三页是这套主题下的第一次
落地，主题不够用、容量不够、图表选错都会在这里暴露 —— 此时改成本最低。

做完停在 **Checkpoint First**，给用户截图或让他打开 dev server 看。

## Phase 4 —— 铺完全部页面

读 [`references/ARCHETYPES.md`](references/ARCHETYPES.md) 选骨架、
[`references/CHARTS.md`](references/CHARTS.md) 选图表。

每页的做法：

1. 先写 `content.presentation`（canonical 文案包），**再**挑版式
2. 按容量挑 archetype —— 不是挑好看的再塞字
3. 一页给 3 个 archetype 方案 + 1 个 bespoke 定制方案
4. bespoke 先写 `designIntent` 再画 `composition`，几何必须**看得出**
   它声明的 `compositionFamily`

**反卡片墙**：相邻页不许同一个 composition family；卡片墙不许超过正文页的
三分之一。这两条 `npm run validate` 会查。

## Phase 5 —— 终审

```bash
npm run check     # typecheck + validate + export + verify:geometry
```

四道机器校验全过之后，**还必须渲染截图目检**。读
[`references/ACCEPTANCE.md`](references/ACCEPTANCE.md)：机器校验通过 ≠ 验收
通过，三态结论只有「通过 / 待修正 / 阻塞」。

## Phase 6 —— 交付

```bash
npm run export:pptx                      # dist/deck.pptx（可编辑）
npm run export:pptx -- --mode=comparison # 每页展开全部方案
npm run export:pdf                       # dist/deck.pdf
npm run build                            # dist-web/ 可离线打开的网页版
```

细节与边界见 [`references/EXPORT.md`](references/EXPORT.md)。

## 生成之后：控制台

改稿不必回来找 Agent。`npm run dev` 后按 `C` 开控制台：

- 双击页面文字**就地改**（写回 canonical 内容层，换方案不丢）
- 拖控件调数量 / 换对齐 / 开关模块
- 切方案
- 写回 `deck.json`，下次 `export:pptx` 直接带上

见 [`references/CONSOLE.md`](references/CONSOLE.md)。

## 视觉自检（不可省）

机器校验只保证**位置对**，保证不了**看起来对**。主题配色、字重、装饰层
这类问题 code review 一定看不出来：

```bash
npm run build
(cd dist-web && python3 -m http.server 5399 &)
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless \
  --window-size=1920,1080 --virtual-time-budget=4000 \
  --screenshot=shot.png "http://127.0.0.1:5399/index.html?capture=1&slide=1"
```

开发这套东西的过程里，目检抓到的、review 全部漏掉的缺陷包括：主题发丝网格
被页面背景盖住、标题字重写死无视主题的 200 签名、饼图楔形被三次曲线拉成
花瓣、`--chart-neg` 的 CSS 与 JS 公式不一致、metric 数字不随框宽收缩导致相撞、
**CSS 导入顺序错误让网页用兜底配色而导出器用主题配色**。**这一步不可省。**

三份现成画廊可作视觉回归集：

```bash
cp ${CLAUDE_PLUGIN_ROOT}/skills/ppt-maker/assets/gallery/charts.json     deck.json   # 18 种图表
cp ${CLAUDE_PLUGIN_ROOT}/skills/ppt-maker/assets/gallery/archetypes.json deck.json   # 15 个版式
cp ${CLAUDE_PLUGIN_ROOT}/skills/ppt-maker/assets/gallery/models.json     deck.json   # 8 个分析模型
```

## 相关资源

| 文件 | 何时读 |
|---|---|
| [`references/DECK-DSL.md`](references/DECK-DSL.md) | **动手前必读** —— schema、坐标系、三条红线 |
| [`references/PLANNING.md`](references/PLANNING.md) | Phase 2 —— 怎么写 canonical 文案包 |
| [`references/ARCHETYPES.md`](references/ARCHETYPES.md) | Phase 4 —— 23 个骨架的容量与适用 |
| [`references/CHARTS.md`](references/CHARTS.md) | Phase 4 —— 18 种图表选型 + 配色规则 |
| [`references/ACCEPTANCE.md`](references/ACCEPTANCE.md) | Phase 5 —— 三态验收协议 |
| [`references/CONSOLE.md`](references/CONSOLE.md) | 生成之后改稿 |
| [`references/EXPORT.md`](references/EXPORT.md) | Phase 6 —— 三条出口与各自的边界 |
| [`references/THEMES.md`](references/THEMES.md) | 选 / 造主题 |

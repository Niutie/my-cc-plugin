# ppt-maker

> **1.0 — 生成、编辑、校验、交付全通。**

把素材做成**可离线打开的网页版 PPT**，并导出成**真·可编辑的 PPTX**。

## 为什么再做一个

`video-maker` 做的是"看起来像视频"的网页演示，`article-maker` 做长文。
两者的页面都是 AI 现场手写的 tsx —— 好看，但**没法交给别人在 PowerPoint
里接着改**。汇报场景的刚需恰恰是后者。

要让产物落进 PowerPoint，页面就不能自由手写，必须落到受约束的 DSL。这是
ppt-maker 与另两个 plugin 的根本分野，也是它全部设计的起点。

## 架构

一份 `deck.json`，三个渲染器，**共享同一套几何引擎**：

```
deck.json ──compile──→ Composition ──┬─→ React        网页版 PPT
                                     ├─→ pptxgenjs    可编辑 .pptx
                                     └─→ Playwright   PDF
```

两个关键决定：

1. **archetype 是函数，不是组件。** 它编译出和 bespoke 一模一样的
   `Composition`，所以只有一种东西需要渲染。导出器永远不需要反解 DOM —— 
   这正是同类闭源产品的导出引擎无法开源的原因。
2. **坐标 1:1 可换算。** 舞台 1920×1080 px = PowerPoint 13.333×7.5 in，
   **144 px/inch**；字号 **pt = px / 2**。两边都是精确整除，没有取整策略
   要争论。

## 现状

| 能力 | 状态 |
|---|---|
| deck.json DSL + 12×8 构图 | ✅ |
| React 渲染器 | ✅ |
| pptxgenjs 渲染器（原生图表 + 内嵌数据表） | ✅ |
| 几何一致性机械校验 | ✅ 642/642 |
| 24 套主题 token（继承自 video-maker）+ 图表配色派生 | ✅ |
| 中英分离的 PPTX 字体声明 | ✅ |
| 18 种图表（7 原生 + 11 矢量，含 custGeom 桑基缎带） | ✅ |
| 23 个版式骨架（15 通用 + 8 分析模型） | ✅ |
| 24 套主题配色逐条通过 CVD / 对比度校验 | ✅ |
| 浏览器内控制台（改字 + 控件 + 写回 deck.json） | ✅ |
| deck 校验器（容量 / required 事实 / 节奏 / 图表自洽） | ✅ |
| PDF 导出 | ✅ |
| source → plan → build → review → deliver 流程 + 9 个命令 | ✅ |

## 用

```bash
bash skills/ppt-maker/scripts/scaffold.sh ./deck --theme=swiss-ikb
bash skills/ppt-maker/scripts/scaffold.sh --list-themes

cd deck
npm run dev                 # → / ← 翻页，v 切换方案
npm run export:pptx         # dist/deck.pptx
npm run verify:geometry     # 校验两个渲染器坐标一致
```

`verify:geometry` 独立复算每个盒子应有的 EMU 坐标，再解压 .pptx 逐一比对。
**改完渲染相关代码必须跑一次。** 三份画廊是现成的回归集：

```bash
cp skills/ppt-maker/assets/gallery/charts.json     deck.json   # 325 个盒子
cp skills/ppt-maker/assets/gallery/archetypes.json deck.json   # 168 个
cp skills/ppt-maker/assets/gallery/models.json     deck.json   # 149 个
```

它只保证位置对，保证不了看起来对 —— 配色 / 字重 / 装饰层这类问题 code
review 一定看不出来，必须渲染后目检（SKILL.md 里有截图命令）。P0 靠这一步
抓到 3 个 review 漏掉的缺陷，P1 又抓到 9 个（饼图楔形被三次曲线拉成花瓣、
CSS 与 JS 的 `--chart-neg` 公式不一致、metric 数字不随框宽收缩导致相撞……）。

## 已知边界

- **PPTX 字重只有粗/不粗。** OOXML 的文本 run 没有数值字重，导出以 ≥600
  为界。swiss-ikb 的 200 极细在网页上是极细，在 .pptx 里是常规 —— 这是
  PowerPoint 的下限。
- **PPTX 不嵌字体。** 主题在 `theme.json` 里声明 `pptxFonts`（中文另给
  一套 `zh`），装不到就由 Office 自行替换。
- **7 种图表走原生、11 种走矢量。** 原生的（column/bar/line/area/pie/donut/
  radar）带可编辑数据表，但由 PowerPoint 画图元，样式是近似；矢量的
  （waterfall/funnel/heatmap/treemap/sankey/gantt/slope/dumbbell/marimekko/
  scatter/bubble）与网页逐像素一致，但数字是烧死的。单张图可用
  `chart.render: "vector"` 强制。
- **深色主题的图表次级序列色偏暗。** 序列色统一由 accent 向 surface / text
  两极派生（为了让 CSS 的 `color-mix()` 与导出器的 JS 公式保持一致，不按
  明暗分支），深色主题下 series-2 会靠近背景。有需要的主题自己声明
  `--chart-series-N` 覆盖。P4 处理。

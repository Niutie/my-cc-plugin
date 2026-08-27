# Deck DSL

`deck.json` 是**唯一事实源**。三个渲染器都从它出发，没有第二份数据：

```
deck.json ──compile──→ Composition ──┬─→ React        网页版 PPT
                                     ├─→ pptxgenjs    可编辑 .pptx
                                     └─→ Playwright   PDF（打印网页）
```

## 🔴 红线

**任何一页都不能携带自由 HTML / JSX / CSS。** 表达不了的东西就扩 DSL，不要
绕过它。一旦某页夹带裸标记，PPTX 导出就只能退化成 DOM walker —— 那正是
闭源同类产品掉进去的坑，也是它们的导出引擎无法开源的原因。

**任何一处都不能出现 `vw` / `vh` / `clamp()` / `em` 尺寸。** 舞台是固定
1920×1080、整体 transform scale 的画布：视口相对单位在屏幕上会二次缩放，
在 PowerPoint 里则毫无意义。一律绝对 px。

**渲染器不许自己算坐标。** 位置一律来自 `deck/layout.ts`、`deck/blocks.ts`。
两个渲染器如果对某个盒子的位置有分歧，那是 layout 的 bug，不是下游要
各自校正的差异。`npm run verify:geometry` 会机械地检查这件事。

## 坐标系

| | 网页 | PowerPoint |
|---|---|---|
| 舞台 | 1920 × 1080 px | 13.333 × 7.5 in |
| 换算 | — | **144 px / inch**（精确） |
| 字号 | px | **pt = px / 2**（精确，1pt = 1/72 in） |
| OOXML | — | 1 in = 914400 EMU |

网格 12 列 × 8 行，跨主题 padding（`--stage-pad-x/y`）后的内容区，
格间距 `GUTTER = 24px`。

三个放置修饰（都在 `elementRect()` 里统一解析，两个渲染器都不许自己算）：

| 字段 | 作用 |
|---|---|
| `bleed: true` | 贴合整幅 1920×1080，忽略舞台 padding |
| `size: {w,h}` | 在格子内固定 px 尺寸 —— 12px 的时间线刻度不该因为一列有 122px 就撑满 |
| `anchor` | `size` 生效时元素在格子里的位置，九宫格，默认居中 |

## 结构

```jsonc
{
  "schemaVersion": 1,
  "meta": { "title", "goal", "audience", "lang", "theme", "seed", "runId" },
  "slides": [{
    "id": "s2",
    "role": "metrics",              // 只做候选排序的软提示，不决定资格
    "content": {
      "presentation": {             // ★ 本页唯一事实源，所有方案共享
        "title", "titleShort", "summary", "summaryShort", "takeaway",
        "items": [{ "id", "label", "value", "displayValue",
                    "detail", "unit", "required", "priority" }]
      },
      "media": [],
      "meta": { "kicker": "第一部分 · 结果" }
    },
    "variants": [ /* 3 archetype + 1 bespoke */ ],
    "selectedVariant": "v1"
  }]
}
```

### 为什么要 `presentation` 这一层

各方案只是同一批事实的不同**排布**，不是三个不同的故事。冻结一份文案包
之后：

- 换版式不用重写文案
- `required: true` 的事实必须活到每个方案里，多密的版式都不能丢
- `titleShort` / `summaryShort` 让密集版式挑短的，而不是另写一句

### variants

```jsonc
// 模板方案：archetype 是函数，不是 React 组件
{ "id": "v1", "kind": "archetype", "archetype": "metric-spotlight",
  "props": { "secondaryCount": 3, "align": "left" } }

// 定制方案：Agent 在主题约束内现场设计
{ "id": "v4", "kind": "bespoke",
  "designIntent": { "objective", "audience", "narrativeRole",
                    "emphasis", "rationale", "compositionFamily" },
  "composition": { "background": "surface", "elements": [ ... ] } }
```

**archetype 编译成和 bespoke 一模一样的 `Composition`。** 这是整个架构的
关键一步：只有一种东西需要渲染，导出器永远不需要反解一个 React 组件。

### contentMap

把事实源投影到已编译的构图上，不改几何：

```jsonc
"contentMap": {
  "elements[2].text":  "presentation.title",
  "elements[4].items": "presentation.items"
}
```

## 元素

| type | 字段 | 说明 |
|---|---|---|
| `text` | `role` `text` `align` `valign` `accent` | role ∈ title / subtitle / body / kicker / caption / quote |
| `metric` | `value` `label` `unit` `detail` `accent` | 三段式，几何由 `metricBlocks()` 定 |
| `list` | `style` `items` `columns` | style ∈ bullet / numbered / card / rule |
| `shape` | `shape` `fill` `stroke` `orient` | rect / line / ellipse / diamond / triangle / chevron —— 都是 PowerPoint 同名 preset，导出即可编辑；`line` 用 `orient` 显式声明横竖 |
| `chart` | `chart` `caption` | 见下 |

## 图表

`ChartSpec.kind` 的联合类型就是路线图。**每加一种，两个渲染器必须同时
能画**：PowerPoint 有对应原生图表的走原生（收件人能打开数据表改数），
没有的用矢量形状拼（保真但不可改数）。

全部 18 种已实现。7 种（column / bar / line / area / pie / donut / radar）
默认导出为原生 PowerPoint 图表（带可编辑数据表），其余 11 种导出为矢量形状
（含 custGeom 三次贝塞尔）。单张图用 `"render": "vector"` 强制矢量。

**序列上限 6。** 一套主题给不出第 7 个可区分色相；`validate-deck` 直接报错，
渲染器对越界索引夹取而非回绕。详见 [`CHARTS.md`](CHARTS.md)。

图表配色是**独立于主题 accent 的一个参数**，每套主题的调色板由
`scripts/gen-chart-palettes.mjs` 生成并逐条通过 dataviz 校验器
（明度带 / 色度下限 / CVD 分离 / 常视觉下限 / 对比度）。手改要重跑校验。

`base.css` 里的兜底值只服务于手工新建、还没跑过生成器的主题 —— 它们**未经
校验**。

## 主题字重

主题可用 `--title-weight` / `--hero-num-weight` 表达性格（swiss-ikb 用
200，"越大越细"）。**PowerPoint 的文本 run 只有 b="1"/b="0"**，所以导出
时以 ≥600 为界折成粗/不粗 —— 200 权重在网页上是极细、在 .pptx 里是常规，
这是 PowerPoint 的下限，不是映射的 bug。

## 字体

PowerPoint 不嵌字体。主题在 `theme.json` 里声明 `pptxFonts`，中文另给一套
`zh`（承载西文性格的字面通常不是合适的中文字面，猜一个会导致本地看着没事、
换台机器就崩）。

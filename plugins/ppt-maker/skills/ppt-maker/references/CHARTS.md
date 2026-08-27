# 图表

18 种。选型不是审美问题——**图形本身就是论证**，选错的图会让正确的数据讲
出错误的故事。

## 先问：这页要说的是什么

| 要说的 | 用 | 别用 |
|---|---|---|
| 谁大谁小（类目 ≤ 8） | `column` | pie（比长度容易，比角度难） |
| 谁大谁小，但类目名字长 | `bar` | column 转标签 |
| 随时间怎么走 | `line` | column（横轴是连续量时） |
| 总量的累积与构成变化 | `area` | 多条 line 叠在一起 |
| 占比（≤ 5 片） | `pie` / `donut` | 6 片以上——改 bar |
| 两个变量相关吗 | `scatter` | 两条 line |
| 相关 + 第三个量级 | `bubble` | 给散点加标签 |
| 多维能力画像（3~8 维） | `radar` | 一排 metric |
| 总量怎么从起点走到终点 | `waterfall` | 首尾两根柱子 |
| 逐级转化的流失 | `funnel` | 递减的 bar |
| 两个维度交叉的密度 | `heatmap` | 表格 |
| 层级占比，量级悬殊 | `treemap` | pie |
| 资源从哪流到哪 | `sankey` | 两个 pie |
| 排期 | `gantt` | 时间线 + 文字 |
| 两个时点谁涨谁跌、名次换没换 | `slope` | 分组 column |
| 每一项前后的差距本身 | `dumbbell` | 分组 column |
| 类目体量 + 内部构成 | `marimekko` | 堆叠 column |

`chartDef(kind).reads` 里也记着这一句，`validate` 报错时会带出来。

## 导出：原生 vs 矢量

| | 原生 PowerPoint 图表 | 矢量形状 |
|---|---|---|
| 谁 | column / bar / line / area / pie / donut / radar | 其余 11 种 |
| 收件人能改数字 | ✅ 带内嵌 Excel 数据表 | ❌ 烧死 |
| 和网页逐像素一致 | ❌ PowerPoint 自己画图元 | ✅ |
| 值轴范围 | 钉死成 SVG 算出的 min/max，所以比例读起来一致 | 同一份几何 |

默认走原生（「同事能改数」通常比像素一致更值钱）。单张图要保真就写
`"render": "vector"`。

矢量那条路用 PowerPoint 的 `custGeom`，支持三次贝塞尔——桑基的缎带在
.pptx 里是真曲线，不是图片。

## 配色

**每套主题的图表配色是生成出来并逐条校验过的**，不要手改：

```bash
node ${CLAUDE_PLUGIN_ROOT}/skills/ppt-maker/scripts/gen-chart-palettes.mjs \
  --validator <dataviz-skill>/scripts/validate_palette.js
```

三件事值得知道：

1. **图表配色是独立于主题 accent 的一个参数。** 主题只允许一个饱和 accent
   （第二个会跟第一个打架），但序列身份靠色相承载。单色相的明度阶
   **实测通不过**——第一版做出来相邻 ΔE 13.2，硬底线是 15。所以 slot 1 是
   accent（accent 落在可读明度带内时），slot 2~6 是从它旋转开的色相。
2. **6 是诚实上限。** 一套主题给不出第 7 个可区分的色相。超过 6 条序列
   `validate` 直接报错——把尾部并成「其他」，或者拆图。渲染器对越界索引
   **夹取**而不是回绕，这样第 7 条看起来跟第 6 条一样（"序列太多"），
   而不是冒充第 1 条。
3. **热力 / 树图 / 漏斗用的是顺序色阶（`--chart-seq-*`），不是分类色。**
   那是另一种任务：单色相、明度单调、最浅一档仍要 ≥2:1 压得住底色。
   拿分类色的规则去校验顺序色阶会「按设计失败」，不要去修一条本来就对的色阶。

## 数据契约

```jsonc
{
  "kind": "column",
  "categories": ["Q1", "Q2", "Q3", "Q4"],   // 也是 x 轴
  "series": [
    { "name": "新客", "data": [62, 55, 51, 48] },
    { "name": "复购", "data": [32, 58, 77, 99] }
  ],
  "unit": "亿",
  "showValues": true,
  "legend": true,       // ≥2 条序列必须开，validate 会警告
  "baseline": 0,        // 柱子从零起才诚实；要裁轴就显式写
  "render": "native"    // 或 "vector"
}
```

- `data.length` 必须等于 `categories.length`（validate 查）
- `null` 是真实的缺口，不是 0——折线会断开而不是俯冲到轴上
- 几种图的 series 有特殊约定：
  - `gantt`：series[0] = 开始，series[1] = 结束
  - `sankey`：categories = 源节点，series = 目标节点，`series[t].data[s]` 是流量
  - `scatter` / `bubble`：categories 是 x（字符串形式的数字），series[0] = y，
    bubble 的 series[1] = 气泡大小（**按面积**映射，不是半径）
  - `waterfall`：单序列增量；类目名前加 `=` 表示这根是从零起的合计

## 反模式

- **双轴**。永远不要。两个量级不同的度量 → 两张图，或都换算成指数
- **给标称类目按数值上色**——柱长已经在说这件事了，色彩这个通道被浪费掉
- **每个点都标数**。选择性直标，不要满屏数字
- **文字穿序列色**。数值、标签、图例一律用文本色，旁边的色块负责身份

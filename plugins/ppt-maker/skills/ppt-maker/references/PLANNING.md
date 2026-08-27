# 内容规划

Phase 2 只产出一份 `plan.md`。它决定整份稿子的成败——**版式是可以换的，
事实源不行**。

## 为什么先写文案包，再挑版式

一页会有 4 个方案（3 个模板 + 1 个定制）。如果先挑版式再填字，四个方案会
变成四个不同的故事，读者切一下方案就发现说法变了。

所以顺序是死的：

```
素材 → 每页的 canonical 文案包 → 按容量挑版式 → 投影
```

`content.presentation` 是这一页的唯一事实源。所有方案渲染的是**同一批事实**，
它们只选择长短、排序、分组和视觉层级。

## 文案包写什么

```jsonc
"presentation": {
  "title":        "上半年核心数字",      // 完整标题
  "titleShort":   "核心数字",            // 密集版式挑短的，不是另写一句
  "summary":      "四个指标解释增长从哪来",
  "summaryShort": "增长从哪来",
  "takeaway":     "新客贡献下滑，老客复购撑起了增量",  // 听众只记住这一句
  "items": [
    { "id": "gmv", "label": "GMV", "value": 4.82, "displayValue": "4.82",
      "unit": "亿", "detail": "同比 +31%", "required": true }
  ]
}
```

几条不那么显然的规则：

- **`value` 是给图表的原始数，`displayValue` 是给人读的。** 图表只吃
  `value`。没有 `value` 的 item 进不了图表——一张用文字凑出来的图是撒谎。
- **`required: true` 的事实必须活到每个方案里。** 版式的 `visibleCount`
  控件会截断数组，被截掉的 required 事实在页面上是**看不见的缺失**，
  `npm run validate` 专门查这一条。
- **`*Short` 存在的意义是让密集版式挑短的，不是让你另写一句。** 两者说的
  必须是同一件事。
- **`id` 要稳定。** contentMap 和控制台都按 id 寻址。
- **`unit` 单独放，别拼进 `displayValue`。** metric 会用小一号字排单位，
  图表轴标签也要用它。

## 每页还要定三件事

| 字段 | 作用 |
|---|---|
| `role` | 软提示，只影响候选排序（cover / metrics / trend / comparison / matrix / process / case / risks / actions / result / closing…） |
| `priority` | 这页最重要的是什么：title / metrics / items / media / narrative |
| `meta.kicker` | 眉标，通常是「第几部分 · 什么」 |

`role` **不决定**版式资格——资格由容量决定（标题多长、几个 item、要不要
数字）。role 名字叫 `metrics` 但没有一个 item 带 `value` 的页，照样进不了
metric-wall。

## 页数与节奏

- 用户没说页数，默认 **10 页上下，不少于 8 页**
- 每页只讲一件事。一页塞两个论点 = 两页
- 相邻页不许同一个 composition family（`validate` 会警告）
- 卡片墙不许超过正文页的 1/3（`validate` 会报错）

一个常规复盘的骨架：

```
封面 → 目录 → 结果（数字）→ 结构（图表）→ 归因（对比 / 案例）
     → 风险 → 下一步（流程 / 时间线）→ 结尾
```

## plan.md 的样子

```markdown
# <deck 标题>
目标：<一句话，这份稿子要让听众做什么决定>
受众：<谁听 / 他们已经知道什么>
语言：中文 / 英文
主题：<theme id>（备选 <id> / <id>）

## 页面

### 1. cover · 2026 上半年业务复盘
- kicker：增长团队 · 2026 H1
- title / summary / takeaway：…
- 候选版式：cover-hero、cover-split
- 必含事实：无

### 2. metrics · 上半年核心数字
- items（★ = required）：
  - ★ GMV 4.82 亿（同比 +31%）
  - ★ 复购率 38%
  - ★ 获客成本 ¥214
  -   NPS 46
- 候选版式：metric-wall、metric-spotlight、chart-led(column)
- 图表：不用图，四个数字直接给
…
```

## 自检

进 Checkpoint Plan 之前逐条过：

- [ ] 每页都有 `takeaway`，且它是**结论**不是**描述**
- [ ] 每个数字都带单位，且和素材里的原值一致
- [ ] `required` 标了，而且总数不超过对应版式的容量
- [ ] 图表页的 item 都有 `value`
- [ ] 相邻页的 composition family 不重复
- [ ] 有封面、有结尾，中间不超过 1/3 是卡片墙
- [ ] 页数 8~14 之间；超过 14 先问用户要不要拆

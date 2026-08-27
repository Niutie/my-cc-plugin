# 版式骨架

23 个。它们是**起手式，不是模板库** —— 装不下的东西交给 bespoke 定制方案。
刻意保持小：大型版式库是一个人维护不了的重资产，而且会把 Agent 推向
「先挑好看的页面」而不是「先看内容再挑」。

## 挑选顺序（不可颠倒）

```
1. 写完这一页的 canonical 文案包
2. 量它：标题多少字 / 几个 item / 有没有 value / 要不要媒体
3. 问哪些骨架装得下  ← capacityError() 就是这一步的机器版
4. 从装得下的里面挑 3 个「结构家族不同」的
5. 第 4 个方案是 bespoke —— 先写 designIntent 再画 composition
```

先挑版式再塞字，是这套东西里最容易犯也最贵的错。

## 清单

| id | 名称 | family | 用在哪 |
|---|---|---|---|
| `cover-hero` | 封面 · 大标题 | hero | 标准封面，标题独占左上 |
| `cover-split` | 封面 · 左右分屏 | split | 封面，右侧留整块色/图 |
| `statement` | 金句 · 单句主张 | hero | 金句、单句主张、章节转场 |
| `agenda-numbered` | 目录 · 编号列表 | editorial | 目录，2~8 条 |
| `closing` | 结尾页 | hero | 结尾 + 最多 3 条下一步 |
| `metric-wall` | 指标墙 | metric-spotlight | 2~4 个并列指标 |
| `chart-led` | 图表主导 · 左文右图 | chart-led | 左文右图，结论有话说时 |
| `chart-full` | 图表主导 · 满幅 | chart-led | 图占满，数据自己说话时 |
| `comparison-split` | 对比 · 双栏 | comparison | A vs B 双栏 |
| `timeline-steps` | 时间线 · 横向节点 | timeline | 3~5 个时间节点 |
| `process-flow` | 流程 · 编号阶梯 | process | 3~6 步流程 |
| `matrix-2x2` | 矩阵 · 四象限 | matrix | 四象限，恰好 4 项 |
| `list-cards` | 要点 · 卡片网格 | editorial | 2~6 张要点卡（受 1/3 上限约束） |
| `case-detail` | 案例 · 单点深挖 | editorial | 单案例深挖 + 结果指标 |
| `metric-spotlight` | 单数字聚焦 | metric-spotlight | 一个数字撑全页 + 3 条副指标 |
| `model-swot` | SWOT 分析 | matrix | SWOT，恰好 4 项 |
| `model-pest` | PEST 分析 | matrix | PEST，恰好 4 项 |
| `model-bcg` | BCG 矩阵 | matrix | BCG 矩阵，恰好 4 项 |
| `model-bmc` | 商业模式画布 | matrix | 商业模式画布，恰好 9 项 |
| `model-porter` | 波特五力 | relationship | 波特五力，恰好 5 项 |
| `model-double-diamond` | 双钻模型 | process | 双钻，恰好 4 项 |
| `model-aarrr` | AARRR 海盗指标 | process | AARRR，恰好 5 项 |
| `model-flywheel` | 飞轮模型 | relationship | 飞轮，3~4 项 |

## 分析模型是特例

SWOT / PEST / BCG / 画布 / 五力 / 双钻 / AARRR / 飞轮 的骨架是**固定**的：
框架决定有几格、每格叫什么，内容只填格子。这跟其余骨架正好相反，而且是对的
—— 框架的全部价值就在于听众已经认识这个形状。

两个后果，都是刻意的：

- **item 数量是精确值，不是区间。** 少一格的 SWOT 不是 SWOT。
- **格子标题来自框架，不来自内容。** 你提供的是「优势」里放什么，
  永远不是用别的词替换「优势」。控制台里这些字**改不动**，会明确告诉你原因。

## 反卡片墙

每个骨架的几何必须**看得出**它的 family：时间线要有轴，流程要有方向，
矩阵要有象限。三者都画成一排卡片 —— 这是生成式稿子最容易被一眼认出的特征 ——
只有 `list-cards` 被允许这么做，而且它受 1/3 上限约束。

`npm run validate` 查两条：相邻页不同 family（警告）、卡片墙 ≤ 正文页 1/3（报错）。

## 控件

每个骨架声明自己的 typed controls（range / toggle / select），控制台照着渲染。
带 `bindsArray` 的 range 控件会截断内容数组 —— 被截掉的 `required` 事实
`validate` 会抓出来，因为那是页面上**看不见的缺失**。

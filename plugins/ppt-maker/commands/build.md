---
description: 铺完全部页面（每页 3 模板方案 + 1 定制方案）
argument-hint: '[页码范围，如 4-12；默认全部]'
allowed-tools: Bash, Read, Write, Edit
---

参数：$ARGUMENTS

执行 ppt-maker 的 Phase 4。

必读 `references/ARCHETYPES.md`（选骨架）和 `references/CHARTS.md`（选图表）。

每页：先写 canonical 文案包 → 按容量挑骨架 → 3 个结构家族不同的模板方案 →
第 4 个 bespoke（先写 designIntent 再画 composition，几何必须看得出声明的
compositionFamily）。

红线：相邻页不同 composition family；卡片墙 ≤ 正文页 1/3；图表序列 ≤ 6。
每铺几页就跑一次 `npm run validate`，不要攒到最后。

下一步：/ppt-maker:review 走终审。

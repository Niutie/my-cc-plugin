---
description: 终审 —— 机器四检 + 六维人工验收 + 最小切片修复
argument-hint: '[--fix 直接修复待修正项]'
allowed-tools: Bash, Read, Write, Edit
---

参数：$ARGUMENTS

执行 ppt-maker 的 Phase 5。

```bash
npm run check     # typecheck + validate + export:pptx + verify:geometry
```

全绿之后**必须渲染截图逐页目检** —— 机器校验保证不了看起来对。

按 `references/ACCEPTANCE.md` 的六个维度判断，给出三态结论之一：
通过 / 待修正 / 阻塞。「待修正」只改失败的那几页（最小切片），
改完再复验这几页。

铁律：先按 fail 项改完，再向用户汇报。

下一步：/ppt-maker:deliver 确认交付格式后出货。

---
description: 只出货，不走流程
argument-hint: '[--pptx] [--pdf] [--html]'
allowed-tools: Bash, Read
---

参数：$ARGUMENTS

已有 `deck.json` 时直接导出：

```bash
npm run export:pptx     # 可编辑 PPTX
npm run export:pdf      # PDF
npm run build           # 离线网页版
npm run verify:geometry # 核对两个渲染器坐标一致
```

导出前先跑 `npm run validate`。边界见 `references/EXPORT.md`。

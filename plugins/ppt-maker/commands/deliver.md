---
description: 交付 —— 停在 Checkpoint Deliver 再出 HTML / PPTX / PDF
argument-hint: '[--pptx] [--pdf] [--html] [--comparison]'
allowed-tools: Bash, Read
---

参数：$ARGUMENTS

执行 ppt-maker 的 Phase 6。

先停在 **Checkpoint Deliver** 问清要哪种（可多选），再照
`references/EXPORT.md` 出货，并在交付说明里带上该格式的边界
（PPTX 的字重二值化与字体替换、PDF 需要本机 Chrome、网页版要整个目录）。

```bash
npm run export:pptx
npm run export:pptx -- --mode=comparison
npm run export:pdf
npm run build
```

下一步：改稿不必回来找我 —— `npm run dev` 按 C 开控制台，见 references/CONSOLE.md。

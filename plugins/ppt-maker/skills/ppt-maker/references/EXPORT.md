# 交付

三条出口，同一份 `deck.json`。

```bash
npm run build                             # dist-web/ —— 可离线打开的网页版
npm run export:pptx                       # dist/deck.pptx —— 可编辑
npm run export:pptx -- --mode=comparison  # 每页展开全部方案（4N 页）
npm run export:pdf                        # dist/deck.pdf
```

`npm run dev` 时控制台里还有个**导出 PPTX** 按钮：它在 dev server 里跑上面
那条同样的 `export:pptx`，写同一个 `dist/deck.pptx`，并把字节流回浏览器下载。
先保存后导出，所以拿到的一定是屏幕上这份。它**不跑**几何校验，也没有
comparison 模式 —— 见 [`CONSOLE.md`](CONSOLE.md)。

## 网页版

`base: "./"`，所以构建产物直接双击 `index.html` 就能开，不需要服务器。
`?capture=1` 去掉所有 chrome，给截图和录制用；`?slide=N` 直接定位。

## PPTX

- 舞台 1920×1080 px ↔ 13.333×7.5 in，**144 px/inch**；字号 **pt = px/2**。
  两者都是精确整除，`npm run verify:geometry` 会解压 .pptx 逐个盒子核对 EMU。
- 7 种图表导出为**原生 PowerPoint 图表**，带内嵌 Excel 数据表，收件人能改数字。
  其余 11 种导出为真实矢量形状（含 custGeom 曲线），逐像素一致但数字烧死。
- **字重只有粗/不粗。** OOXML 的文本 run 没有数值字重，导出以 ≥600 为界。
  swiss-ikb 的 200 极细在网页上是极细，在 .pptx 里是常规 —— 这是 PowerPoint
  的下限，不是映射的 bug。
- **不嵌字体。** 主题在 `theme.json` 里声明 `pptxFonts`，中文另给一套 `zh`
  （承载西文性格的字面通常不是合适的中文字面，猜一个会导致本地看着没事、
  换台机器就崩）。装不到时由 Office 自行替换。
- 定制方案的渐变、混合模式、装饰层不会过去 —— DSL 本来就不允许它们，
  这条边界在设计时就画好了。

## PDF

打印网页版，不是第三次遍历 DSL。PDF 是稿子的一张照片，浏览器已经知道怎么
拍对，包括 PowerPoint 装不下的字体和效果；再从 DSL 推一遍只会引入第三套
取整规则。

`?print=1` 把所有页堆叠，每页正好一张 PDF 页（1280×720 CSS px = 13.333×7.5 in
@96dpi，1920 舞台缩放 2/3），所以是一次打印任务而不是 N 个文件再合并。

需要本机 Chrome（`playwright-core` 驱动 `channel: chrome`）。

## 选哪个

| 场景 | 给什么 |
|---|---|
| 同事要接着改 | `.pptx` |
| 邮件 / IM 发出去看 | `.pdf` |
| 要在浏览器里放映、或要保留交互 | `dist-web/`（整个目录） |
| 让用户在几个版式方案里挑 | `--mode=comparison` 的 `.pptx` |

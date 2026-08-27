# 主题

24 套，继承自 video-maker，外加 ppt-maker 自己的两层扩展：**图表配色**和
**PPTX 字体**。

一份稿子从头到尾用一个主题。切主题 = 覆盖两个文件：

```bash
cp ${CLAUDE_PLUGIN_ROOT}/skills/ppt-maker/themes/<id>/tokens.css  deck/src/styles/tokens.css
cp ${CLAUDE_PLUGIN_ROOT}/skills/ppt-maker/themes/<id>/theme.json  deck/src/styles/theme.json
# deck.json 的 meta.theme 也要跟着改，否则导出器会警告
```

列全部：`bash ${CLAUDE_PLUGIN_ROOT}/skills/ppt-maker/scripts/scaffold.sh --list-themes`

## 主题管什么

| 维度 | token |
|---|---|
| 表面色阶 | `--shell` / `--surface` / `--surface-2` / `--surface-3` |
| 文字色阶 | `--text` / `--text-2` / `--text-mute` / `--text-faint` |
| 线条与强调 | `--rule` / `--accent` / `--accent-soft` |
| 字型 | `--font-display-cn/en` / `--font-body` / `--font-mono` |
| 舞台密度 | `--stage-pad-x/y` ← **决定 12×8 网格的实际尺寸，导出器也读它** |
| 性格旋钮 | `--r-card` / `--rule-w` / `--title-weight` / `--hero-num-*` |
| 装饰层 | `--surface-pattern*` / `--surface-vignette` |
| 图表配色 | `--chart-series-1..6` / `--chart-seq-1..5` / `--chart-grid` / `--chart-axis` / `--chart-label` / `--chart-pos` / `--chart-neg` |

`tokens.css` 是**唯一事实源**：浏览器当 CSS 变量用，PPTX 导出器解析同一个
文件。没有第二份 JSON，所以主题不可能在屏幕和导出之间漂。

**导入顺序**：`base.css`（默认值）在前，`tokens.css`（主题）在后。反了会让
网页用兜底值而导出器用主题值 —— 两套颜色，所有机器校验还全绿。

## 图表配色是生成的，不是手挑的

```bash
node ${CLAUDE_PLUGIN_ROOT}/skills/ppt-maker/scripts/gen-chart-palettes.mjs \
  --validator <dataviz-skill>/scripts/validate_palette.js
```

生成器为每套主题产出 6 个分类色 + 5 级顺序色阶，并逐条跑 dataviz 校验器的
六项检查（明度带 / 色度下限 / CVD 分离 / 常视觉分离下限 / 对比度）。
当前 24 套全部通过。

为什么不能只用 accent 的明度阶：**实测通不过**。第一版就是单色相明度阶，
相邻 ΔE 13.2，硬底线 15。所以图表配色是**独立于 accent 的一个参数** ——
slot 1 仍是 accent（accent 落在可读明度带内时），slot 2~6 是从它旋转开的色相。

## PPTX 字体

PowerPoint 不嵌字体。`theme.json` 的 `pptxFonts` 声明导出时写进 .pptx 的字族：

```json
"pptxFonts": {
  "display": "Arial", "body": "Arial", "mono": "Consolas",
  "zh": { "display": "SimSun", "body": "SimSun", "mono": "Microsoft YaHei" }
}
```

中文单独一套，不是魔法回退：承载西文性格的字面通常不是合适的中文字面，
猜一个会导致本地看着没事、换台机器就崩。衬线主题给 SimSun，其余给
Microsoft YaHei —— 都是 Office 装得到的。

## 造新主题

1. 复制最接近的一套：`cp -r themes/monochrome-print themes/my-theme`
2. 改 `tokens.css` 的调色板 / 字体 / 性格旋钮。**只挑一个设计签名**重重发力
   （虚线 rule、粗黑边、扫描线、纸纹、glass slab），叠三个会互相打架
3. 改 `theme.json` 的 `id`（必须等于目录名）/ `nameZh` / `bestFor` / `preview`
4. **跑配色生成器** —— 不跑的话图表用的是未经校验的兜底色
5. 用三份画廊过一遍视觉：`assets/gallery/{charts,archetypes,models}.json`

几条不显然的规则：

- 深色主题的 `--shell` 比 `--surface` 更深；浅色主题的 `--shell` 略灰一点。
  舞台要读起来是主体，外围要退后
- `--text` 与 `--surface` 至少 4.5:1；96px 以上的标题可放宽到 3:1
- `--accent` 是**唯一**的饱和色。第二个饱和色会跟第一个打架 ——
  图表需要更多颜色时走 `--chart-series-*`，那是另一个参数

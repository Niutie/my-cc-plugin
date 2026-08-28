# 控制台

`npm run dev` 之后按 `C`（或加 `?console=1`）。

## 能改什么

| 操作 | 落到哪 |
|---|---|
| 双击页面文字 | canonical 内容层（`presentation.*` / `items[i].*` / `meta.*`） |
| 拖 range 控件 | `variant.props.<key>` |
| 切 select / toggle | `variant.props.<key>` |
| 点方案 | `slide.selectedVariant` |
| 「写回 deck.json」/ ⌘S | 整份 deck POST 到 dev server，重写 `deck.json` |
| 「导出 PPTX」 | dev server 里跑 `scripts/export-pptx.ts`，写 `dist/deck.pptx` 并把同一份字节流回浏览器下载 |

保存之后 `npm run export:pptx` 直接带上改动 —— 这是控制台存在的全部意义。
只改像素的控制台是个 demo；这里的要求是**屏幕上改的东西，同事在 PowerPoint
里打开就是那样**。

## 编辑落在内容层，不落在构图上

这是控制台唯一重要的设计决定。

如果编辑直接改已编译的 composition，切一下方案改动就没了，而 .pptx 会带上
「碰巧赢了的那份文案」。所以编辑走**溯源**：找出屏幕上这段字是哪个 canonical
字段产出的，然后写到那里。

溯源用的是**值匹配**而不是编译期埋点：让每个 archetype 把 provenance 一路
传下去，任何一个漏了就会产出「悄悄不可编辑」的文字。值匹配只有一个失败模式
—— 两个字段存了一模一样的字符串 —— 而且解析顺序是固定的，行为至少可预期。

**没有 canonical 来源的文字改不动**：框架标题（「S · 优势」）、编号、轴标签。
控制台会直说原因，而不是假装改成功了。

## 导出按钮

按钮**先保存再导出**，无条件。导出器从磁盘读 `deck.json`，所以「脏着导出」
会给你一份不是屏幕上这份的稿子 —— 这是控制台里加导出按钮唯一会引入的新
失败模式，先存一次就没了。按钮上的字会跟着状态走（`保存并导出 PPTX` →
`导出中…` → `已下载 ✓`），失败时把导出器的原话贴出来，不吞。

按钮跑的是**同一个** `scripts/export-pptx.ts`，不是第二个浏览器版导出器 ——
第二份实现会和 `verify:geometry` 校验的那份漂移。代价是它只能在 dev server
里跑，以及：

- **按钮不跑几何校验。** 交付前仍然要 `npm run check`。
- **只导选中方案。** `--mode=comparison`（每页展开全部方案）只有命令行有。

## 边界

- **控制台只在 dev server 下能保存和导出**。构建产物没有那两个中间件 ——
  这是刻意的：你发给别人的稿子是成品，不是共享编辑器。
- 定制（bespoke）方案没有控件。它的构图是 Agent 逐页设计的，要改回对话里说。
- 改完记得跑 `npm run check`：控件把 `visibleCount` 调小可能截掉 `required`
  事实，那是页面上看不见的缺失。

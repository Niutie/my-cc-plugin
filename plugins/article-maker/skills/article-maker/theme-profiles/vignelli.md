# Theme Profile · vignelli（瑞士国际主义文档）

> 这是给 **AI 写作时读** 的 authoring profile，不是 CSS。CSS token 由组件库
> 运行时主题持有（`data-theme="vignelli"`）。本文件是"如何选择和使用这个主题"。
> 详尽版本见组件库 canonical md：`src/theme/themes/vignelli/vignelli.md`（写代码 /
> 公式 / 媒体 / Raw 前请读它）。

- **runtime theme id**：`vignelli`（`<ThemeProvider theme="vignelli">`）
- **气质**：瑞士国际主义排版。ReActicle **唯一的 sans 正文 + 冷中性**主题。冷中性纸、
  一个 grotesque 字族在不同字号上建立层级、发丝网格线、一抹瑞士红、等宽体承载元数据。
  完整继承结构纪律（以线代框、去垃圾表格、色彩承载含义）。

## 培训 / 赋能课程模版（article-maker 的 training 模版 · 对标 video-maker `training-center`）

> **这是 article-maker 里做企业培训 / 认证课 / Partner 赋能 / 产品 onboarding 文章时的首选模版。**
> 它是 reacticle 里唯一的「净白底 + 双语友好无衬线 + 网格化 + 高信息密度 + 可扫读」机构气质主题，
> 与 video-maker 的 `training-center` 视频主题同源 —— 二者搭配能让「培训视频 + 配套讲义文章」气质统一。
>
> **关于强调色**：vignelli 默认 accent 是一抹瑞士红（reacticle 运行时 CSS），而 `training-center`
> 视频用 royal 蓝。要与视频对齐，**脚手架时加 `--accent="#2b3f9e"` 即可** —— 它把 accent + info 换成
> 该蓝（强 / 浅变体自动用 `color-mix` 派生），写进工作区 `article/theme-overrides.css`，
> risk / warn 警示红保持不变，也不影响别处用 vignelli。命令：
> `scaffold.sh ./course --theme=vignelli --accent="#2b3f9e"`。想保留瑞士红就别传 `--accent`；
> 想要别的品牌色把 hex 换掉即可。（`bayer` 仍是另一个蓝调教学候选，但暖纸 + 三原色更"品牌活泼"。）

做培训 / 赋能文章时：

- **结构先行、可扫读**：用清晰的模块编号 + 网格对齐承载课程层级（呼应 training-center 的 L0–L3 /
  模块化），靠字号与留白建立层级，不堆字重、不上彩色卡。
- **双语友好**：grotesque 字族对中英混排友好；术语 / 时长 / 模块号用等宽体作 metadata chip。
- **高密度但克制**：规格表、流程 / 状态图、步骤网格、键盘 / 快捷键图都合适；瑞士红只承载信息
  （重点 / 风险），不作装饰。
- 推荐文章类型：`tutorial`（上手 / 实操课）、`explainer`（概念 / 体系课）、`full-report`（认证 / 复盘）。

## 适合 / 不适合的文章类型

- **适合**：`docs` / 产品文档、`spec` / 技术规格、`changelog` / release notes、
  `reference` / SDK·API 参考、AI 工具 / 平台文档、`explainer`、`tutorial`。
  需要强结构、可扫读的中性内容。
- **不适合**：温暖叙事（`press`）；正式学术论文（`knuth`）；暗底工程现场（`shannon`）；幻灯片。

## 排版气质

- 正文与标题用单一 grotesque 字族（Söhne → Aktiv Grotesk → Helvetica Neue → Arial），
  **靠字号与留白、而非堆字重**建立层级。
- 标签 / 表头用同一字族小字号；元数据 / 代码用等宽体作 metadata "chip"（以线与字重呈现，
  绝不做成彩色胶囊或卡片）。
- 正文 ~17px，行距 1.6；大标题带负字距保持紧致。强调不用斜体（协议级禁用）。

## Raw 风格

像一页严格按网格设计的系统文档插图。

- 约束的是**气质**（冷中性、强网格、系统化、可扫读），不是**媒介**。
- 典型：网格示意、流程 / 状态图、规格对照表、键盘 / 快捷键图、可切换参数说明、
  带 mono 标注的 SVG。
- 构图：强网格对齐、清晰层级、瑞士红作识别线索；填色克制、服务理解。颜色只用 `--ra-*`。
- 动效：允许短促干脆的一次性过渡（~120ms）；避免无限循环装饰。

## 媒体（图片 / 视频 / 音频）风格

- 适合：界面截图（裁净 chrome）、信息图 / 流程图 / 网格示意、图标系统说明、线框 / 规格图、
  低饱和中性摄影。
- 构图强网格对齐、留白克制、主体清楚；caption 简洁说明来源；必须配 alt。
- 色彩贴近冷中性体系，强调只用瑞士红承载信息。

## 代码 / 公式风格

- `CodeBlock` 像排版严谨的技术规格：冷纸浅 surface + 发丝线，不用暗色编辑器窗口。行号克制。
- Prism token 从主题派生：标签 / 函数用瑞士红 accent（克制），关键字 / 风险用 risk 深红，
  字符串用绿，其余走墨色 / muted。
- `Formula` 像规格里的公式：克制、对齐、发丝线与留白承载。

## 禁止项

- 卡片、面板、填色块、投影、圆角、**彩色左边框强调卡**（被点名的 slop）。
- 把瑞士红当装饰；第二个红色用于"警示"以外；用堆字重代替字号层级。
- 紫粉渐变 SaaS hero、霓虹、Tailwind 默认味、emoji / 图标当装饰、3D 渲染图标。
- Raw / 媒体变成营销落地页或仪表盘大屏。

## 不同信息密度下的表现建议（建议，非限制）

- `100% docs / reference`：系统化长文 + 规格表 + 网格图，正文为主体。
- `60-80% spec / changelog`：保留关键规格 + 流程图，mono 元数据带扫读友好。
- `40% briefing`：Raw 偏网格图解，文字更短，仍是文档形态。

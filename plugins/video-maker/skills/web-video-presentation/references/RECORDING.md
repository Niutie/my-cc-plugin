# 录制与后期合成

网页做完之后，把它变成 mp4 有三条路径，**从省事到费事**：

| 路径 | 谁来录 | 何时用 |
|---|---|---|
| **① 一键出片（推荐）** | `npm run record-video` 无人值守直接出 mp4 | 已合成音频；想要一条命令出片、零手动 |
| ② Auto 一镜到底 | 你手动开屏幕录制 + 按 SPACE | 想自己掌控录制 / 加摄像头画中画等 |
| ③ Manual 手动录 | 你手动点击推进 + 后期配音 | 没合成音频、想后期精修 |

下面先讲 ①，②③ 在后面。

---

## ① 一键出片（无人值守，推荐）

```bash
cd presentation
npm run record-video            # → output/video.mp4（1920×1080 mp4）
```

**一条命令，从网页到成品 mp4** —— 不用开浏览器、不用屏幕录制软件、不用后期
裁头尾对音轨。脚本（`scripts/record-video.mjs`）做四件事：

1. 起 dev server，用 **Playwright 无头驱动 `?capture=1`**（默认调**系统 Chrome**，
   零额外下载），录下 1920×1080 画面；
2. 按 `narrations.ts` 的全量 step 结构 + 每条 mp3 的真实时长（`ffprobe`）
   排出一张**时刻表**，按表逐步推进页面；
3. 把每步 mp3 按**同一张时刻表**拼回整条音轨（每段后垫 200ms，和运行时
   `useAudioPlayer` 完全一致；空 step 用字数估时的静音填充）；
4. `ffmpeg` 自动裁掉黑色 pre-roll、合成视频 + 音轨 → `output/video.mp4`。

> **为什么音画必然同步**：推进画面用的时刻表 = 拼音轨用的时刻表，是同一张。
> 视频里每步的切换点和音轨里每段的边界落在同一时间轴上，**靠构造对齐**，
> 不依赖"边播边抓声音"那种脆弱实时同步（而且 Playwright 只能录画面、不录声音，
> 所以本来也得离线拼音轨）。

### 前置

- 章节代码做完，每章都有 `narrations.ts`
- **已合成音频**（`public/audio/<id>/<step>.mp3`）—— 没有也能跑，但成片**静音**、
  只按字数估时排节奏（先 `npm run extract-narrations && npm run synthesize-audio` 才有口播）
- `ffmpeg` + `ffprobe` 在 PATH（`brew install ffmpeg` / `apt-get install ffmpeg`）
- `playwright`（脚手架已装为 devDep；缺则 `npm i -D playwright`）
- 一个浏览器：默认用你装的 **Google Chrome**；没有则 `npx playwright install chromium`

### 常用参数

```bash
npm run record-video -- --out=dist/talk.mp4   # 换输出路径
npm run record-video -- --fps=60              # 提帧率（默认 30）
npm run record-video -- --crf=16              # 提画质，文件更大（默认 18，越小越好）
npm run record-video -- --headed              # 看着浏览器跑（调试）
npm run record-video -- --keep-temp           # 保留 .capture-tmp/ 中间文件
npm run record-video -- --url=http://localhost:5174  # 录一个已在跑的 dev server
```

> **某步动画被切一半？** capture 和 Auto 一样**严格按音频时长推进**（+200ms），
> 没有"等动画跑完"的兜底。说明该 step 动画长于口播 → 回章节代码：写更长口播 /
> 拆 step / 调快动画。改完重跑即可（音频增量、不重烧）。

> **画质**：实时录制 ≈ 一次干净的屏幕录制（再转 H.264）。要逐帧无损得改成
> Remotion/timecut 式的逐帧渲染，但那要求动画都跑在可 seek 的时钟上、会约束
> 章节写法 —— 当前不走这条。绝大多数"伪装成视频的网页"用实时录制足够。

---

如果你不打音频，仍可走 ② Auto 屏幕录制 或 ③ "手动点击 + 后期配"（见下）。

---

## ② Auto 一镜到底（你手动开屏幕录制）

> 想自己掌控录制（加画中画、特定录屏软件、边录边讲）时走这条。否则用 ①。

### 前置

- 章节代码做完，每章都有 `narrations.ts`
- 已经跑过 `npm run extract-narrations` + `npm run synthesize-audio`，
  `public/audio/<id>/<step>.mp3` 全部就位
- `npm run dev` 跑着，浏览器能打开页面

### 录制步骤

1. **浏览器全屏**（F11 / Ctrl+Cmd+F），URL 改成
   `http://localhost:5174/?auto=1`
2. 看到 "Press SPACE to start" 蒙层 = Auto 模式就绪
3. **打开屏幕录制**（QuickTime / OBS / Cmd+Shift+5），开始录
4. **按一次 Space** → 蒙层消失 → step 0 出现，1.mp3 自动播 →
   播完自动推进到 step 1 → 2.mp3 → … → 最后一个 step 播完 → 停在终态
5. **停止录制** → 后期裁掉头尾（Space 那一下、最后停在终态的尾巴）就是
   成品

整个过程**完全不用点鼠标**。音视频天然同步，不需要后期对轨。

> **Auto 模式严格按音频结束推进**（+ 200ms 缓冲），没有"等动画跑完"
> 的兜底。如果你看到某步动画被切了一半 → 说明该 step 动画长于口播，
> 回章节代码改：写更长口播 / 拆 step / 调动画速度。

> **每次以 `?auto=1` 打开或刷新都从第 1 章第 1 步开始** —— 录废了想重来，
> 直接刷新页面再按 Space 即可，不会从上次停的地方接着播。（这只对 `?auto=1`
> **加载**生效；在 Manual 里按 `M` 切到 Auto 会从**当前位置**开始、不重置。
> Manual / Audio 模式刷新仍会续看上次进度，方便开发。）

### 录屏工具

| 平台 | 工具 | 设置 |
|---|---|---|
| macOS | Cmd+Shift+5 → 录制选定窗口 | 选浏览器窗口；浏览器全屏后输出就是 1920×1080 |
| macOS | QuickTime → 文件 → 新建屏幕录制 | 同上 |
| 跨平台 | OBS Studio | 窗口捕获，Canvas 1920×1080，60fps |

### 模式速查

| URL / 快捷键 | 行为 |
|---|---|
| 直接打开（默认） | Manual：点击 / ←→ 推进，不播音频 |
| `?audio=1` 或按 `M` | Audio：进入 step 自动播音频，但**手动点鼠标推进** |
| `?audio=1` + 再按 `M` | Auto：进入 step 自动播 + 自动推进（录制用） |
| Auto 模式下首次按 `Space` | 启动 Auto 播放（绕过浏览器自动播放限制） |

也可以鼠标移到右上角，会出现一个隐藏的模式切换按钮。

---

## ③ Manual 手动录（没合成音频时）

如果你跳过了音频合成（`Checkpoint Audio` 选了"不合成"），按老方法：

1. 浏览器全屏 → 打开 `localhost:5174`（默认 Manual 模式）
2. 按 **Home** 键回到开头（Manual 模式刷新会**续看**上次进度、不清空；
   想从头录就按 Home）
3. 开始录屏 → 按口播节奏点击空白推进 step
4. 后期用任何剪辑软件配音 + 调时间线

### 后期工具

| 工具 | 适合 |
|---|---|
| **DaVinci Resolve** | 跨平台免费、能处理多段音频拼接 |
| **iMovie** | macOS 简单场景 |
| **CapCut / 剪映** | B 站 / 抖音风加字幕 |

---

> agent 在 Checkpoint Audio 后**主动告诉用户**把网页变成 mp4 的路径：
> 合成了音频 → 首推 **① 一键出片**（`npm run record-video`，或 `/video-maker:capture`）；
> 想自己掌控录制 → ② Auto 屏幕录制；没合成音频 → ③ Manual 手动录 + 后期配音。

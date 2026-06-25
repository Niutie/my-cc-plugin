---
description: 一键出片 — 无头驱动 ?capture=1 录屏 + ffmpeg 合轨，直接产出 1920×1080 mp4（无需手动录屏 / 后期对轨）
argument-hint: '[--out=output/video.mp4] [--fps=30] [--headed] [--keep-temp] [--url=http://localhost:5174]'
allowed-tools: Bash, Read
---

你在执行 video-maker 的 **Phase 4 · 一键出片（无人值守）**。参数：$ARGUMENTS
必读：`${CLAUDE_PLUGIN_ROOT}/skills/web-video-presentation/references/RECORDING.md`「一键出片」节。

机制：`scripts/record-video.mjs` 无头驱动 `?capture=1`（系统 Chrome 录画面），
把每步 mp3 按**和录制相同的时刻表**拼回音轨，再用 ffmpeg 合成成片 —— 音画
天然同步，**不用手动录屏、不用后期对轨**。

步骤：

1. **探测前置**：
   - `presentation/` 在不在、`npm` 依赖装没装（没装先 `cd presentation && npm install`）。
   - `ffmpeg` / `ffprobe` 在不在 PATH（缺 → 提示 `brew install ffmpeg`，停下）。
   - `presentation/public/audio/` 有没有 mp3：
     - **有** → 正常出**带口播**的成片。
     - **没有** → 成片会**静音**（按字数估时排节奏）。先问用户要不要先
       `/video-maker:audio` 合成音频；用户要"先出静音版预览"再继续。
   - playwright 在不在（脚手架已装；缺 → `cd presentation && npm i -D playwright`）。
     默认驱动**系统 Chrome**（零额外下载）；没有 Chrome 时按脚本提示
     `npx playwright install chromium`。

2. **出片**（脚本会自动起 / 关 dev server）：

   ```bash
   cd presentation && npm run record-video -- $ARGUMENTS
   ```

   不传参就是默认：`output/video.mp4`、1920×1080、30fps、系统 Chrome 无头。

3. **看自检结果**：脚本出片后会逐 step 抽帧自检。
   - 打印 `✓ verified N steps — no blank scenes detected` → 干净，正常汇报。
   - 打印 `⚠ … step(s) look BLANK` → **别直接说"做完了"**。这通常是渲染故障
     （不是章节代码 bug，尤其当你用了 `--url` 复用旧 server 时）。先**换全新
     server 重渲**（去掉 `--url`），看 `output/verify-frames/` 里存的问题帧确认，
     复核 OK 再汇报。

4. **汇报**：成片路径 + 时长 + 分辨率 + 多少步有口播 + 自检结论。提示可调参数：
   - `--out=<path>` 换输出路径；`--fps=60` 提帧率；`--crf=16` 提画质（更大）；
   - `--headed` 看着浏览器跑（调试）；`--keep-temp` 留中间文件；`--no-verify` 跳过自检；
   - `--url=http://localhost:5174` 录一个**已在跑**的 dev server（跳过自动起服务）。
     ⚠️ **优先用默认的全新 server**（不传 `--url`）—— 复用一个被 HMR 热更新过很多次
     的长驻 dev server 偶发会把某一屏渲染成空白。

> 录出来某步动画被切一半 = 该 step 动画比口播长（Auto / capture 都严格按
> 音频时长推进，无"等动画跑完"兜底）→ 回章节代码：写更长口播 / 拆 step /
> 调快动画。改完重跑即可（音频增量、不重烧）。

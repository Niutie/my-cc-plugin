#!/usr/bin/env node
// ────────────────────────────────────────────────────────────────────
// record-video.mjs — headless one-shot: web presentation → finished mp4.
//
// Drives the page in `?capture=1` mode through window.__capture (no manual
// clicking, no screen recorder), records the video with Playwright, rebuilds
// the audio track OFFLINE from the per-step mp3 files, and muxes them with
// ffmpeg into output/video.mp4.
//
// Why this is reliable: Playwright records video only (no audio), so instead
// of capturing the browser's sound we reconstruct the audio track from the
// same mp3 segments the runtime would play, on the SAME per-step schedule the
// recorder uses to advance the page. Video step-transitions and audio segment
// boundaries therefore sit on one shared timeline → they line up by
// construction. No fragile real-time A/V sync.
//
// Per-step hold (mirrors the runtime's useAudioPlayer):
//   • step has a real mp3        → ffprobe(duration) + 200ms trailing pad
//   • silent / missing audio     → max(1500ms, text.length × 250ms) estimate
//
// Requirements:
//   • ffmpeg + ffprobe in PATH
//   • playwright installed in the project (npm i -D playwright)
//   • a browser: uses your system Google Chrome by default (channel: chrome,
//     zero download); falls back to Playwright's bundled Chromium if present.
//
// Usage:
//   npm run record-video                       # start dev server, record, mux
//   npm run record-video -- --out=dist/talk.mp4
//   npm run record-video -- --url=http://localhost:5174   # use a running server
//   npm run record-video -- --headed           # show the browser (debug)
//   npm run record-video -- --fps=30 --keep-temp
//
// Flags:
//   --url=<url>      record an already-running dev server (skip auto-start)
//   --out=<path>    output mp4 (default: output/video.mp4)
//   --port=<n>      dev-server port to start / poll (default: 5174)
//   --fps=<n>       output frame rate (default: 30)
//   --black=<ms>    black pre-roll length before playback (default: 600)
//   --tail=<ms>     hold after the last step before stopping (default: 700)
//   --crf=<n>       x264 quality, lower = better/larger (default: 18)
//   --headed        run the browser headed (default: headless)
//   --keep-temp     keep the intermediate .capture-tmp/ dir
// ────────────────────────────────────────────────────────────────────
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, "..");

// ── args ──────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const flag = (name, def) => {
  const hit = args.find((a) => a === `--${name}` || a.startsWith(`--${name}=`));
  if (!hit) return def;
  const eq = hit.indexOf("=");
  return eq === -1 ? true : hit.slice(eq + 1);
};
const PORT = Number(flag("port", 5174));
const URL_ARG = flag("url", null);
const OUT_ARG = flag("out", "output/video.mp4");
const FPS = Number(flag("fps", 30));
const BLACK_MS = Number(flag("black", 600));
const TAIL_MS = Number(flag("tail", 700));
const CRF = Number(flag("crf", 18));
const HEADED = flag("headed", false) === true;
const KEEP_TEMP = flag("keep-temp", false) === true;

const OUT = isAbsolute(OUT_ARG) ? OUT_ARG : resolve(process.cwd(), OUT_ARG);
const TMP = join(ROOT, ".capture-tmp");
const SLOTS = join(TMP, "slots");

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Tracked so die() / Ctrl-C can tear down the detached dev server. Without
// this, any error after the server starts would orphan vite on PORT and, with
// --strictPort, wedge every subsequent run until the port is freed by hand.
let activeServer = null;
const stopServer = () => {
  if (!activeServer) return;
  try {
    activeServer.stop();
  } catch {
    /* ignore */
  }
  activeServer = null;
};
const die = (msg) => {
  console.error(`\n✗ ${msg}\n`);
  stopServer();
  process.exit(1);
};
for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, () => {
    stopServer();
    process.exit(130);
  });
}

// Mirror App.tsx estimateMs EXACTLY (silent / missing-audio fallback).
const estimateMs = (text) =>
  !text ? 1500 : Math.max(1500, text.length * 250);

// ── ffmpeg / ffprobe helpers ───────────────────────────────────────────
function sh(cmd, cmdArgs, { allowFail = false } = {}) {
  const r = spawnSync(cmd, cmdArgs, { encoding: "utf8", maxBuffer: 1 << 26 });
  if (r.error) {
    if (r.error.code === "ENOENT") die(`'${cmd}' not found in PATH.`);
    if (!allowFail) die(`${cmd} failed: ${r.error.message}`);
  }
  if (r.status !== 0 && !allowFail) {
    die(`${cmd} exited ${r.status}\n${(r.stderr || "").slice(-2000)}`);
  }
  return r;
}

function preflightFfmpeg() {
  sh("ffmpeg", ["-version"]);
  sh("ffprobe", ["-version"]);
}

function ffprobeDurationMs(file) {
  const r = sh(
    "ffprobe",
    [
      "-v", "error",
      "-show_entries", "format=duration",
      "-of", "default=nw=1:nk=1",
      file,
    ],
    { allowFail: true },
  );
  const sec = parseFloat((r.stdout || "").trim());
  return Number.isFinite(sec) && sec > 0 ? Math.round(sec * 1000) : 0;
}

// ── dev server (optional) ────────────────────────────────────────────────
async function waitForServer(url, timeoutMs = 40000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(url, { method: "GET" });
      if (res.ok || res.status === 200) return true;
    } catch {
      /* not up yet */
    }
    await sleep(300);
  }
  return false;
}

async function startDevServer() {
  console.log(`▸ starting dev server on :${PORT} …`);
  const child = spawn(
    "npm",
    ["run", "dev", "--", "--port", String(PORT), "--strictPort"],
    { cwd: ROOT, detached: true, stdio: ["ignore", "ignore", "inherit"] },
  );
  const url = `http://localhost:${PORT}`;
  const ok = await waitForServer(url);
  if (!ok) {
    try {
      process.kill(-child.pid, "SIGTERM");
    } catch {
      /* ignore */
    }
    die(`dev server did not come up on ${url} within timeout.`);
  }
  console.log(`  ✓ server up at ${url}`);
  return {
    url,
    stop() {
      try {
        process.kill(-child.pid, "SIGTERM");
      } catch {
        /* ignore */
      }
    },
  };
}

// ── playwright launch (system Chrome first) ──────────────────────────────
async function launchBrowser() {
  let chromium;
  try {
    ({ chromium } = await import("playwright"));
  } catch {
    die(
      "playwright is not installed. Run:\n" +
        "    npm i -D playwright\n" +
        "  It drives your system Chrome (no browser download needed).",
    );
  }
  const headless = !HEADED;
  // Prefer the user's system Chrome — zero extra download.
  try {
    const b = await chromium.launch({ channel: "chrome", headless });
    console.log("▸ browser: system Chrome (channel=chrome)");
    return b;
  } catch (e) {
    console.log(`  · system Chrome unavailable (${e.message.split("\n")[0]})`);
  }
  // Fall back to Playwright's bundled Chromium, if it's been installed.
  try {
    const b = await chromium.launch({ headless });
    console.log("▸ browser: Playwright bundled Chromium");
    return b;
  } catch {
    die(
      "no usable browser. Either install Google Chrome, or run:\n" +
        "    npx playwright install chromium",
    );
  }
}

// ── build per-step schedule from the page's own structure ────────────────
function buildSchedule(meta) {
  const schedule = [];
  meta.chapters.forEach((c, ci) => {
    c.steps.forEach((s, si) => {
      const text = (s.text ?? "").toString();
      const fileStep = si + 1; // 1-indexed, matches audio file naming
      const audioPath = join(ROOT, "public", "audio", c.id, `${fileStep}.mp3`);
      // Emptiness test mirrors App.tsx EXACTLY (stepText === "", not trimmed):
      // a whitespace-only narration is non-empty there, so if its mp3 exists
      // the runtime plays it — the recorder must too.
      const hasAudio = text !== "" && existsSync(audioPath);
      let holdMs;
      let audio = null;
      if (hasAudio) {
        const dur = ffprobeDurationMs(audioPath);
        if (dur > 0) {
          holdMs = dur + 200; // matches runtime trailMs
          audio = audioPath;
        } else {
          holdMs = estimateMs(text);
        }
      } else {
        holdMs = estimateMs(text);
      }
      schedule.push({ ci, si, chapterId: c.id, fileStep, text, holdMs, audio });
    });
  });
  return schedule;
}

// ── rebuild the audio track to match the schedule exactly ────────────────
function buildAudioTrack(schedule) {
  mkdirSync(SLOTS, { recursive: true });
  const listLines = [];
  let withAudio = 0;
  schedule.forEach((slot, i) => {
    const out = join(SLOTS, `slot-${String(i).padStart(4, "0")}.wav`);
    const durSec = (slot.holdMs / 1000).toFixed(3);
    if (slot.audio) {
      withAudio++;
      // speech + silence padding, truncated to EXACTLY holdMs (=dur+200ms),
      // normalized to a uniform pcm format so the concat demuxer is happy.
      sh("ffmpeg", [
        "-y", "-loglevel", "error", "-nostats",
        "-i", slot.audio,
        "-af", "apad",
        "-t", durSec,
        "-ar", "44100", "-ac", "2", "-c:a", "pcm_s16le",
        out,
      ]);
    } else {
      // silent slot of exactly holdMs (silent / missing-audio step).
      sh("ffmpeg", [
        "-y", "-loglevel", "error", "-nostats",
        "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
        "-t", durSec,
        "-c:a", "pcm_s16le",
        out,
      ]);
    }
    listLines.push(`file '${out.replace(/'/g, "'\\''")}'`);
  });
  const listFile = join(TMP, "audio-list.txt");
  writeFileSync(listFile, listLines.join("\n") + "\n", "utf8");
  const audioOut = join(TMP, "audio.wav");
  sh("ffmpeg", [
    "-y", "-loglevel", "error", "-nostats",
    "-f", "concat", "-safe", "0", "-i", listFile,
    "-c:a", "pcm_s16le",
    audioOut,
  ]);
  return { audioOut, withAudio };
}

// ── find where on-screen content begins (end of the black pre-roll) ──────
function detectContentStartSec(webm) {
  const r = sh(
    "ffmpeg",
    ["-i", webm, "-vf", "blackdetect=d=0.05:pix_th=0.03", "-an", "-f", "null", "-"],
    { allowFail: true },
  );
  const log = `${r.stderr || ""}`;
  // The FIRST black interval is the #000 pre-roll: with the strict pix_th the
  // blank/dark load period before it doesn't register as black, and real
  // chapter content (text/shapes on the surface) is never ~100% pure black for
  // a full frame, so nothing earlier is reported. Its end = where content
  // begins. (The pre-roll's start drifts with cold-load time — don't gate on
  // it; just trim at the first black_end.)
  const m = log.match(/black_start:[\d.]+\s+black_end:([\d.]+)/);
  if (m) {
    const end = parseFloat(m[1]);
    if (Number.isFinite(end)) return end;
  }
  return null;
}

// ── main ──────────────────────────────────────────────────────────────
async function main() {
  preflightFfmpeg();

  rmSync(TMP, { recursive: true, force: true });
  mkdirSync(TMP, { recursive: true });

  const server = URL_ARG ? null : await startDevServer();
  if (server) activeServer = server;
  const baseUrl = (URL_ARG || server.url).replace(/\/$/, "");
  const pageUrl = `${baseUrl}/?capture=1`;

  const browser = await launchBrowser();
  // Sampled just before recording begins; (paint - recStartT) is a safe
  // upper bound on where content sits in the webm (it over-counts by the
  // recordVideo startup latency), used to clamp the blackdetect trim.
  const recStartT = Date.now();
  const context = await browser.newContext({
    viewport: { width: 1920, height: 1080 },
    deviceScaleFactor: 1,
    recordVideo: { dir: TMP, size: { width: 1920, height: 1080 } },
  });
  const page = await context.newPage();

  console.log(`▸ loading ${pageUrl}`);
  await page.goto(pageUrl, { waitUntil: "load", timeout: 60000 });
  await page.waitForFunction(() => !!window.__capture?.ready, {
    timeout: 30000,
  });
  // Let webfonts settle so the first frames aren't a fallback-font flash.
  await page.waitForLoadState("networkidle", { timeout: 15000 }).catch(() => {});
  await page.evaluate(() => document.fonts?.ready).catch(() => {});

  const meta = await page.evaluate(() => window.__capture.meta());
  const schedule = buildSchedule(meta);
  if (schedule.length === 0) die("no steps found — is any chapter registered?");
  const totalMs = schedule.reduce((s, x) => s + x.holdMs, 0);
  const audioCount = schedule.filter((s) => s.audio).length;
  console.log(
    `▸ ${meta.chapters.length} chapters · ${schedule.length} steps · ` +
      `${audioCount} with audio · ~${(totalMs / 1000).toFixed(1)}s`,
  );
  if (audioCount === 0) {
    console.log(
      "  ! no mp3 found under public/audio — output will be SILENT with " +
        "estimated pacing. Run npm run synthesize-audio first for voiced video.",
    );
  }

  // Black pre-roll → release playback (mounts step 0) and wait for the first
  // content paint in ONE round-trip, so t0 hugs the paint instead of trailing
  // it by an extra evaluate's worth of frames.
  await sleep(BLACK_MS);
  await page.evaluate(
    () =>
      new Promise((r) => {
        window.__capture.start();
        requestAnimationFrame(() => requestAnimationFrame(() => r(true)));
      }),
  );
  const t0 = Date.now();
  const wallContentSec = (t0 - recStartT) / 1000;

  // start() mounts the cursor at (0,0). If the first real slot isn't (0,0)
  // — e.g. a leading zero-step chapter — jump to it so slot 0 shows the right
  // scene from the top.
  const first = schedule[0];
  if (first.ci !== 0 || first.si !== 0) {
    await page.evaluate(
      ([c, s]) => window.__capture.goto(c, s),
      [first.ci, first.si],
    );
  }

  // Drive each slot to its exact (chapter, step) via goto() on an absolute
  // clock. goto() keeps the recorder's cursor authoritative — no accumulating
  // drift, and immune to any zero-step chapter the stepper's next() would
  // otherwise land on (which would slip every later step out of sync).
  let cum = 0;
  for (let i = 0; i < schedule.length; i++) {
    cum += schedule[i].holdMs;
    const wait = t0 + cum - Date.now();
    if (wait > 0) await sleep(wait);
    const next = schedule[i + 1];
    if (next) {
      await page.evaluate(
        ([c, s]) => window.__capture.goto(c, s),
        [next.ci, next.si],
      );
    }
    process.stdout.write(`\r  recording step ${i + 1}/${schedule.length}   `);
  }
  process.stdout.write("\n");
  await sleep(TAIL_MS);

  const video = page.video();
  await context.close(); // finalizes the webm
  await browser.close();
  stopServer();

  const webm = await video.path();
  console.log("▸ rebuilding audio track …");
  const { audioOut } = buildAudioTrack(schedule);

  console.log("▸ trimming + encoding video …");
  // Where on-screen content begins. blackdetect is pixel-accurate when it
  // works, but a near-black theme surface can fool it into reporting a
  // black_end deep inside step 0 — which would trim away the opening frames
  // and shift the whole video ahead of the (schedule-anchored) audio. So clamp
  // it by wallContentSec, a safe upper bound on the true content position. If
  // blackdetect finds nothing (e.g. encoding lifted the #000 pre-roll), fall
  // back to the wall-clock estimate biased slightly early so we never eat
  // content.
  const bd = detectContentStartSec(webm);
  let ss;
  if (bd != null) {
    ss = Math.min(bd, wallContentSec);
  } else {
    ss = Math.max(0, wallContentSec - 0.2);
    console.log(
      "  ! black pre-roll not detected; using wall-clock trim estimate.",
    );
  }
  const totalSec = (totalMs / 1000).toFixed(3);
  const trimmed = join(TMP, "video-trim.mp4");
  // Accurate seek (-ss AFTER -i) so the trim lands frame-exact for sync.
  sh("ffmpeg", [
    "-y", "-loglevel", "error", "-nostats",
    "-i", webm,
    "-ss", String(ss),
    "-t", totalSec,
    "-an",
    "-c:v", "libx264", "-preset", "medium", "-crf", String(CRF),
    "-pix_fmt", "yuv420p", "-r", String(FPS), "-fps_mode", "cfr",
    trimmed,
  ]);

  mkdirSync(dirname(OUT), { recursive: true });
  sh("ffmpeg", [
    "-y", "-loglevel", "error", "-nostats",
    "-i", trimmed,
    "-i", audioOut,
    "-map", "0:v:0", "-map", "1:a:0",
    "-c:v", "copy",
    "-c:a", "aac", "-b:a", "192k",
    "-movflags", "+faststart",
    "-shortest",
    OUT,
  ]);

  if (!KEEP_TEMP) rmSync(TMP, { recursive: true, force: true });

  console.log(
    `\n✓ done → ${OUT}\n` +
      `  1920×1080 · ${FPS}fps · ~${totalSec}s · ` +
      `${audioCount}/${schedule.length} steps voiced` +
      (KEEP_TEMP ? `\n  (kept intermediates in ${TMP})` : ""),
  );
}

main().catch((err) => {
  die(err?.stack || err?.message || String(err));
});

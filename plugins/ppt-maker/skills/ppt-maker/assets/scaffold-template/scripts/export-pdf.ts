#!/usr/bin/env tsx
/* ─────────────────────────────────────────────────────────────────────
 * export-pdf.ts — deck.json → deck.pdf
 *
 * The third renderer, and the only one that doesn't walk the DSL itself:
 * it prints the HTML deck. That is the right call here — a PDF is a
 * picture of the deck, and the browser already knows how to make that
 * picture correctly, including every font and gradient PowerPoint can't
 * hold. Re-deriving it from the DSL would only introduce a third set of
 * rounding decisions.
 *
 * `?print=1` stacks all slides at exactly one PDF page each, so this is
 * a single print job rather than N files merged afterwards.
 *
 *   npm run export:pdf
 *   npm run export:pdf -- --out out/deck.pdf
 * ───────────────────────────────────────────────────────────────────── */

import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "..");
const DIST = path.join(ROOT, "dist-web");

const MIME: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript",
  ".css": "text/css",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".woff2": "font/woff2",
};

function parseOut(argv: string[]): string {
  const i = argv.indexOf("--out");
  if (i >= 0 && argv[i + 1]) return argv[i + 1];
  const inline = argv.find((a) => a.startsWith("--out="));
  return inline ? inline.slice(6) : "dist/deck.pdf";
}

function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : 0;
      server.close(() => resolve(port));
    });
    server.on("error", reject);
  });
}

function serve(port: number): http.Server {
  return http
    .createServer((req, res) => {
      const url = (req.url ?? "/").split("?")[0];
      const rel = url === "/" ? "/index.html" : url;
      const file = path.join(DIST, decodeURIComponent(rel));
      if (!file.startsWith(DIST) || !fs.existsSync(file)) {
        res.statusCode = 404;
        res.end("not found");
        return;
      }
      res.setHeader("content-type", MIME[path.extname(file)] ?? "application/octet-stream");
      fs.createReadStream(file).pipe(res);
    })
    .listen(port, "127.0.0.1");
}

function run(command: string, args: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: ROOT, stdio: "inherit", shell: false });
    child.on("exit", (code) =>
      code === 0 ? resolve() : reject(new Error(`${command} exited ${code}`)),
    );
  });
}

async function main(): Promise<void> {
  const out = path.isAbsolute(parseOut(process.argv))
    ? parseOut(process.argv)
    : path.join(ROOT, parseOut(process.argv));

  if (!fs.existsSync(path.join(DIST, "index.html"))) {
    console.log("▸ building the deck first…");
    await run("npm", ["run", "build"]);
  }

  const port = await freePort();
  const server = serve(port);

  // System Chrome rather than a downloaded browser: the deck's fonts are
  // whatever this machine has, and that is exactly what should end up in
  // the PDF.
  const browser = await chromium.launch({ channel: "chrome", headless: true });
  try {
    const page = await browser.newPage();
    await page.goto(`http://127.0.0.1:${port}/index.html?print=1`, {
      waitUntil: "networkidle",
    });
    await page.evaluate(() => document.fonts.ready);
    fs.mkdirSync(path.dirname(out), { recursive: true });
    await page.pdf({
      path: out,
      width: "13.3333in",
      height: "7.5in",
      printBackground: true,
      margin: { top: "0", right: "0", bottom: "0", left: "0" },
      pageRanges: "",
    });
  } finally {
    await browser.close();
    server.close();
  }

  const deck = JSON.parse(fs.readFileSync(path.join(ROOT, "deck.json"), "utf8"));
  console.log(`✓ ${out}\n  ${deck.slides.length} pages · 13.333in × 7.5in`);
}

main().catch((error) => {
  console.error(`✗ pdf export failed: ${error?.message ?? error}`);
  console.error("  needs a local Chrome (playwright-core drives channel:chrome).");
  process.exit(1);
});

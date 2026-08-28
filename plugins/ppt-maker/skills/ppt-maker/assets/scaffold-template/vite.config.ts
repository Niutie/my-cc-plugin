import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import react from "@vitejs/plugin-react";
import { defineConfig, type Plugin } from "vite";

/**
 * Lets the in-browser console write edits back to deck.json.
 *
 * deck.json is the single source of truth, so an edit made on screen
 * has to land THERE and nowhere else — otherwise the next `export:pptx`
 * silently ships the pre-edit deck. This endpoint exists only in dev;
 * a built deck is a read-only artefact.
 */
function deckWriter(): Plugin {
  return {
    name: "ppt-maker-deck-writer",
    apply: "serve",
    configureServer(server) {
      server.middlewares.use("/__deck", (req, res) => {
        if (req.method !== "POST") {
          res.statusCode = 405;
          res.end("POST only");
          return;
        }
        let body = "";
        req.on("data", (chunk) => {
          body += chunk;
        });
        req.on("end", () => {
          try {
            const deck = JSON.parse(body);
            const file = path.resolve(server.config.root, "deck.json");
            fs.writeFileSync(file, JSON.stringify(deck, null, 2) + "\n");
            res.setHeader("content-type", "application/json");
            res.end(JSON.stringify({ ok: true }));
          } catch (error) {
            res.statusCode = 400;
            res.end(String((error as Error)?.message ?? error));
          }
        });
      });
    },
  };
}

/**
 * Lets the console export a .pptx without leaving the browser.
 *
 * It shells out to the SAME `scripts/export-pptx.ts` the npm script runs
 * — not a second exporter. A browser-side exporter would need the whole
 * pptxgenjs path rebuilt without `fs`, and would then be a second
 * codepath that can drift from the one `verify:geometry` checks.
 *
 * Serve-only, like the writer above: the file lands in `dist/` exactly
 * where the CLI puts it, and the response streams the same bytes back so
 * the button also behaves like a download. A built deck has no server,
 * hence no button — see App.tsx.
 */
function deckExporter(): Plugin {
  return {
    name: "ppt-maker-deck-exporter",
    apply: "serve",
    configureServer(server) {
      server.middlewares.use("/__export", (req, res) => {
        if (req.method !== "POST") {
          res.statusCode = 405;
          res.end("POST only");
          return;
        }
        const root = server.config.root;
        const bin = path.join(
          root,
          "node_modules",
          ".bin",
          process.platform === "win32" ? "tsx.cmd" : "tsx",
        );
        if (!fs.existsSync(bin)) {
          res.statusCode = 500;
          res.end("找不到 node_modules/.bin/tsx —— 先跑 npm install");
          return;
        }

        const out = path.join(root, "dist", "deck.pptx");
        const child = spawn(bin, ["scripts/export-pptx.ts"], { cwd: root });
        let log = "";
        child.stdout.on("data", (chunk) => {
          log += chunk;
        });
        child.stderr.on("data", (chunk) => {
          log += chunk;
        });
        child.on("error", (error) => {
          res.statusCode = 500;
          res.end(`导出器起不来：${error.message}`);
        });
        child.on("close", (code) => {
          if (res.writableEnded) return;
          if (code !== 0) {
            res.statusCode = 500;
            res.end(log.trim() || `export:pptx exited ${code}`);
            return;
          }
          let bytes: Buffer;
          try {
            bytes = fs.readFileSync(out);
          } catch (error) {
            res.statusCode = 500;
            res.end(String((error as Error)?.message ?? error));
            return;
          }
          res.setHeader(
            "content-type",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
          );
          res.setHeader("content-disposition", 'attachment; filename="deck.pptx"');
          res.setHeader("content-length", String(bytes.byteLength));
          res.end(bytes);
        });
      });
    },
  };
}

export default defineConfig({
  // "./" so a built deck also opens straight from file:// — an offline
  // deck people can mail around is a first-class deliverable here.
  base: "./",
  plugins: [react(), deckWriter(), deckExporter()],
  server: { port: 5175 },
  build: { outDir: "dist-web" },
});

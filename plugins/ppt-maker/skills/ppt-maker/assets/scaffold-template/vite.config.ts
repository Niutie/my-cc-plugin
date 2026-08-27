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

export default defineConfig({
  // "./" so a built deck also opens straight from file:// — an offline
  // deck people can mail around is a first-class deliverable here.
  base: "./",
  plugins: [react(), deckWriter()],
  server: { port: 5175 },
  build: { outDir: "dist-web" },
});

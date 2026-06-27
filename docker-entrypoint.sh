#!/bin/sh
set -e

cd /app

STATE_DIR="${MICROFEED_STATE:-/app/data/.wrangler-state}"
mkdir -p "$STATE_DIR"

WRANGLER="npx --no-install wrangler"
PORT=3000
D1_DIR="$STATE_DIR/v3/d1/miniflare-D1DatabaseObject"

# Seed/verify the schema by applying ops/db/init.sql DIRECTLY to the SQLite file(s)
# that `wrangler pages dev` (Miniflare) created under --persist-to. We do NOT use
# `wrangler d1 execute`: the execute CLI derives the local DB filename from the
# database id differently than `pages dev` does, so they end up on two different
# files (the worker reads one, the seed writes the other → 'no such table: channels'
# 500). Writing straight into Miniflare's file, with the same better-sqlite3 the
# runtime bundles, removes all ambiguity. init.sql is idempotent (CREATE TABLE IF
# NOT EXISTS), so re-running on restart is safe.
seed_and_verify() {
  D1_DIR="$D1_DIR" node -e '
    const fs = require("fs");
    const path = require("path");
    const Database = require("better-sqlite3");
    const dir = process.env.D1_DIR;
    const sql = fs.readFileSync("ops/db/init.sql", "utf8");
    let files = [];
    try {
      files = fs.readdirSync(dir).filter(f => f.endsWith(".sqlite"))
        .map(f => path.join(dir, f));
    } catch (e) { /* dir not created yet */ }
    if (files.length === 0) { console.log("[microfeed] no D1 file yet"); process.exit(2); }
    let okAll = true;
    for (const f of files) {
      try {
        const db = new Database(f);
        db.exec(sql);
        const row = db.prepare(
          "SELECT name FROM sqlite_master WHERE type=\x27table\x27 AND name=\x27channels\x27"
        ).get();
        db.close();
        const ok = !!row;
        console.log("[microfeed] seeded " + path.basename(f) + " channels=" + ok);
        okAll = okAll && ok;
      } catch (e) {
        console.log("[microfeed] seed error on " + path.basename(f) + ": " + e.message);
        okAll = false;
      }
    }
    process.exit(okAll ? 0 : 1);
  '
}

echo "[microfeed] starting wrangler pages dev on 0.0.0.0:${PORT} ..."
$WRANGLER pages dev ./public \
  --ip 0.0.0.0 \
  --port "$PORT" \
  --persist-to "$STATE_DIR" \
  --compatibility-date 2025-03-14 &
SERVER_PID=$!

# Wait for the server to be listening (any HTTP response, incl. 500, means up).
i=0
CODE=000
while [ $i -lt 90 ]; do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/" 2>/dev/null || echo 000)
  [ "$CODE" != "000" ] && break
  i=$((i+1))
  sleep 1
done
echo "[microfeed] server responding (http=${CODE}) after ${i}s; seeding D1..."

# Miniflare lazily creates the D1 file on first DB access. Hit the home page once
# (it touches FEED_DB) so the file exists, then seed it. Retry a few times.
curl -s -o /dev/null "http://127.0.0.1:${PORT}/" 2>/dev/null || true
attempt=0
while [ $attempt -lt 10 ]; do
  if seed_and_verify; then
    echo "[microfeed] D1 schema verified (channels table present)."
    break
  fi
  attempt=$((attempt+1))
  echo "[microfeed] schema not ready (attempt ${attempt}) — touching DB + retrying..."
  curl -s -o /dev/null "http://127.0.0.1:${PORT}/" 2>/dev/null || true
  sleep 2
done

# Hand the foreground back to the server process.
wait "$SERVER_PID"

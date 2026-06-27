#!/bin/sh
set -e

cd /app

STATE_DIR="${MICROFEED_STATE:-/app/data/.wrangler-state}"
mkdir -p "$STATE_DIR"

WRANGLER="npx --no-install wrangler"
PORT=3000

seed_schema() {
  # Seed the local D1 schema (idempotent — init.sql uses CREATE TABLE IF NOT EXISTS).
  # Must share --persist-to with `pages dev` so the same local SQLite is written.
  echo "[microfeed] seeding local D1 (FEED_DB) schema..."
  $WRANGLER d1 execute FEED_DB --local --persist-to "$STATE_DIR" --file ops/db/init.sql --yes 2>&1 \
    || $WRANGLER d1 execute FEED_DB --local --persist-to "$STATE_DIR" --file ops/db/init.sql 2>&1 \
    || echo "[microfeed] WARN: d1 seed returned non-zero"
}

verify_schema() {
  # Returns 0 if the channels table exists in the local D1 pages dev is using.
  $WRANGLER d1 execute FEED_DB --local --persist-to "$STATE_DIR" \
    --command "SELECT name FROM sqlite_master WHERE type='table' AND name='channels';" 2>/dev/null \
    | grep -q channels
}

# Start the Pages dev server (Miniflare) in the background so we can seed the
# SAME local D1 instance it provisions, then verify the schema landed.
echo "[microfeed] starting wrangler pages dev on 0.0.0.0:${PORT} ..."
$WRANGLER pages dev ./public \
  --d1 FEED_DB \
  --ip 0.0.0.0 \
  --port "$PORT" \
  --persist-to "$STATE_DIR" \
  --compatibility-date 2025-03-14 &
SERVER_PID=$!

# Wait for the server to be listening (any HTTP response, incl. 500, means up).
i=0
while [ $i -lt 90 ]; do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/" 2>/dev/null || echo 000)
  [ "$CODE" != "000" ] && break
  i=$((i+1))
  sleep 1
done
echo "[microfeed] server responding (http=${CODE}) after ${i}s; seeding D1..."

# Seed, then verify; retry once if the first seed didn't land.
seed_schema
if ! verify_schema; then
  echo "[microfeed] schema not visible yet — retrying seed..."
  sleep 2
  seed_schema
fi
if verify_schema; then
  echo "[microfeed] D1 schema verified (channels table present)."
else
  echo "[microfeed] WARN: channels table still not visible after seeding."
fi

# Hand the foreground back to the server process.
wait "$SERVER_PID"

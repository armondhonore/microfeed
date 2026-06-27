#!/bin/sh
set -e

cd /app

STATE_DIR="${MICROFEED_STATE:-/app/data/.wrangler-state}"
mkdir -p "$STATE_DIR"

WRANGLER="npx --no-install wrangler"

# Seed the local D1 schema (idempotent: init.sql uses CREATE TABLE IF NOT EXISTS).
# --persist-to must match the dev server so the seeded tables are visible.
echo "[microfeed] seeding local D1 (FEED_DB) schema..."
$WRANGLER d1 execute FEED_DB --local --persist-to "$STATE_DIR" --file ops/db/init.sql --yes \
  || $WRANGLER d1 execute FEED_DB --local --persist-to "$STATE_DIR" --file ops/db/init.sql \
  || echo "[microfeed] d1 seed step returned non-zero (continuing; tables may already exist)"

echo "[microfeed] starting wrangler pages dev on 0.0.0.0:3000 ..."
exec $WRANGLER pages dev ./public \
  --d1 FEED_DB \
  --ip 0.0.0.0 \
  --port 3000 \
  --persist-to "$STATE_DIR" \
  --compatibility-date 2025-03-14

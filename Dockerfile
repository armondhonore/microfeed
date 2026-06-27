# microfeed self-host on Nexlayer
# microfeed is a Cloudflare Pages app (D1 + R2 + Pages Functions). We self-host it
# by running the Pages Functions under Wrangler/Miniflare, which simulates D1 (local
# SQLite) and serves the functions on an HTTP port. The home feed render only needs
# D1; R2 is for media presigned URLs (admin uploads).

FROM node:22-bookworm-slim AS builder
WORKDIR /app

# Install deps. The repo uses yarn (berry); corepack ships with Node 22.
RUN corepack enable && corepack prepare yarn@stable --activate
COPY . .
# yarn install (node-modules linker via .yarnrc.yml) — devDependencies (incl. wrangler)
# are required at runtime, so force a full, non-immutable install. Then build client assets.
RUN YARN_ENABLE_IMMUTABLE_INSTALLS=false yarn install
RUN NODE_ENV=production yarn build:production

FROM node:22-bookworm-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production

# curl is used by the entrypoint to wait for the server and is small.
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Bring the whole built app (functions/, edge-src/, public/ with compiled assets,
# node_modules incl. wrangler, ops/db/init.sql, wrangler.toml).
COPY --from=builder /app /app

# Persisted local state (D1 sqlite, R2 fs) lives on the mounted volume so data
# survives restarts.
ENV MICROFEED_STATE=/app/data/.wrangler-state
RUN mkdir -p /app/data

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 3000
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

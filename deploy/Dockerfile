# deploy/Dockerfile -- build from the repo root:  docker build -f deploy/Dockerfile .
# Stage 1: fetch pinned third-party assets (cached until vendor.lock changes)
FROM debian:bookworm-slim AS vendor
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/*
COPY deploy/vendor.sh deploy/vendor.lock /build/
RUN bash /build/vendor.sh /build/vendor.lock /static/vendor

# Stage 2: the app
FROM node:20-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends gosu && rm -rf /var/lib/apt/lists/*
WORKDIR /app

COPY server/code/package.json ./
RUN npm install --omit=dev --no-audit --no-fund
# the filesystem shim replaces the real daves3 (which talks to Amazon)
COPY deploy/daves3-shim/daves3.js node_modules/daves3/daves3.js

COPY server/code/rssnetwork.js server/code/emailtemplate.html ./
COPY deploy/make-config.js deploy/entrypoint.sh ./

# static tree: the client (copied, then patched) + vendored assets
COPY client/code/ static-src/client/
COPY --from=vendor /static/vendor/ static-src/vendor/
COPY deploy/patches/fonts.css static-src/vendor/fonts/fonts.css
COPY deploy/patches/overrides.js static-src/vendor/overrides.js
COPY deploy/patches/patch-client.sh /tmp/patch-client.sh
RUN bash /tmp/patch-client.sh /app/static-src && rm /tmp/patch-client.sh

EXPOSE 1452 1462
ENTRYPOINT ["/bin/bash", "/app/entrypoint.sh"]

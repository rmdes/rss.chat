# deploy/Dockerfile -- build from the repo root:  docker build -f deploy/Dockerfile .
# Stage 1: fetch pinned third-party assets (cached until vendor.lock changes)
FROM debian:bookworm-slim AS vendor
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/*
COPY deploy/vendor.sh deploy/vendor.lock /build/
RUN bash /build/vendor.sh /build/vendor.lock /static/vendor

# Stage 2: the app
# node 20 reached end of life in April 2026. Nothing here needs a toolchain:
# upstream pins better-sqlite3 as of v0.6.3 and that version ships prebuilt
# binaries, so npm install fetches one instead of compiling.
FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends gosu && rm -rf /var/lib/apt/lists/*
WORKDIR /app

COPY server/code/package.json ./
# davemail requires aws-sdk eagerly and builds an SES client as it loads, but this server
# always sends over SMTP -- 101mb of end-of-support v2 SDK for a path that cannot run here.
# The delete shares the install's layer; a later RUN would hide the files without
# reclaiming the space, since the earlier layer still carries them.
RUN npm install --omit=dev --no-audit --no-fund \
	&& rm -rf node_modules/aws-sdk
# the filesystem shim replaces the real daves3 (which talks to Amazon)
COPY deploy/daves3-shim/daves3.js node_modules/daves3/daves3.js
COPY deploy/aws-sdk-shim/aws-sdk.js deploy/aws-sdk-shim/package.json node_modules/aws-sdk/

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

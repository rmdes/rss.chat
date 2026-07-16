#!/bin/bash
#deploy/entrypoint.sh -- container entrypoint for the rsschat image
set -euo pipefail
cd /app

node make-config.js > config.json
node -e "JSON.parse (require ('fs').readFileSync ('config.json', 'utf8'))" || {
	echo "entrypoint: generated config.json is not valid JSON" >&2
	exit 1
}
echo "entrypoint: config.json generated for ${RSSCHAT_DOMAIN}"

mkdir -p data
mkdir -p /static
if [ -d /static ]; then #shared volume; caddy serves it read-only
	cp -a /app/static-src/. /static/
	echo "entrypoint: static tree synced to /static"
fi

# drop root: chown the volume mountpoints the node process writes to, then
# exec node as the unprivileged 'node' user shipped in the base image.
chown -R node:node /app/data /static

# daveappserver writes stats.json to cwd (/app, root-owned); as the node user it can only
# rewrite the file if it already exists and node owns it. Seed it with valid empty JSON.
if [ ! -f /app/stats.json ]; then
	echo '{}' > /app/stats.json
fi
chown node:node /app/stats.json

exec gosu node node rssnetwork.js

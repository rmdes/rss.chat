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
mkdir -p "${FEEDS_ROOT:-/feeds}"
if [ -d /static ]; then #shared volume; caddy serves it read-only
	cp -a /app/static-src/. /static/
	echo "entrypoint: static tree synced to /static"
fi

exec node rssnetwork.js

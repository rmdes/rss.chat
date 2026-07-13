#!/bin/bash
#deploy/pin-vendors.sh -- regenerate vendor.lock (and fonts assets) from live URLs.
#Run on demand when a pin needs refreshing; review the resulting diff deliberately.
set -euo pipefail
cd "$(dirname "$0")"
LOCK="vendor.lock"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

MANIFEST="
includes/jquery-1.9.1.min.js|https://s3.amazonaws.com/scripting.com/code/includes/jquery-1.9.1.min.js
includes/bootstrap.css|https://s3.amazonaws.com/scripting.com/code/includes/bootstrap.css
includes/bootstrap.min.js|https://s3.amazonaws.com/scripting.com/code/includes/bootstrap.min.js
includes/basic/code.js|https://s3.amazonaws.com/scripting.com/code/includes/basic/code.js
includes/basic/styles.css|https://s3.amazonaws.com/scripting.com/code/includes/basic/styles.css
fontawesome/css/all.css|https://s3.amazonaws.com/scripting.com/code/fontawesome/css/all.css
feedland/api.js|https://s3.amazonaws.com/scripting.com/code/feedland/home/dev/api.js
feedland/signupdialog.css|https://s3.amazonaws.com/scripting.com/code/feedland/home/dev/signupdialog.css
feedland/signupdialog.js|https://s3.amazonaws.com/scripting.com/code/feedland/home/dev/signupdialog.js
feedland/sockets.js|https://s3.amazonaws.com/scripting.com/code/feedland/home/sockets.js
concord/concord.js|https://s3.amazonaws.com/scripting.com/code/concord/testing/3.0.6/concord.js
concord/concordstyles.css|https://s3.amazonaws.com/scripting.com/code/concord/testing/3.0.6/concordstyles.css
fargo/outliner.js|https://s3.amazonaws.com/fargo.io/code/shared/outliner.js
fargo/markdownConverter.js|https://s3.amazonaws.com/fargo.io/code/markdownConverter.js
outlinedialog/code.js|https://s3.amazonaws.com/scripting.com/code/outlinedialog/code.js
outlinedialog/styles.css|https://s3.amazonaws.com/scripting.com/code/outlinedialog/styles.css
rsschat/feedlandsocket.js|https://s3.amazonaws.com/scripting.com/code/rsschat/feedlandsocket.js
turndown/turndown.js|https://cdn.jsdelivr.net/npm/turndown@7.1.1/dist/turndown.js
images/kittyStamp.png|https://imgs.scripting.com/2024/09/10/kittyStamp.png
"

: > "$LOCK.new"
pin () { # rel url
	local rel="$1" url="$2" out="$TMP/$1"
	mkdir -p "$(dirname "$out")"
	curl -fsSL --retry 3 -A "$UA" -o "$out" "$url"
	printf '%s  %s  %s\n' "$(sha256sum "$out" | awk '{print $1}')" "$rel" "$url" >> "$LOCK.new"
	echo "pinned $rel"
}

echo "$MANIFEST" | while IFS='|' read -r rel url; do
	[ -z "$rel" ] && continue
	pin "$rel" "$url"
done

# fontawesome webfonts: discover from all.css url(...) references (quoted or bare)
grep -oE 'url\("?\.\./webfonts/[^)"?#]+' "$TMP/fontawesome/css/all.css" | sed -E 's|url\("?\.\./webfonts/||' | sort -u | while read -r f; do
	pin "fontawesome/webfonts/$f" "https://s3.amazonaws.com/scripting.com/code/fontawesome/webfonts/$f"
done

# google fonts: fetch css with a modern UA, pin the woff2 files, author a local fonts.css
FONTCSS="$TMP/fonts.css.src"
curl -fsSL -A "$UA" "https://fonts.googleapis.com/css2?family=Ubuntu:ital,wght@0,300;0,400;0,500;0,700;1,300;1,400;1,500;1,700" > "$FONTCSS"
curl -fsSL -A "$UA" "https://fonts.googleapis.com/css?family=Archivo+Black" >> "$FONTCSS"
grep -oE 'https://fonts\.gstatic\.com/[^) ]+' "$FONTCSS" | sort -u | while read -r url; do
	pin "fonts/$(basename "$url")" "$url"
done
perl -pe 's~https://fonts\.gstatic\.com/\S*/([^/)\s]+)\)~/static/vendor/fonts/$1)~g' "$FONTCSS" > patches/fonts.css

mv "$LOCK.new" "$LOCK"
echo "pin-vendors: wrote $LOCK and patches/fonts.css -- review the diff, then commit"

#!/bin/bash
#deploy/patches/test-patch-client.sh -- patch a copy of the real client, assert results
set -euo pipefail
cd "$(dirname "$0")"
REPO_ROOT="$(cd ../.. && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/static"
cp -a "$REPO_ROOT/client/code" "$TMP/static/client"
bash ./patch-client.sh "$TMP/static"

grep -qE "scripting\.com|amazonaws\.com|googleapis\.com|gstatic\.com|jsdelivr\.net" \
	"$TMP/static/client/index.html" "$TMP/static/client/globals.js" "$TMP/static/client/styles.css" \
	&& { echo "FAIL: external URLs remain"; exit 1; }
grep -q '/static/vendor/includes/jquery-1.9.1.min.js' "$TMP/static/client/index.html" || { echo "FAIL: jquery not rewritten"; exit 1; }
grep -q '/static/client/code.js' "$TMP/static/client/index.html" || { echo "FAIL: app code.js not rewritten"; exit 1; }
grep -q '/static/vendor/overrides.js' "$TMP/static/client/index.html" || { echo "FAIL: overrides not injected"; exit 1; }
grep -q '"/static/client/themes/"' "$TMP/static/client/globals.js" || { echo "FAIL: urlThemes not rewritten"; exit 1; }
grep -q '/static/vendor/images/kittyStamp.png' "$TMP/static/client/globals.js" || { echo "FAIL: default avatar not rewritten"; exit 1; }
# untouched repo check: the working tree must be clean of client/ changes
git -C "$REPO_ROOT" status --porcelain client/ | grep -q . && { echo "FAIL: repo client/ was modified"; exit 1; }
echo "test-patch-client: OK"

#!/bin/bash
#deploy/test-vendor.sh -- offline test for vendor.sh using file:// urls
set -euo pipefail
cd "$(dirname "$0")"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo -n "hello vendor" > "$TMP/asset.js"
GOOD=$(sha256sum "$TMP/asset.js" | awk '{print $1}')
BAD="0000000000000000000000000000000000000000000000000000000000000000"

printf '# comment line\n%s  sub/dir/asset.js  file://%s\n' "$GOOD" "$TMP/asset.js" > "$TMP/good.lock"
bash ./vendor.sh "$TMP/good.lock" "$TMP/out"
[ "$(cat "$TMP/out/sub/dir/asset.js")" = "hello vendor" ] || { echo "FAIL: content wrong"; exit 1; }

printf '%s  sub/asset.js  file://%s\n' "$BAD" "$TMP/asset.js" > "$TMP/bad.lock"
if bash ./vendor.sh "$TMP/bad.lock" "$TMP/out2" 2>/dev/null; then
	echo "FAIL: hash mismatch did not fail the build"; exit 1
fi
echo "test-vendor: OK"

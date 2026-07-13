#!/bin/bash
#deploy/vendor.sh -- fetch pinned third-party assets. Strict: any mismatch fails.
#Usage: vendor.sh <lockfile> <destdir>
set -euo pipefail
LOCK="$1"; DEST="$2"
while read -r sha rel url; do
	[ -z "${sha:-}" ] && continue
	case "$sha" in \#*) continue;; esac
	out="$DEST/$rel"
	mkdir -p "$(dirname "$out")"
	curl -fsSL --retry 3 -o "$out" "$url"
	actual=$(sha256sum "$out" | awk '{print $1}')
	if [ "$actual" != "$sha" ]; then
		echo "vendor.sh: HASH MISMATCH for $url" >&2
		echo "  pinned:  $sha" >&2
		echo "  fetched: $actual" >&2
		echo "  If upstream changed deliberately, re-run deploy/pin-vendors.sh and review the diff." >&2
		exit 1
	fi
	echo "vendored $rel"
done < "$LOCK"

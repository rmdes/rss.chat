#!/bin/bash
#deploy/patches/patch-client.sh -- rewrite CDN URLs in the COPIED client tree.
#Usage: patch-client.sh <staticdir>  (expects <staticdir>/client, <staticdir>/vendor)
#Never run against the repo itself; the Docker build runs it on a copy.
set -euo pipefail
S="$1"
IDX="$S/client/index.html"
GLB="$S/client/globals.js"
CSS="$S/client/styles.css"

rep () { # file, exact-from, to -- fails loudly when upstream drifted
	local f="$1"; export FROM="$2" TO="$3"
	grep -qF -- "$FROM" "$f" || { echo "patch-client: NOT FOUND in $f: $FROM" >&2; exit 1; }
	perl -pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$f"
}

# third-party includes -> /static/vendor (cache-buster ?x= queries stay; harmless on static files)
rep "$IDX" "//s3.amazonaws.com/scripting.com/code/fontawesome/webfonts/fa-solid-900.woff2" "/static/vendor/fontawesome/webfonts/fa-solid-900.woff2"
rep "$IDX" "//s3.amazonaws.com/scripting.com/code/includes/jquery-1.9.1.min.js" "/static/vendor/includes/jquery-1.9.1.min.js"
rep "$IDX" "//s3.amazonaws.com/scripting.com/code/includes/bootstrap.css" "/static/vendor/includes/bootstrap.css"
rep "$IDX" "//s3.amazonaws.com/scripting.com/code/includes/bootstrap.min.js" "/static/vendor/includes/bootstrap.min.js"
rep "$IDX" "//s3.amazonaws.com/scripting.com/code/fontawesome/css/all.css" "/static/vendor/fontawesome/css/all.css"
rep "$IDX" "https://fonts.googleapis.com/css2?family=Ubuntu:ital,wght@0,300;0,400;0,500;0,700;1,300;1,400;1,500;1,700" "/static/vendor/fonts/fonts.css"
rep "$IDX" "//s3.amazonaws.com/scripting.com/code/includes/basic/code.js" "/static/vendor/includes/basic/code.js"
rep "$IDX" "//s3.amazonaws.com/scripting.com/code/includes/basic/styles.css" "/static/vendor/includes/basic/styles.css"
rep "$IDX" "//s3.amazonaws.com/scripting.com/code/feedland/home/dev/api.js" "/static/vendor/feedland/api.js"
rep "$IDX" "//s3.amazonaws.com/scripting.com/code/feedland/home/dev/signupdialog.css" "/static/vendor/feedland/signupdialog.css"
rep "$IDX" "//s3.amazonaws.com/scripting.com/code/feedland/home/dev/signupdialog.js" "/static/vendor/feedland/signupdialog.js"
rep "$IDX" "//s3.amazonaws.com/scripting.com/code/concord/testing/3.0.6/concord.js" "/static/vendor/concord/concord.js"
rep "$IDX" "//s3.amazonaws.com/scripting.com/code/concord/testing/3.0.6/concordstyles.css" "/static/vendor/concord/concordstyles.css"
rep "$IDX" "//s3.amazonaws.com/fargo.io/code/shared/outliner.js" "/static/vendor/fargo/outliner.js"
rep "$IDX" "//s3.amazonaws.com/scripting.com/code/outlinedialog/code.js" "/static/vendor/outlinedialog/code.js"
rep "$IDX" "//s3.amazonaws.com/scripting.com/code/outlinedialog/styles.css" "/static/vendor/outlinedialog/styles.css"
rep "$IDX" "//s3.amazonaws.com/scripting.com/code/feedland/home/sockets.js" "/static/vendor/feedland/sockets.js"
rep "$IDX" "//s3.amazonaws.com/scripting.com/code/rsschat/feedlandsocket.js" "/static/vendor/rsschat/feedlandsocket.js"
rep "$IDX" "//s3.amazonaws.com/fargo.io/code/markdownConverter.js" "/static/vendor/fargo/markdownConverter.js"
rep "$IDX" "https://cdn.jsdelivr.net/npm/turndown@7.1.1/dist/turndown.js" "/static/vendor/turndown/turndown.js"

# the app's own client files -> /static/client
rep "$IDX" "https://code.scripting.com/rsschat/globals.js" "/static/client/globals.js"
rep "$IDX" "//s3.amazonaws.com/scripting.com/code/rsschat/misc.js" "/static/client/misc.js"
rep "$IDX" "https://code.scripting.com/rsschat/api.js" "/static/client/api.js"
rep "$IDX" "https://code.scripting.com/rsschat/styles.css" "/static/client/styles.css"
rep "$IDX" "https://code.scripting.com/rsschat/code.js" "/static/client/code.js"

# overrides last in head, so its definitions win
rep "$IDX" "</head>" "<script src=\"/static/vendor/overrides.js\"></script></head>"

# globals.js: themes served from the image; default avatar vendored
rep "$GLB" "//s3.amazonaws.com/scripting.com/code/rsschat/themes/" "/static/client/themes/"
rep "$GLB" "https://imgs.scripting.com/2024/09/10/kittyStamp.png" "/static/vendor/images/kittyStamp.png"

# styles.css: Archivo Black comes from the vendored fonts.css
rep "$CSS" "@import url('https://fonts.googleapis.com/css?family=Archivo+Black');" "/* Archivo Black is vendored via /static/vendor/fonts/fonts.css */"

# Nothing the browser fetches may still point off-instance. An <a href> is not a
# fetch -- it is a link the reader may click, and upstream's Docs menu links out to
# source.scripting.com and github on purpose -- so anchors are allowed through while
# src=, <link href=, @import and url() are not.
if grep -nE "scripting\.com|amazonaws\.com|googleapis\.com|gstatic\.com|jsdelivr\.net" "$IDX" "$GLB" "$CSS" | grep -vE "<a [^>]*href="; then
	echo "patch-client: external URLs remain in something the page loads (see above)" >&2
	exit 1
fi
echo "patch-client: OK"

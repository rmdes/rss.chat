# rss.chat Self-Contained Docker Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `docker compose up -d` deployment of rss.chat with zero runtime dependence on Amazon or scripting.com, built entirely from an overlay in `deploy/` that never modifies upstream files.

**Architecture:** Four services (rsschat app built from this repo, MySQL 8, Caddy, MailPit). Feeds are written by a filesystem shim that replaces the `daves3` npm package inside the image and are served as static files by Caddy at `/feeds/*`. The client and its ~20 CDN includes are vendored at image build time (sha256-pinned), URL-rewritten copies served at `/static/*`; `index.html` is served by daveappserver from a local path so its `[%macro%]` substitution keeps working.

**Tech Stack:** bash, Node 20 (node:test for JS units), Docker/BuildKit, Docker Compose, Caddy 2, MySQL 8.0, MailPit.

**Spec:** `docs/superpowers/specs/2026-07-13-rsschat-docker-deploy-design.md`

## Global Constraints

- **Never modify or commit changes to any file under `client/` or `server/`.** All new files live in `deploy/` (and this plan/spec under `docs/`). Patches are applied to *copies* inside the Docker build, never to the repo.
- Vendor pinning is **strict sha256**: a hash mismatch fails the build.
- JS files that sit in the Winer runtime (the daves3 shim, make-config.js) follow his style: tabs, space before parens, `fl` boolean prefixes, callbacks.
- Shell scripts: `#!/bin/bash` + `set -euo pipefail`.
- Fixed ports: app HTTP 1452, app websocket 1462 (inside the network; only Caddy publishes 80/443).
- Service names (used in configs and scripts): `rsschat`, `mysql`, `caddy`, `mailpit`.
- Compose is run **from the `deploy/` directory**; `.env` lives there.
- Feed URL shape: `https://DOMAIN/feeds/users/{name}/rss.xml`, everyone feed `https://DOMAIN/feeds/users/rss.xml`, comments `https://DOMAIN/feeds/users/{name}/comments/{id}.xml`, OPML `https://DOMAIN/feeds/subs.opml`.
- Deviation from spec (simpler, same outcome): instead of the shim stripping upstream S3 prefixes, the generated `config.json` sets `rssS3Path: "/users/"` and `opmlS3Path: "/subs.opml"`, so the shim is a pure sanitize-join-write. Also: the everyone-feed channel image URL (`imgs.scripting.com/.../loveRss.png`) is hardcoded in `server/code/rssnetwork.js` which we do not modify — it remains in feed XML as cosmetic metadata; the instance never fetches it.
- Commit after every task, meaningful message, ending with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: daves3 filesystem shim

**Files:**
- Create: `deploy/daves3-shim/daves3.js`
- Test: `deploy/daves3-shim/test.js`

**Interfaces:**
- Consumes: env var `FEEDS_ROOT` (default `/feeds`), read at module load.
- Produces: module exporting `newObject (path, data, type, acl, callback)` with callback `(err, data)` — the only daves3 function upstream calls (`rssnetwork.js`: `updateFeedsOnS3` ×2, `publishCommentsFeed`, `updateSubscriptionListOnS3`). Any other property access throws `Error` matching `/unimplemented/`.

- [ ] **Step 1: Write the failing test**

```javascript
//deploy/daves3-shim/test.js -- run with: node --test deploy/daves3-shim/
const test = require ("node:test");
const assert = require ("node:assert");
const fs = require ("fs");
const path = require ("path");
const os = require ("os");

const feedsRoot = fs.mkdtempSync (path.join (os.tmpdir (), "feeds-shim-test-"));
process.env.FEEDS_ROOT = feedsRoot;
const daves3 = require ("./daves3.js");

test ("newObject writes the file under FEEDS_ROOT, creating folders", function (t, done) {
	daves3.newObject ("/users/dave/rss.xml", "<rss/>", "text/xml", "public-read", function (err, data) {
		assert.strictEqual (err, undefined);
		const written = fs.readFileSync (path.join (feedsRoot, "users/dave/rss.xml"), "utf8");
		assert.strictEqual (written, "<rss/>");
		done ();
		});
	});
test ("newObject overwrites an existing file", function (t, done) {
	daves3.newObject ("/subs.opml", "v1", "text/xml", "public-read", function (err) {
		assert.strictEqual (err, undefined);
		daves3.newObject ("/subs.opml", "v2", "text/xml", "public-read", function (err) {
			assert.strictEqual (err, undefined);
			assert.strictEqual (fs.readFileSync (path.join (feedsRoot, "subs.opml"), "utf8"), "v2");
			done ();
			});
		});
	});
test ("newObject rejects a path that escapes the feeds root", function (t, done) {
	daves3.newObject ("/../evil.xml", "x", "text/xml", "public-read", function (err) {
		assert.ok (err !== undefined);
		assert.match (err.message, /escapes/);
		assert.ok (!fs.existsSync (path.join (feedsRoot, "..", "evil.xml")));
		done ();
		});
	});
test ("any other daves3 call throws loudly", function () {
	assert.throws (function () {
		return (daves3.getObject);
		}, /unimplemented/);
	});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test deploy/daves3-shim/`
Expected: FAIL — `Cannot find module './daves3.js'`

- [ ] **Step 3: Write the implementation**

```javascript
//deploy/daves3-shim/daves3.js -- drop-in replacement for the daves3 package.
//Part of the deploy overlay, not upstream code. Writes "S3 objects" to a local
//folder instead of Amazon; Caddy serves that folder at /feeds/*.
//rssnetwork.js only ever calls newObject. Anything else throws, loudly, so an
//upstream change surfaces as an error instead of silent data loss.

const fs = require ("fs");
const path = require ("path");

const feedsRoot = path.resolve (process.env.FEEDS_ROOT || "/feeds");

function newObject (s3path, data, type, acl, callback) {
	try {
		const relpath = String (s3path).replace (/^\/+/, "");
		const resolved = path.resolve (path.join (feedsRoot, relpath));
		if (!resolved.startsWith (feedsRoot + path.sep)) {
			throw (new Error ("daves3 shim: path escapes the feeds root: " + s3path));
			}
		fs.mkdirSync (path.dirname (resolved), {recursive: true});
		const tmppath = resolved + ".tmp-" + process.pid; //atomic publish: write then rename
		fs.writeFileSync (tmppath, data);
		fs.renameSync (tmppath, resolved);
		if (callback !== undefined) {
			callback (undefined, {location: resolved});
			}
		}
	catch (err) {
		if (callback !== undefined) {
			callback (err);
			}
		}
	}

module.exports = new Proxy ({newObject}, {
	get: function (target, prop) {
		if (typeof prop === "symbol") {
			return (undefined);
			}
		if (prop in target) { //includes Object.prototype (toString etc), which keeps introspection happy
			return (target [prop]);
			}
		if ((prop === "then") || (prop === "inspect")) { //async/console probes
			return (undefined);
			}
		throw (new Error ("daves3 shim: unimplemented call \"" + prop + "\" -- upstream now uses more of daves3 than newObject."));
		}
	});
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test deploy/daves3-shim/`
Expected: `# pass 4`, `# fail 0`

- [ ] **Step 5: Commit**

```bash
git add deploy/daves3-shim/
git commit -m "$(printf 'deploy: daves3 filesystem shim\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 2: config.json generator

**Files:**
- Create: `deploy/make-config.js`
- Test: `deploy/test-make-config.js`

**Interfaces:**
- Consumes: env vars `RSSCHAT_DOMAIN` (required), `MYSQL_PASSWORD` (required), `PRODUCT_NAME`, `WHITELIST`, `RSSCLOUD_ENABLED`, `MYSQL_HOST/DATABASE/USER`, `SMTP_HOST/PORT/USERNAME/PASSWORD`, `MAIL_SENDER`, `HOMEPAGE_PATH`.
- Produces: complete rss.chat `config.json` on stdout; exit code 1 with message on stderr when a required var is missing. Task 5's entrypoint runs `node make-config.js > config.json`.

- [ ] **Step 1: Write the failing test**

```javascript
//deploy/test-make-config.js -- run with: node --test deploy/test-make-config.js
const test = require ("node:test");
const assert = require ("node:assert");
const child = require ("child_process");
const path = require ("path");

const script = path.join (__dirname, "make-config.js");
function run (env) {
	return (child.spawnSync (process.execPath, [script], {env: Object.assign ({}, process.env, env), encoding: "utf8"}));
	}
const goodEnv = {RSSCHAT_DOMAIN: "chat.example.com", MYSQL_PASSWORD: "s3cr3t"};

test ("produces valid json with domain-derived urls", function () {
	const result = run (goodEnv);
	assert.strictEqual (result.status, 0);
	const config = JSON.parse (result.stdout);
	assert.strictEqual (config.myDomain, "chat.example.com");
	assert.strictEqual (config.urlServerForClient, "https://chat.example.com/");
	assert.strictEqual (config.urlWebsocketServerForClient, "wss://chat.example.com/");
	assert.strictEqual (config.rssFeedUrl, "https://chat.example.com/feeds/users/");
	assert.strictEqual (config.opmlListUrl, "https://chat.example.com/feeds/subs.opml");
	assert.strictEqual (config.rssS3Path, "/users/");
	assert.strictEqual (config.opmlS3Path, "/subs.opml");
	assert.strictEqual (config.port, 1452);
	assert.strictEqual (config.websocketPort, 1462);
	assert.strictEqual (config.database.password, "s3cr3t");
	assert.strictEqual (config.database.host, "mysql");
	assert.strictEqual (config.smtpHost, "mailpit");
	assert.strictEqual (config.whitelist, undefined); //empty WHITELIST means open signup
	});
test ("whitelist csv becomes an array", function () {
	const result = run (Object.assign ({WHITELIST: " a@b.com, c@d.com "}, goodEnv));
	assert.deepStrictEqual (JSON.parse (result.stdout).whitelist, ["a@b.com", "c@d.com"]);
	});
test ("rsscloud can be disabled", function () {
	const result = run (Object.assign ({RSSCLOUD_ENABLED: "false"}, goodEnv));
	assert.strictEqual (JSON.parse (result.stdout).flRssCloudEnabled, false);
	});
test ("missing required vars fail with a message", function () {
	const result = run ({RSSCHAT_DOMAIN: "chat.example.com"});
	assert.strictEqual (result.status, 1);
	assert.match (result.stderr, /MYSQL_PASSWORD/);
	});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test deploy/test-make-config.js`
Expected: FAIL — make-config.js missing / status not 0.

- [ ] **Step 3: Write the implementation**

```javascript
//deploy/make-config.js -- generates rss.chat's config.json on stdout from env vars.
//Part of the deploy overlay, not upstream code.

function required (name) {
	const theValue = process.env [name];
	if ((theValue === undefined) || (theValue.length === 0)) {
		console.error ("make-config: " + name + " is required");
		process.exit (1);
		}
	return (theValue);
	}
function optional (name, theDefault) {
	const theValue = process.env [name];
	if ((theValue === undefined) || (theValue.length === 0)) {
		return (theDefault);
		}
	return (theValue);
	}

const domain = required ("RSSCHAT_DOMAIN");
const productName = optional ("PRODUCT_NAME", "rss.chat");

const config = {
	note: "Generated by deploy/make-config.js at container start. Do not edit; set env vars in deploy/.env instead.",
	port: 1452,
	flWebsocketEnabled: true,
	websocketPort: 1462,
	flSecureWebsocket: true, //TLS terminates at caddy; the client connects wss://
	urlWebsocketServerForClient: "wss://" + domain + "/",

	productName: productName,
	productNameForDisplay: productName,
	myDomain: domain,
	urlServerForClient: "https://" + domain + "/",
	urlServerForEmail: "https://" + domain + "/",
	pathServerHomePageSource: optional ("HOMEPAGE_PATH", "/app/static-src/client/index.html"),

	prefsPath: "data/prefs.json", //on the rsschat-data volume
	dataPath: "data/",

	mailSender: optional ("MAIL_SENDER", "rsschat@localhost"),
	confirmEmailSubject: productName + " confirmation",
	operationToConfirm: "sign in to " + productName,
	smtpHost: optional ("SMTP_HOST", "mailpit"),
	smtpPort: Number (optional ("SMTP_PORT", "1025")),
	smtpUsername: optional ("SMTP_USERNAME", ""),
	smtpPassword: optional ("SMTP_PASSWORD", ""),

	rssFeedUrl: "https://" + domain + "/feeds/users/",
	rssFilename: "rss.xml",
	rssS3Path: "/users/", //the daves3 shim writes under /feeds, so this lands at /feeds/users/
	opmlS3Path: "/subs.opml",
	opmlListUrl: "https://" + domain + "/feeds/subs.opml",
	flRssCloudEnabled: optional ("RSSCLOUD_ENABLED", "true") === "true",

	database: {
		host: optional ("MYSQL_HOST", "mysql"),
		port: 3306,
		user: optional ("MYSQL_USER", "rsschat"),
		password: required ("MYSQL_PASSWORD"),
		charset: "utf8mb4",
		connectionLimit: 100,
		database: optional ("MYSQL_DATABASE", "rsschat"),
		debug: false
		}
	};

const whitelist = optional ("WHITELIST", "");
if (whitelist.trim ().length > 0) {
	config.whitelist = whitelist.split (",").map (function (s) {
		return (s.trim ());
		}).filter (function (s) {
		return (s.length > 0);
		});
	}

console.log (JSON.stringify (config, undefined, "\t"));
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test deploy/test-make-config.js`
Expected: `# pass 4`, `# fail 0`

- [ ] **Step 5: Commit**

```bash
git add deploy/make-config.js deploy/test-make-config.js
git commit -m "$(printf 'deploy: env-driven config.json generator\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 3: vendor fetcher, pin generator, and pinned assets

**Files:**
- Create: `deploy/vendor.sh` (build-time, strict, offline-testable)
- Create: `deploy/pin-vendors.sh` (maintenance-time, network; regenerates the lock + fonts.css)
- Create: `deploy/patches/overrides.js`
- Generate + commit: `deploy/vendor.lock`, `deploy/patches/fonts.css`
- Test: `deploy/test-vendor.sh`

**Interfaces:**
- Consumes: network access to Dave's CDNs (pin script only).
- Produces: `vendor.sh LOCKFILE DESTDIR` populates DESTDIR with the exact relative paths Task 4's patch script points at (`includes/…`, `fontawesome/css|webfonts/…`, `feedland/…`, `concord/…`, `fargo/…`, `outlinedialog/…`, `rsschat/feedlandsocket.js`, `turndown/turndown.js`, `images/kittyStamp.png`, `fonts/*.woff2`). Lock line format: `<sha256><space><space><relative-dest><space><space><url>`; `#` comments and blank lines skipped. Exit 1 on any hash mismatch or fetch failure.

- [ ] **Step 1: Write the failing test (offline, file:// fixtures)**

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash deploy/test-vendor.sh`
Expected: FAIL — `vendor.sh: No such file or directory`

- [ ] **Step 3: Write vendor.sh**

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash deploy/test-vendor.sh`
Expected: `test-vendor: OK`

- [ ] **Step 5: Write pin-vendors.sh**

The manifest below is the complete external-URL surface of `client/code/index.html` and `globals.js` (verified by grep; theme files are clean, `chat.css` is not loaded). Cache-buster queries (`?x=1`) are dropped from fetch URLs.

```bash
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

# fontawesome webfonts: discover from all.css url(...) references
grep -oE 'url\(\.\./webfonts/[^)?#]+' "$TMP/fontawesome/css/all.css" | sed 's|url(\.\./webfonts/||' | sort -u | while read -r f; do
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
```

- [ ] **Step 6: Write overrides.js**

```javascript
//deploy/patches/overrides.js -- loaded last in index.html by the patch step.
//Later definitions win, so this neutralizes calls that phone home.
function hitCounter () { //the basic includes version pings Dave's stats server; a self-hosted instance doesn't
	}
```

- [ ] **Step 7: Generate the real pins (network required)**

Run: `bash deploy/pin-vendors.sh`
Expected: one `pinned …` line per asset (19 manifest entries + FontAwesome webfonts + font woff2 files), final line `pin-vendors: wrote vendor.lock and patches/fonts.css`. Inspect: `wc -l deploy/vendor.lock` ≥ 25; `head -3 deploy/vendor.lock` shows `hash  rel  url` triples; `grep -c gstatic deploy/patches/fonts.css` is 0 and `grep -c "/static/vendor/fonts/" deploy/patches/fonts.css` ≥ 8.

- [ ] **Step 8: Prove the lock round-trips through vendor.sh**

Run: `bash deploy/vendor.sh deploy/vendor.lock /tmp/vendor-check && ls /tmp/vendor-check/includes /tmp/vendor-check/fonts`
Expected: every asset vendors cleanly; jquery/bootstrap files and woff2 files listed.

- [ ] **Step 9: Commit**

```bash
git add deploy/vendor.sh deploy/pin-vendors.sh deploy/test-vendor.sh deploy/vendor.lock deploy/patches/overrides.js deploy/patches/fonts.css
git commit -m "$(printf 'deploy: vendor CDN assets with sha256 pinning\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 4: client patch script

**Files:**
- Create: `deploy/patches/patch-client.sh`
- Test: `deploy/patches/test-patch-client.sh`

**Interfaces:**
- Consumes: a directory `<staticdir>` containing `client/` (a copy of `client/code/`) and `vendor/` (Task 3 output plus `fonts/fonts.css`, `overrides.js`).
- Produces: `client/index.html`, `client/globals.js`, `client/styles.css` rewritten in place — all externals → `/static/vendor/…` or `/static/client/…`; `<script src="/static/vendor/overrides.js">` injected before `</head>`. Exits 1 if any expected string is absent (upstream drift) or any external URL survives.

- [ ] **Step 1: Write the failing test**

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash deploy/patches/test-patch-client.sh`
Expected: FAIL — `patch-client.sh: No such file or directory`

- [ ] **Step 3: Write patch-client.sh**

```bash
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

if grep -nE "scripting\.com|amazonaws\.com|googleapis\.com|gstatic\.com|jsdelivr\.net" "$IDX" "$GLB" "$CSS"; then
	echo "patch-client: external URLs remain (see above)" >&2
	exit 1
fi
echo "patch-client: OK"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash deploy/patches/test-patch-client.sh`
Expected: `patch-client: OK` then `test-patch-client: OK`

- [ ] **Step 5: Commit**

```bash
git add deploy/patches/patch-client.sh deploy/patches/test-patch-client.sh
git commit -m "$(printf 'deploy: build-time client URL rewrites\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 5: Dockerfile and entrypoint

**Files:**
- Create: `deploy/Dockerfile`
- Create: `deploy/Dockerfile.dockerignore`
- Create: `deploy/entrypoint.sh`

**Interfaces:**
- Consumes: repo-root build context; Tasks 1–4 files at their committed paths.
- Produces: image whose entrypoint generates `/app/config.json`, syncs `/app/static-src` → `/static` (volume), ensures `/app/data` and `/feeds`, then `exec node rssnetwork.js` with cwd `/app`. Listens 1452 (HTTP) and 1462 (ws). Compose (Task 6) builds it as service `rsschat`.

- [ ] **Step 1: Write entrypoint.sh**

```bash
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
```

- [ ] **Step 2: Write Dockerfile**

```dockerfile
# deploy/Dockerfile -- build from the repo root:  docker build -f deploy/Dockerfile .
# Stage 1: fetch pinned third-party assets (cached until vendor.lock changes)
FROM debian:bookworm-slim AS vendor
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/*
COPY deploy/vendor.sh deploy/vendor.lock /build/
RUN bash /build/vendor.sh /build/vendor.lock /static/vendor

# Stage 2: the app
FROM node:20-bookworm-slim
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
```

Note: `perl -pi` in patch-client.sh needs only `perl-base`, which Debian ships as essential — no extra install. If the build errors with `perl: not found`, add `perl-base` to an apt-get line in stage 2.

- [ ] **Step 3: Write Dockerfile.dockerignore**

```
# deploy/Dockerfile.dockerignore -- BuildKit picks this up for deploy/Dockerfile
.git
docs
examples
deploy/backups
```

- [ ] **Step 4: Build and smoke-test the image**

Run:
```bash
docker build -f deploy/Dockerfile -t rsschat:dev .
docker run --rm rsschat:dev bash -c "node --test /app 2>/dev/null; node -e \"process.env.FEEDS_ROOT='/tmp/f'; const s3=require('/app/node_modules/daves3/daves3.js'); s3.newObject('/users/x/rss.xml','<rss/>','text/xml','public-read',function(err){console.log(err?'ERR '+err.message:'shim ok')})\""
docker run --rm rsschat:dev bash -c "grep -c '/static/vendor/' /app/static-src/client/index.html && ls /app/static-src/vendor/fonts/fonts.css /app/static-src/vendor/overrides.js"
docker run --rm -e RSSCHAT_DOMAIN=x.test -e MYSQL_PASSWORD=pw rsschat:dev bash -c "cd /app && node make-config.js | head -3"
```
Expected: build succeeds ending `patch-client: OK`; `shim ok`; a count ≥ 20 and both files listed; JSON opening lines.

- [ ] **Step 5: Commit**

```bash
git add deploy/Dockerfile deploy/Dockerfile.dockerignore deploy/entrypoint.sh
git commit -m "$(printf 'deploy: rsschat image build and entrypoint\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 6: compose stack (Caddy, MySQL, MailPit, env, schema)

**Files:**
- Create: `deploy/docker-compose.yml`
- Create: `deploy/Caddyfile`
- Create: `deploy/db/init/01-schema.sql`
- Create: `deploy/db/conf/my.cnf`
- Create: `deploy/.env.example`
- Create: `deploy/.gitignore`

**Interfaces:**
- Consumes: the image from Task 5 (built via `build:`), env contract from Task 2.
- Produces: running stack; Caddy routes `/mail*`→mailpit:8025, websocket-upgrades→rsschat:1462, `/feeds/*`→feeds volume, `/static/*`→static volume, everything else→rsschat:1452. Volumes `feeds-data` and `static-data` are shared rsschat↔caddy. Task 8's e2e script runs against this stack.

- [ ] **Step 1: Write the schema (verbatim from `server/docs/install.md`)**

```sql
-- deploy/db/init/01-schema.sql -- from server/docs/install.md; database is created
-- by the MYSQL_DATABASE env var, so only the tables are defined here.
create table users (
	screenname varchar (255) not null,
	emailAddress varchar (255),
	emailSecret varchar (64),
	prefs json,
	ctHits int not null default 0,
	ctHitsToday int not null default 0,
	whenLastHit datetime,
	whenCreated datetime default current_timestamp,
	whenUpdated datetime default current_timestamp on update current_timestamp,
	primary key (screenname),
	index emailAddress (emailAddress)
	) character set utf8mb4 collate utf8mb4_unicode_ci;

create table items (
	id int unsigned not null auto_increment,
	feedUrl varchar (512),
	author varchar (255),
	inReplyTo int unsigned,
	title text,
	link text,
	description longtext,
	pubDate datetime,
	enclosureUrl text,
	enclosureType text,
	enclosureLength int,
	whenCreated datetime default current_timestamp,
	whenUpdated datetime default current_timestamp on update current_timestamp,
	markdowntext longtext,
	outlineJsontext text,
	flDeleted tinyint (1) not null default 0,
	primary key (id),
	index feedUrl (feedUrl),
	index author (author)
	) character set utf8mb4 collate utf8mb4_unicode_ci;

create table likes (
	screenname varchar (255),
	itemId int unsigned,
	whenCreated datetime default current_timestamp,
	primary key (screenname, itemId),
	index itemId (itemId)
	) character set utf8mb4 collate utf8mb4_unicode_ci;
```

- [ ] **Step 2: Write my.cnf**

```ini
# deploy/db/conf/my.cnf
[mysqld]
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
```

- [ ] **Step 3: Write the Caddyfile**

```
# deploy/Caddyfile
{$RSSCHAT_DOMAIN} {
	handle /mail* {
		reverse_proxy mailpit:8025
	}

	handle_path /feeds/* {
		root * /feeds
		@opml path *.opml
		header @opml Content-Type "text/xml; charset=utf-8"
		file_server
	}

	handle_path /static/* {
		root * /static
		file_server
	}

	@websockets {
		header Connection *Upgrade*
		header Upgrade websocket
	}
	handle @websockets {
		reverse_proxy rsschat:1462
	}

	handle {
		reverse_proxy rsschat:1452
	}
}
```

- [ ] **Step 4: Write docker-compose.yml**

```yaml
# deploy/docker-compose.yml -- run from the deploy/ directory
services:
  rsschat:
    build:
      context: ..
      dockerfile: deploy/Dockerfile
    container_name: rsschat
    depends_on:
      mysql:
        condition: service_healthy
    environment:
      RSSCHAT_DOMAIN: ${RSSCHAT_DOMAIN:?Set RSSCHAT_DOMAIN in .env}
      PRODUCT_NAME: ${PRODUCT_NAME:-rss.chat}
      WHITELIST: ${WHITELIST:-}
      RSSCLOUD_ENABLED: ${RSSCLOUD_ENABLED:-true}
      MYSQL_DATABASE: ${MYSQL_DATABASE:-rsschat}
      MYSQL_USER: ${MYSQL_USER:-rsschat}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD:?Set MYSQL_PASSWORD in .env}
      SMTP_HOST: ${SMTP_HOST:-mailpit}
      SMTP_PORT: ${SMTP_PORT:-1025}
      SMTP_USERNAME: ${SMTP_USERNAME:-}
      SMTP_PASSWORD: ${SMTP_PASSWORD:-}
      MAIL_SENDER: ${MAIL_SENDER:-rsschat@localhost}
      TZ: ${TZ:-UTC}
    volumes:
      - feeds-data:/feeds
      - static-data:/static
      - rsschat-data:/app/data
    healthcheck:
      test: ["CMD", "node", "-e", "require('http').get('http://localhost:1452/', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"]
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 30s
    deploy:
      resources:
        limits:
          memory: 512M
    restart: unless-stopped
    networks:
      - frontend
      - backend

  mysql:
    image: mysql:8.0
    container_name: rsschat-mysql
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD:?Set MYSQL_ROOT_PASSWORD in .env}
      MYSQL_DATABASE: ${MYSQL_DATABASE:-rsschat}
      MYSQL_USER: ${MYSQL_USER:-rsschat}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD:?Set MYSQL_PASSWORD in .env}
      TZ: ${TZ:-UTC}
    volumes:
      - mysql-data:/var/lib/mysql
      - ./db/init:/docker-entrypoint-initdb.d:ro
      - ./db/conf/my.cnf:/etc/mysql/conf.d/rsschat.cnf:ro
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 20
      start_period: 30s
    stop_grace_period: 30s
    deploy:
      resources:
        limits:
          memory: 1G
    restart: unless-stopped
    networks:
      - backend

  caddy:
    image: caddy:2-alpine
    container_name: rsschat-caddy
    depends_on:
      rsschat:
        condition: service_healthy
    environment:
      RSSCHAT_DOMAIN: ${RSSCHAT_DOMAIN:?Set RSSCHAT_DOMAIN in .env}
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - feeds-data:/feeds:ro
      - static-data:/static:ro
      - caddy-data:/data
      - caddy-config:/config
    restart: unless-stopped
    networks:
      - frontend

  mailpit:
    image: axllent/mailpit:latest
    container_name: rsschat-mailpit
    environment:
      MP_WEBROOT: /mail
    restart: unless-stopped
    networks:
      - frontend
      - backend

volumes:
  mysql-data:
  feeds-data:
  static-data:
  rsschat-data:
  caddy-data:
  caddy-config:

networks:
  frontend:
  backend:
```

- [ ] **Step 5: Write .env.example and .gitignore**

```bash
# deploy/.env.example -- copy to .env (or run scripts/generate-env.sh) and edit
RSSCHAT_DOMAIN=localhost
PRODUCT_NAME=rss.chat
# comma-separated emails allowed to sign up; empty = open signup
WHITELIST=
# ping rpc.rsscloud.io so subscribers get instant updates (outbound only)
RSSCLOUD_ENABLED=true
MYSQL_ROOT_PASSWORD=change-me
MYSQL_PASSWORD=change-me
MYSQL_DATABASE=rsschat
MYSQL_USER=rsschat
# mail: defaults to the built-in MailPit catcher (read at https://DOMAIN/mail).
# For real delivery set an SMTP relay + a MAIL_SENDER whose domain has SPF/DKIM for it.
SMTP_HOST=mailpit
SMTP_PORT=1025
SMTP_USERNAME=
SMTP_PASSWORD=
MAIL_SENDER=rsschat@localhost
TZ=UTC
```

```
# deploy/.gitignore
.env
backups/
```

- [ ] **Step 6: Validate and boot the stack**

Run:
```bash
cd deploy
cp .env.example .env   # localhost defaults; change-me passwords are fine for the smoke test
docker compose config -q && echo "compose: valid"
docker compose up -d --build
docker compose ps
```
Expected: `compose: valid`; all four services up, `rsschat` and `mysql` healthy (rsschat may take ~30s).

- [ ] **Step 7: Smoke-test routing**

Run:
```bash
curl -sk https://localhost/ | grep -o "<title>[^<]*</title>"
curl -sk -o /dev/null -w '%{http_code} %{content_type}\n' https://localhost/static/vendor/includes/jquery-1.9.1.min.js
curl -sk -o /dev/null -w '%{http_code}\n' https://localhost/mail/
curl -sk https://localhost/ | grep -c "scripting.com" || true
```
Expected: `<title>rss.chat</title>`; `200` with a javascript content type; `200`; final count `0` (no CDN URLs in the served homepage).

- [ ] **Step 8: Commit**

```bash
cd ..
git add deploy/docker-compose.yml deploy/Caddyfile deploy/db/ deploy/.env.example deploy/.gitignore
git commit -m "$(printf 'deploy: compose stack with caddy, mysql, mailpit\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 7: ops scripts

**Files:**
- Create: `deploy/scripts/generate-env.sh`
- Create: `deploy/scripts/backup.sh`
- Create: `deploy/scripts/migrate.sh`

**Interfaces:**
- Consumes: `deploy/.env`, running compose stack, service names `mysql`/`rsschat`.
- Produces: `.env` with random passwords; timestamped `db-*.sql.gz` + `feeds-*.tar.gz` under `deploy/backups/` (14 kept); `migrate.sh <file.sql>` applies SQL to the app database.

- [ ] **Step 1: Write generate-env.sh**

```bash
#!/bin/bash
#deploy/scripts/generate-env.sh -- create .env from .env.example with random passwords
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && { echo "generate-env: .env already exists, refusing to overwrite" >&2; exit 1; }
RP1=$(openssl rand -hex 24)
RP2=$(openssl rand -hex 24)
sed -e "s/^MYSQL_ROOT_PASSWORD=.*/MYSQL_ROOT_PASSWORD=$RP1/" \
    -e "s/^MYSQL_PASSWORD=.*/MYSQL_PASSWORD=$RP2/" \
    .env.example > .env
echo "generate-env: wrote .env -- edit RSSCHAT_DOMAIN (and SMTP_* for real mail) before deploying"
```

- [ ] **Step 2: Write backup.sh**

```bash
#!/bin/bash
#deploy/scripts/backup.sh -- dump the database and tar the feeds volume; keep 14 of each
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
STAMP=$(date +%Y%m%d-%H%M%S)
DEST="${1:-./backups}"
mkdir -p "$DEST"
docker compose exec -T mysql mysqldump -u"${MYSQL_USER:-rsschat}" -p"$MYSQL_PASSWORD" "${MYSQL_DATABASE:-rsschat}" | gzip > "$DEST/db-$STAMP.sql.gz"
docker compose exec -T rsschat tar -czf - -C /feeds . > "$DEST/feeds-$STAMP.tar.gz"
ls -t "$DEST"/db-*.sql.gz 2>/dev/null | tail -n +15 | xargs -r rm
ls -t "$DEST"/feeds-*.tar.gz 2>/dev/null | tail -n +15 | xargs -r rm
echo "backup: $DEST/db-$STAMP.sql.gz + feeds-$STAMP.tar.gz"
```

- [ ] **Step 3: Write migrate.sh**

```bash
#!/bin/bash
#deploy/scripts/migrate.sh -- apply a SQL migration file to the app database
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -eq 1 ] || { echo "usage: migrate.sh <migration.sql>" >&2; exit 1; }
set -a; source .env; set +a
docker compose exec -T mysql mysql -u"${MYSQL_USER:-rsschat}" -p"$MYSQL_PASSWORD" "${MYSQL_DATABASE:-rsschat}" < "$1"
echo "migrate: applied $1"
```

- [ ] **Step 4: Test against the running stack**

Run:
```bash
chmod +x deploy/scripts/*.sh
bash deploy/scripts/backup.sh
ls -la deploy/backups/
echo "select 1;" > /tmp/noop.sql && bash deploy/scripts/migrate.sh /tmp/noop.sql
```
Expected: `backup: …` with both archives present and non-empty; `migrate: applied /tmp/noop.sql`.

- [ ] **Step 5: Commit**

```bash
git add deploy/scripts/
git commit -m "$(printf 'deploy: ops scripts (env, backup, migrate)\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 8: end-to-end test script

**Files:**
- Create: `deploy/scripts/e2e-test.sh`

**Interfaces:**
- Consumes: running stack on `RSSCHAT_DOMAIN=localhost` with **empty WHITELIST** and `RSSCLOUD_ENABLED=false` in `.env` (restart stack after changing); MailPit JSON API at `/mail/api/v1/…`; the repo's `examples/threadwalker`.
- Produces: exit 0 with `E2E: ALL CHECKS PASSED`, or exit 1 naming the failed check. This script is the spec's verification plan, automated (spec items 2–7; item 8 backup/restore is Task 7 + README).

- [ ] **Step 1: Write e2e-test.sh**

```bash
#!/bin/bash
#deploy/scripts/e2e-test.sh -- full posting flow against a local stack (RSSCHAT_DOMAIN=localhost)
#Signup happens via the magic link pulled from MailPit's API -- the same path a human takes.
set -euo pipefail
cd "$(dirname "$0")/.."
BASE="https://localhost"
C () { curl -sk "$@"; }
EMAIL="e2e-$(date +%s)@example.com"
NAME="e2e$(date +%s)"
fail () { echo "E2E FAIL: $*" >&2; exit 1; }
jsonget () { node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const v=JSON.parse(s)$1;console.log(v===undefined?'':v)})"; }

echo "-- 1 sign up ($NAME)"
C "$BASE/createnewuser?email=$EMAIL&name=$NAME&urlredirect=$BASE/" > /dev/null
sleep 2

echo "-- 2 magic link from mailpit"
MSGID=$(C "$BASE/mail/api/v1/messages?limit=1" | jsonget ".messages[0].ID")
[ -n "$MSGID" ] || fail "no message in mailpit"
LINK=$(C "$BASE/mail/api/v1/message/$MSGID" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const m=JSON.parse(s);const t=(m.Text||'')+' '+(m.HTML||'');const x=t.match(/https?:\/\/[^\s\"'<>]+/g)||[];console.log(x.find(u=>u.includes('confirm'))||'')})")
[ -n "$LINK" ] || fail "no confirmation link in the email"

echo "-- 3 confirm; capture credentials from the redirect"
REDIR=$(C -o /dev/null -w '%{redirect_url}' "$LINK")
[ -n "$REDIR" ] || fail "confirmation did not redirect (inspect: curl -sk -i '$LINK')"
CODE=$(node -e "console.log(new URL(process.argv[1]).searchParams.get('code')||'')" "$REDIR")
SCREEN=$(node -e "console.log(new URL(process.argv[1]).searchParams.get('screenname')||'')" "$REDIR")
[ "$SCREEN" = "$NAME" ] || fail "screenname mismatch: got '$SCREEN'"
AUTH="emailaddress=$EMAIL&emailcode=$CODE"

echo "-- 4 post"
ID=$(C -G -X POST "$BASE/newpost?$AUTH" --data-urlencode 'jsontext={"description":"hello from the e2e test"}' | jsonget ".id")
[ -n "$ID" ] || fail "newpost returned no id"
sleep 1
C "$BASE/feeds/users/$NAME/rss.xml" | grep -q "hello from the e2e test" || fail "user feed missing the post"
C "$BASE/feeds/users/rss.xml"       | grep -q "hello from the e2e test" || fail "everyone feed missing the post"
C "$BASE/feeds/subs.opml"           | grep -q "$NAME" || fail "subs.opml missing the user"

echo "-- 5 reply -> comments feed"
RID=$(C -G -X POST "$BASE/newpost?$AUTH" --data-urlencode "jsontext={\"description\":\"a reply from e2e\",\"inReplyTo\":$ID}" | jsonget ".id")
[ -n "$RID" ] || fail "reply returned no id"
sleep 1
C "$BASE/feeds/users/$NAME/comments/$ID.xml" | grep -q "a reply from e2e" || fail "comments feed missing the reply"
C "$BASE/feeds/users/$NAME/rss.xml" | grep -q "source:comments" || fail "user feed missing source:comments"

echo "-- 6 like"
C -G -X POST "$BASE/togglelike?$AUTH" --data-urlencode "id=$ID" > /dev/null
LIKES=$(C "$BASE/getiteminfo?id=$ID&format=feedland&screenname=$NAME" | jsonget ".ctLikes")
[ "$LIKES" = "1" ] || fail "like count is '$LIKES', expected 1"

echo "-- 7 edit"
C -G -X POST "$BASE/updatepost?$AUTH" --data-urlencode "jsontext={\"id\":$ID,\"description\":\"hello edited by e2e\"}" > /dev/null
sleep 1
C "$BASE/feeds/users/$NAME/rss.xml" | grep -q "hello edited by e2e" || fail "edit not reflected in feed"

echo "-- 8 threadwalker walks our feeds"
TW=$(mktemp -d)
cp ../examples/threadwalker/walker.js ../examples/threadwalker/package.json "$TW/"
FROM="https://users.rss.network/manton/rss.xml" TO="$BASE/feeds/users/$NAME/rss.xml" perl -pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/' "$TW/walker.js"
FROM="https://rss.chat/?id=204" TO="$BASE/?id=$ID" perl -pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/' "$TW/walker.js"
(cd "$TW" && npm install --silent --no-audit --no-fund && NODE_TLS_REJECT_UNAUTHORIZED=0 node walker.js) > "$TW/out.txt" 2>/dev/null
grep -q "hello edited by e2e" "$TW/out.txt" || fail "threadwalker missed the post"
grep -q "a reply from e2e" "$TW/out.txt" || fail "threadwalker missed the reply"
rm -rf "$TW"

echo "-- 9 delete the reply"
C -G -X POST "$BASE/deletepost?$AUTH" --data-urlencode "id=$RID" > /dev/null
sleep 1
C "$BASE/feeds/users/$NAME/comments/$ID.xml" | grep -q "a reply from e2e" && fail "deleted reply still in comments feed"

echo "-- 10 no external calls"
docker compose logs rsschat 2>&1 | grep -iE "amazonaws|scripting\.com|rsscloud" && fail "server log mentions external hosts" || true

echo "E2E: ALL CHECKS PASSED"
```

- [ ] **Step 2: Run it against the stack**

Run:
```bash
grep -q "^RSSCLOUD_ENABLED=false" deploy/.env || sed -i 's/^RSSCLOUD_ENABLED=.*/RSSCLOUD_ENABLED=false/' deploy/.env
(cd deploy && docker compose up -d)
bash deploy/scripts/e2e-test.sh
```
Expected: ten `-- N …` progress lines, then `E2E: ALL CHECKS PASSED`.
Debugging note: step 3 assumes the confirmation URL answers with a 302 whose `Location` carries `email`/`code`/`screenname` (that is what the client's `handleEmailConfirm` parses from `location.search`). If daveappserver responds differently, inspect with `curl -sk -i "$LINK"` and adjust the extraction, keeping the assertion that CODE and SCREEN are non-empty.

- [ ] **Step 3: Commit**

```bash
git add deploy/scripts/e2e-test.sh
git commit -m "$(printf 'deploy: end-to-end verification script\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
```

---

### Task 9: README and final verification

**Files:**
- Create: `deploy/README.md`

**Interfaces:**
- Consumes: everything above.
- Produces: operator documentation; the final commit of the feature.

- [ ] **Step 1: Write deploy/README.md**

Cover, in this order (README is prose + the exact commands from earlier tasks — keep it under ~150 lines):

1. **What this is** — self-contained rss.chat instance; no Amazon, no scripting.com at runtime; overlay that never touches upstream files (link the design doc).
2. **Quickstart** — `cd deploy && ./scripts/generate-env.sh`, edit `RSSCHAT_DOMAIN` + `SMTP_*`, `docker compose up -d --build`, visit `https://DOMAIN`, magic links at `https://DOMAIN/mail` until real SMTP is configured.
3. **Env reference** — table of every var in `.env.example`, one line each.
4. **Mail deliverability** — MailPit is a catcher not a relay; for real users set an SMTP provider and a MAIL_SENDER whose domain has SPF/DKIM for it (cite upstream's 7/11/26 worknote lesson).
5. **Feeds** — where they live (`/feeds` volume), their URL shapes, and that they're plain static XML anyone can subscribe to.
6. **Upgrading** — `git pull` upstream, `docker compose build --no-cache rsschat`, `docker compose up -d`; if the build fails at `patch-client` or a vendor hash, upstream changed something: re-run `pin-vendors.sh` / adjust the patch mapping, review the diff, rebuild.
7. **Backup & restore** — `scripts/backup.sh`; restore = fresh stack, `gunzip < db-….sql.gz | docker compose exec -T mysql mysql -u… rsschat`, untar feeds into the volume, or just let the app regenerate feeds on next write.
8. **Testing** — `node --test deploy/`, `bash deploy/patches/test-patch-client.sh`, `bash deploy/test-vendor.sh`, `bash deploy/scripts/e2e-test.sh`.

- [ ] **Step 2: Run the full test suite one last time**

Run:
```bash
node --test deploy/daves3-shim/ && node --test deploy/test-make-config.js
bash deploy/test-vendor.sh && bash deploy/patches/test-patch-client.sh
git status --porcelain client/ server/   # must print nothing
bash deploy/scripts/e2e-test.sh
```
Expected: all pass; `git status` on `client/ server/` empty (upstream untouched).

- [ ] **Step 3: Commit and push**

```bash
git add deploy/README.md
git commit -m "$(printf 'deploy: operator README\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>')"
git push origin main
```

---

## Self-Review (done at plan-writing time)

- **Spec coverage:** shim→T1; config contract→T2; vendor+pins+fonts+images→T3; patches incl. overrides/hitCounter→T4; image+entrypoint+static sync→T5; compose/Caddy/schema/networks/healthchecks→T6; ops scripts→T7; verification plan items 1–7→T8, item 8 (backup/restore)→T7+T9 README; upstream-untouched guarantee asserted in T4's test and T9's final check. Two spec deviations (short S3 paths in config instead of prefix-stripping shim; loveRss.png left as-is in server-generated XML) are recorded in Global Constraints.
- **Placeholder scan:** every file's full content is present except README prose (outlined section-by-section with its commands defined in earlier tasks — deliberate, not a gap).
- **Type consistency:** `newObject` signature identical in T1 shim/test and T5 smoke test; env var names identical across T2, T5, T6, T7, T8; lock-line format identical between vendor.sh, test fixture, and pin-vendors.sh; `/static/vendor/...` and `/static/client/...` paths identical between T3 dest paths, T4 rewrites, T5 Dockerfile COPYs, and T6 Caddy routes.

---

## Post-execution addendum (2026-07-13) — corrections made during implementation

All nine tasks executed and were reviewed clean; the stack runs and the e2e
passes. Where the code as written in this plan was wrong or incomplete, the
implementers corrected it — recorded here so this document is not a trap for
the next reader. The shipped code is authoritative; where it differs from a
task's code block above, the difference is one of these:

- **T2 (make-config):** the whitelist gate must split/trim/filter *before*
  testing for emptiness, else `WHITELIST=" , , "` yields a present empty
  array (deny-all) instead of an absent key (open signup). Also added
  `database.flUseMySql2: true` — **mandatory**, or MySQL 8 auth fails
  (`ER_NOT_SUPPORTED_AUTH_MODE`) and the app never connects.
- **T3 (vendor):** the FontAwesome webfont-discovery regex in
  `pin-vendors.sh` had to match quoted `url("../webfonts/…")` in the live
  `all.css`; the plan's unquoted regex zero-matched and aborted under
  `pipefail`. Real pin count is 84 assets, not ~20.
- **T5 (image):** smoke-test invocations need `--entrypoint bash` (the image
  sets ENTRYPOINT, so trailing args append rather than replace). Added a root
  `.dockerignore` because the per-Dockerfile `Dockerfile.dockerignore` is
  BuildKit-only.
- **T6 (compose):** `deploy.resources.limits` is inert under `docker compose
  up`; replaced with `mem_limit:` (512M/1G, verified via `docker inspect`).
  Also added the **schema `prefs` deviation** (`not null default
  (json_object())`) + a migration under `deploy/db/migrations/`, to prevent
  an upstream NULL-prefs server crash on a new user's first API post.
- **T7 (ops scripts):** hardened per review — password via `MYSQL_PWD` env
  (off the argv), literal `.env` key reader instead of `source .env`,
  space-safe `mapfile` retention, `.partial`→`mv` atomic writes.
- **T8 (e2e) + security:** `/mail` was unauthenticated (magic-link exposure →
  account takeover); added Caddy `basic_auth` + generated bcrypt creds,
  with the bcrypt hash `$$`-escaped for Compose interpolation. The e2e drops
  its `saveprefs` step so it posts with default prefs, regression-testing the
  schema fix. Same `/mail` fix applied to the feedland-docker repo.

Three upstream bugs found (NULL-prefs crash, dead `theWsServer.listen()`,
hardcoded `rss.network` feed strings) are detailed in the design doc's
implementation addendum and go to the scripting/rss.chat issue.

---

## Maintenance addendum (2026-07-24) — upstream drift since execution

The task code blocks above are a 2026-07-13 snapshot. Nine days of upstream
commits invalidated specific lines in them, and `make update` broke for an
operator running the overlay. The shipped code is authoritative; the full
reasoning is in the design doc's maintenance addendum. What moved, by task:

- **T3 (vendor):** `feedland/sockets.js` and `rsschat/feedlandsocket.js`
  (lines 412 and 419 above) are gone from the manifest and the lock —
  upstream inlined the `firehoseSocket` object into `client/code/code.js` on
  07-19 and dropped both `<script>` tags. `favicon.ico` was **added** to
  `pin-vendors.sh`'s MANIFEST: it had been hand-appended to `vendor.lock` back
  on 07-16, so the script could not regenerate its own lock without silently
  dropping the pin. Real pin count is now **83** (84 at ship, 86 with the
  favicon and og:image, minus three retired today).
- **T4 (patches):** the two socket `rep` lines (561–562 above) retire with
  them, and so does the `og:image` rewrite plus its assertion in
  `test-patch-client.sh` — upstream added those meta tags on 07-16 and deleted
  them again on 07-17.
- **T5 (image):** `FROM node:20-bookworm-slim` (line 651 above) is now
  `node:22-bookworm-slim` — Node 20 reached end of life in April 2026. It is a
  runtime-hygiene move, not a build fix: upstream's v0.6.0 SQLite work made
  `better-sqlite3` a hard dependency of `davesql`, and while it was unpinned
  npm resolved 13.x, which always compiles from source and broke the build in
  this toolchain-free image — but upstream v0.6.3 pins 11.10.0 itself, and
  that ships prebuilds for Node 20 and 22 alike, so the overlay carries no pin
  of its own. The `npm install` line gained an `rm -rf node_modules/aws-sdk`
  **inside the same RUN layer** — a later layer would hide the files without
  reclaiming the space. New `deploy/aws-sdk-shim/` replaces the SDK with a
  stub whose constructor succeeds and whose `sendEmail` throws; image
  653MB → 536MB.
- **T8 (e2e):** the threadwalker substitution (line 1143 above) targeted
  `users.rss.network`, which upstream repointed on 07-18 — and it had no
  not-found guard, so it silently no-oped and the walk tested the *public*
  rss.chat rather than the instance, inside a test whose step 10 asserts no
  external calls. Corrected, and routed through a `subst()` helper carrying
  `patch-client.sh`'s fail-loud check. Step 10 also now asserts the aws-sdk
  stub is never reached.
- **Tech stack:** Node 22, not the Node 20 in the header above.

`make test` is now 18 unit tests (the four aws-sdk shim tests are new), and
`make e2e` passes all ten steps.

# rss.chat self-contained Docker deployment — design

Date: 2026-07-13
Status: implemented and running; amended 2026-07-16 for upstream v0.5.27
Author: Ricardo (rmdes) with Claude Code

> **Amendment, 2026-07-16 (server v0.5.27).** Upstream solved the S3 problem
> itself: `flFeedsInDatabase` stores feeds in a `files` table and serves them
> from the app, so the filesystem shim this design built no longer writes
> anything and the `feeds-data` volume is gone. The overlay now just turns the
> flag on. Dependency #1 below is upstream's answer, not ours; the rest of the
> design stands. Details are inline, marked as amendments.
>
> One dependency moved the other way: v0.5.27 added `urlFavicon`, defaulting to
> `//s3.amazonaws.com/scripting.com/favicon.ico`, which the server redirects
> `/favicon.ico` to. It is vendored and served locally like every other asset.

## Motivation

rss.chat is a social network where every user is an RSS feed. Its own docs make
the case that there is no lock-in: anyone can read the feeds anywhere. This
design extends that idea one level down — anyone should be able to *run* an
instance without depending on anyone else's infrastructure.

Today a stock install depends on three external things:

1. **Amazon S3** — every post, edit, delete and like publishes static feed XML
   through the `daves3` package, which hardcodes `new AWS.S3()` with no
   endpoint override.
2. **scripting.com CDNs** — the client's `index.html` loads ~15 JS/CSS
   includes (jQuery, Bootstrap, concord, signupdialog, feedlandsocket,
   markdownConverter, …) from Dave's S3 buckets and `code.scripting.com`;
   themes and two images load from there too. None of these third-party
   includes are in the repo.
3. **Amazon SES** — the default mail path for magic-link sign-in (SMTP is
   already supported by daveappserver via `smtpHost` etc.).

This design removes all three at deployment time, without modifying a single
upstream file. The precedent is [feedland-docker](https://github.com/rmdes/feedland-docker),
the same treatment for FeedLand; conventions are carried over wherever they fit.

## Goals

- One-command deployment on any VPS: `docker compose up -d`.
- Fully self-contained at runtime: no requests to amazonaws.com or
  scripting.com required for the instance to function.
- Zero modifications to upstream files. Everything lives in `deploy/`;
  `git pull` from `scripting/rss.chat` stays conflict-free forever.
- Preserve interop: FeedLand-compatible firehose records, the `source:`
  namespace elements, OPML subscription list, optional rssCloud pings.
- A clear path to a Cloudron package later (explicit non-goal for now).

## Non-goals

- Cloudron packaging (deferred; nothing here blocks it — see last section).
- Changing upstream architecture, restructuring the repo, or forking.
- Multi-instance federation features beyond what RSS already provides.

## Architecture

Four services, two networks, mirroring feedland-docker:

```
┌─ frontend network ──────────────────────────────┐
│  caddy (80/443)                    mailpit      │
│    │ /            → rsschat:1452   (web UI      │
│    │ /users/*     → rsschat:1452 (from the db)  │
│    │ /static/*    → patched client + vendor     │
│    │ websocket    → rsschat:1462                │
│    │ /mail*       → mailpit:8025                │
└────┼────────────────────────────────────────────┘
┌────┼─ backend network ──────────────────────────┐
│  rsschat (node, image built from this repo)     │
│    └── mysql:8.0 (healthcheck-gated)            │
└─────────────────────────────────────────────────┘
volumes: mysql-data, static-data, rsschat-data,
         caddy-data, caddy-config
```

- Only Caddy exposes ports (80/443, automatic HTTPS).
- Single domain, path-based: feeds at `https://DOMAIN/users/{name}/rss.xml`,
  subscription list at `https://DOMAIN/data/subs.opml`, static assets at
  `https://DOMAIN/static/…`, MailPit UI at `https://DOMAIN/mail`.
- *Amended 2026-07-16:* the app serves the feeds itself out of the database, so
  Caddy no longer has a feeds root and `feeds-data` is gone. The overlay had
  not been deployed anywhere when this changed, so there are no old `/feeds/*`
  subscribers to redirect and no upgrade path to carry.
- `static-data` is populated by the app container's entrypoint (rsync from
  the image) so client updates ship with the image and Caddy never rebuilds.

## Repo layout (overlay)

```
deploy/
  docker-compose.yml
  Dockerfile              # builds rsschat image from ../server + ../client
  entrypoint.sh           # env vars → config.json, rsync static, exec node
  Caddyfile
  daves3-shim/            # drop-in daves3 replacement → throws; feeds go to the database
  vendor.sh               # build-time fetch of CDN includes, fonts, images
  vendor.lock             # URL + sha256 pin per asset
  patches/                # build-time URL rewrites (index.html, globals.js, …)
  db/init/01-schema.sql   # vendored from server/docs/install.md
  db/conf/my.cnf          # utf8mb4
  scripts/generate-env.sh # .env with random passwords
  scripts/backup.sh       # mysqldump (feeds included), with retention
  scripts/migrate.sh      # apply SQL migrations
  .env.example
  README.md
```

Upstream files under `client/` and `server/` are never edited or committed to.

## Image build

Multi-stage Dockerfile.

**Stage 1 — vendor.** `vendor.sh` downloads every third-party asset
`index.html` references into `/static/vendor/`:

- jQuery 1.9.1, Bootstrap 2 (css+js), FontAwesome css **and its webfonts/**
- scripting.com `basic` includes (code.js, styles.css)
- feedland `api.js`, `signupdialog.js/.css`
- concord.js/.css, outliner.js, outlinedialog code.js/styles.css
- sockets.js, feedlandsocket.js
- markdownConverter.js, turndown.js
- Google fonts (Ubuntu, Archivo Black, Inter) as woff2 with local
  `@font-face` css replacing the `@import`/`<link>` usage
- the two cosmetic images (default avatar `kittyStamp.png`, everyone-feed
  logo `loveRss.png`)

`vendor.lock` pins each URL with a sha256. **Strict pinning**: any upstream
content change fails the build (re-pin is a deliberate, reviewed act). The
stage is cached; rebuilds don't re-download unless the lock changes.

**Stage 2 — patch.** Applied to *copies* of client files, never the repo:

- `index.html`: CDN URLs → `/static/vendor/…`; `code.scripting.com/rsschat/*`
  → `/static/client/…` (the repo's own `client/code/` files)
- `globals.js`: `urlThemes` → `/static/client/themes/`; `urlDefaultImage` →
  vendored copy
- `basic/code.js`: `hitCounter()` no-oped (phones Dave's stats server)

Patches that fail to apply fail the build — upstream drift surfaces at build
time, never in production.

**Stage 3 — app.** `npm install` in `server/code`, then overwrite
`node_modules/daves3` with the shim. Final image carries the server, the
patched client + vendor tree at `/static/`, and the entrypoint.

## The daves3 shim

*Amended 2026-07-16.* Originally the shim reimplemented `newObject` and wrote
feed XML to a `/feeds` volume, which Caddy served — this design's answer to the
S3 dependency. Server v0.5.27 made that unnecessary: `flFeedsInDatabase` routes
every feed write to a `files` table (`publishFeedFile` and
`updateSubscriptionListOnS3` are the only two `s3.newObject` call sites, and
both sit in the `else` branch), and the app serves them at `/users/*` and
`/data/subs.opml`.

`rssnetwork.js` still requires `daves3` unconditionally, so the shim stays — but
as a stub, not an implementation. Every property access throws. It earns its
place two ways: the real package (and Amazon's SDK) never enters the image, and
if a config regression or an upstream change ever routed a write back to S3, it
fails loudly instead of silently writing to somebody else's bucket. `make test`
asserts exactly that, and the e2e run greps the container log to confirm the
stub is never reached.

## Configuration contract

`entrypoint.sh` generates `config.json` from env vars, validates it with
`node -e JSON.parse`, then `exec node rssnetwork.js`.

| Env var | Default | Maps to |
|---|---|---|
| `RSSCHAT_DOMAIN` | required | `myDomain`, `urlServerForClient`, `urlServerForEmail`, `urlWebsocketServerForClient` (wss://DOMAIN/). The server derives the feed URLs from `urlServerForClient`, so the four S3 location settings are deliberately absent |
| `FAVICON_URL` | `/static/vendor/favicon.ico` | `urlFavicon` -- overrides upstream's amazonaws.com default |
| `PRODUCT_NAME` | `rss.chat` | `productName`, `productNameForDisplay`, `confirmEmailSubject`, `operationToConfirm` |
| `WHITELIST` | empty | `whitelist` array (CSV); empty = open signup |
| `BLOCKLIST` | empty | `blockedUsersList` array (CSV); empty = nobody blocked. Both lists are omitted entirely when empty -- a present-but-empty `whitelist` would lock everyone out |
| `RSSCLOUD_ENABLED` | `true` | `flRssCloudEnabled` |
| `MYSQL_DATABASE/USER/PASSWORD` | rsschat/rsschat/required | `database.*` (host `mysql`) |
| `SMTP_HOST/PORT/USERNAME/PASSWORD` | mailpit/1025/–/– | `smtpHost` etc. |
| `MAIL_SENDER` | `rsschat@localhost` | `mailSender` |
| `TZ` | UTC | container timezone |

Fixed values: `port` 1452, `websocketPort` 1462, `flWebsocketEnabled` true,
`flSecureWebsocket` true, `pathServerHomePageSource` → the patched
`index.html` inside the image (daveappserver does its `[%macro%]`
substitution locally; no fetch from scripting.com).

## Email

MailPit is the zero-config default — magic links land in the web UI at
`https://DOMAIN/mail`, which is enough for a whitelisted personal instance.
Real delivery: set `SMTP_*` + `MAIL_SENDER` to a relay. Deliverability note
(from upstream's own worknotes, 7/11/26): `MAIL_SENDER`'s domain must
authorize the relay via SPF/DKIM or Gmail sends the links to spam.

## Error handling

- Compose healthchecks gate startup: mysql → rsschat → caddy.
- Build fails on: vendor hash mismatch, patch mismatch.
- Entrypoint fails on: missing required env vars, invalid generated JSON.
- Shim fails loudly on unknown calls; feed-write errors surface in the
  server's existing `newObject` error logging.

## Verification plan

On a scratch domain, end to end:

1. `docker compose up -d` from a clean checkout.
2. Create an account via the MailPit magic link; sign in.
3. Post / reply / like / edit / delete; after each, confirm the user feed,
   everyone feed, and comments feeds regenerate under `/users/`.
4. Validate feed XML (channel elements, `source:` namespace, `source:self`,
   `source:comments`).
5. Run `examples/threadwalker` against this instance's feeds — the repo's
   own proof that a conversation tree is walkable from static files alone.
6. Second browser: verify websocket live updates (newItem, updatedItem/likes).
7. Confirm zero requests to scripting.com / amazonaws.com (browser network
   tab + server logs).
8. `backup.sh` then restore into a fresh stack; instance comes back intact.

## Upstream relationship

This design will be presented to `scripting/rss.chat` as an issue before or
alongside publication, so upstream is aware. Key points for that audience:
no upstream file is modified; the overlay tracks upstream `main`; interop
surfaces (FeedLand record names, source namespace, OPML, rssCloud) are
preserved deliberately; the intent is more rss.chat instances, which is the
point of a social network built on RSS.

## Cloudron (future)

Everything maps: MySQL addon, sendmail addon, one app container; Caddy's
routing moves into Cloudron's nginx config. The vendored client is identical in
that world. Feeds-in-database makes this simpler than originally sketched --
there is no feeds volume to map to localstorage, so the MySQL addon carries the
whole instance. Deferred until the compose deployment has proven itself on a
real instance.

---

## Implementation addendum (2026-07-13) — what actually shipped

The overlay was built and verified end to end on a live stack (MySQL 8.0.46,
the full signup → post → reply → like → edit → delete flow, threadwalker
walking our own feeds, zero requests to scripting.com or amazonaws.com). The
design above held; these are the points where reality added to or corrected
it.

### Mandatory config additions

- **`database.flUseMySql2: true`** — not optional. MySQL 8's default auth
  plugin (`caching_sha2_password`) is unsupported by davesql's legacy `mysql`
  driver, so the app cannot connect at all without this flag, which selects
  the modern, bundled `mysql2` driver (3.22.6). Every DB call errored
  `ER_NOT_SUPPORTED_AUTH_MODE` until it was set. This is the anti-legacy
  choice (Dave's config defaults the flag to `false`); the stack is on the
  current MySQL 8 line, not on anything legacy.

### Schema deviation (documented, reversible)

- **`prefs json not null default (json_object())`** — one column constraint
  stronger than upstream's `install.md` (which allows NULL). This is a
  workaround for an upstream server bug, not a fork of behavior: it is
  compatibility-preserving (upstream never inserts `prefs` explicitly —
  `rssnetwork.js:236` writes only screenname/email/secret, so the column
  always took its default; `{}` behaves identically to a user who saved
  empty prefs, a normal state the app already handles) and reversible (drop
  it once the upstream read is guarded). A migration for existing installs
  ships at `deploy/db/migrations/2026-07-13-prefs-not-null.sql` (backfills
  NULL rows before tightening the constraint). See upstream bug #1 below.

### Security addition (not in the original design)

- **`/mail` requires HTTP basic auth.** MailPit's UI and API expose every
  user's sign-in magic link; unauthenticated (the feedland-docker pattern
  this was copied from) that is account takeover on any public instance.
  Caddy now gates `/mail*` with `basic_auth`; `scripts/generate-env.sh`
  generates `MAILPIT_USER`/`MAILPIT_PASSWORD` and the bcrypt
  `MAILPIT_PASSWORD_HASH` Caddy consumes; compose fails closed
  (`${MAILPIT_PASSWORD_HASH:?...}`) if the hash is unset. Gotcha: Docker
  Compose re-interpolates `$name` inside `.env` values, so the bcrypt hash
  must be `$$`-escaped (generate-env.sh does this; a hand-added hash must
  too). The same fix was applied to the user's feedland-docker repo.

### Other corrections to the design

- **Memory limits use `mem_limit:`**, not `deploy.resources.limits`, which
  plain `docker compose up` silently ignores (it is Swarm/`--compatibility`
  only). The original design copied the inert block from feedland-docker;
  the running stack now enforces 512M/1G (verified via `docker inspect`).
- **A root `.dockerignore`** mirrors `deploy/Dockerfile.dockerignore`, whose
  per-Dockerfile naming is BuildKit-only and a no-op on the legacy builder.
- **Vendor count: 84 pinned assets** (not ~20 — FontAwesome expands to 16
  css+webfont files, Google fonts to 50 woff2). The FontAwesome webfont
  discovery in `pin-vendors.sh` had to handle quoted `url("../webfonts/…")`
  in the live `all.css`, which the original design's regex missed.

### Upstream bugs found (for the scripting/rss.chat issue)

All three surfaced because we drove the server outside the browser's happy
path, which is exactly what a Docker deployment and API clients do:

1. **NULL-prefs crash (server-fatal).** `buildFeedForUser`
   (`rssnetwork.js:655` in v0.5.25) reads `userRec.prefs.myFeedTitle`
   unguarded. Any
   user created via the API who posts before saving prefs sends `prefs`
   NULL → `TypeError` → the Node process exits (a one-request remote crash).
   The browser client never hits it because it saves prefs at sign-in.
   Suggested upstream fix: guard the read. Our schema default is the
   deployment-side workaround until then.
2. **Dead `theWsServer.listen()` call.** `daveappserver` appserver.js:431
   calls `.listen()` on a `ws` server that is already listening from its
   constructor; the method does not exist and throws on every boot, logged
   as `webSocketStartup: err.message == theWsServer.listen is not a
   function`. Cosmetic — websockets work (verified `wss://` through Caddy) —
   but it is dead code that should be deleted.
3. **Hardcoded `rss.network` strings.** `rssnetwork.js:1,632,634` hardcode
   the old product name into the feed generator and default feed
   title/description, so a self-hosted instance's feeds introduce themselves
   as "rss.network" regardless of `config.myDomain`/`productNameForDisplay`.
   Overridable per-user via Settings, but the defaults should derive from
   config. (Low-priority companion note: the install docs should mention
   `flUseMySql2: true` for MySQL 8.)

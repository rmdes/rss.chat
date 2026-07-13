# rss.chat self-contained Docker deployment — design

Date: 2026-07-13
Status: approved (design), implementation not started
Author: Ricardo (rmdes) with Claude Code

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
│    │ /feeds/*     → feeds-data volume  at /mail)│
│    │ /static/*    → patched client + vendor     │
│    │ websocket    → rsschat:1462                │
│    │ /mail*       → mailpit:8025                │
└────┼────────────────────────────────────────────┘
┌────┼─ backend network ──────────────────────────┐
│  rsschat (node, image built from this repo)     │
│    └── mysql:8.0 (healthcheck-gated)            │
└─────────────────────────────────────────────────┘
volumes: mysql-data, feeds-data, static-data, rsschat-data,
         caddy-data, caddy-config
```

- Only Caddy exposes ports (80/443, automatic HTTPS).
- Single domain, path-based: feeds at `https://DOMAIN/feeds/users/{name}/rss.xml`,
  subscription list at `https://DOMAIN/feeds/subs.opml`, static assets at
  `https://DOMAIN/static/…`, MailPit UI at `https://DOMAIN/mail`. A separate
  feeds subdomain remains possible later via one env var.
- `feeds-data` is shared: the app writes it (via the daves3 shim), Caddy
  serves it read-only.
- `static-data` is populated by the app container's entrypoint (rsync from
  the image) so client updates ship with the image and Caddy never rebuilds.

## Repo layout (overlay)

```
deploy/
  docker-compose.yml
  Dockerfile              # builds rsschat image from ../server + ../client
  entrypoint.sh           # env vars → config.json, rsync static, exec node
  Caddyfile
  daves3-shim/            # drop-in daves3 replacement → writes /feeds
  vendor.sh               # build-time fetch of CDN includes, fonts, images
  vendor.lock             # URL + sha256 pin per asset
  patches/                # build-time URL rewrites (index.html, globals.js, …)
  db/init/01-schema.sql   # vendored from server/docs/install.md
  db/conf/my.cnf          # utf8mb4
  scripts/generate-env.sh # .env with random passwords
  scripts/backup.sh       # mysqldump + feeds tar, with retention
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

The server calls exactly one daves3 function, in four places
(`updateFeedsOnS3` ×2, `publishCommentsFeed`, `updateSubscriptionListOnS3`):

```
newObject (path, data, type, acl, callback)
```

The shim:

- strips the configured S3 prefix (`rssS3Path` / `opmlS3Path` keep their
  upstream values; the shim maps them under `/feeds`)
- sanitizes the path (rejects `..`, absolute escapes)
- writes atomically (temp file + rename) under the `/feeds` volume
- calls back with the same `(err, data)` contract

Every other property access on the module throws:
`"daves3 shim: unimplemented call <name> — upstream now uses more of daves3"`.
Upstream growth surfaces as a loud error, not silent data loss.

## Configuration contract

`entrypoint.sh` generates `config.json` from env vars, validates it with
`node -e JSON.parse`, then `exec node rssnetwork.js`.

| Env var | Default | Maps to |
|---|---|---|
| `RSSCHAT_DOMAIN` | required | `myDomain`, `urlServerForClient`, `urlServerForEmail`, `urlWebsocketServerForClient` (wss://DOMAIN/), `rssFeedUrl` (https://DOMAIN/feeds/users/), `opmlListUrl` (https://DOMAIN/feeds/subs.opml) |
| `PRODUCT_NAME` | `rss.chat` | `productName`, `productNameForDisplay`, `confirmEmailSubject`, `operationToConfirm` |
| `WHITELIST` | empty | `whitelist` array (CSV); empty = open signup |
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
   everyone feed, and comments feeds regenerate under `/feeds`.
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

Everything maps: MySQL addon, sendmail addon, localstorage for `/feeds`,
one app container; Caddy's routing moves into Cloudron's nginx config. The
daves3 shim and vendored client are identical in that world. Deferred until
the compose deployment has proven itself on a real instance.

# rss.chat Docker deployment

Operator documentation for the `deploy/` overlay: a self-contained rss.chat
instance you can run on any VPS with `docker compose up -d`. No Amazon S3,
no Amazon SES, no scripting.com CDN calls at runtime -- everything the
client and server need is vendored, patched, or replaced at build time.

This overlay never edits a file under `client/` or `server/`; it only adds
files under `deploy/`, so `git pull` from upstream stays conflict-free.
Background and design rationale: `docs/superpowers/specs/2026-07-13-rsschat-docker-deploy-design.md`.

## Quickstart

```bash
cd deploy
./scripts/generate-env.sh        # writes .env with random DB + MailPit passwords
$EDITOR .env                     # set RSSCHAT_DOMAIN; set SMTP_* for real mail (see below)
docker compose up -d --build
```

Visit `https://RSSCHAT_DOMAIN`. Caddy provisions a TLS certificate
automatically for a public domain; for `localhost` or a private IP it falls
back to a self-signed certificate (expect a browser warning, or `curl -k`).

Until you configure a real SMTP relay, sign-in magic links land in MailPit
at `https://RSSCHAT_DOMAIN/mail` (basic-auth protected -- credentials are
printed by `generate-env.sh` and stored in `.env` as `MAILPIT_USER` /
`MAILPIT_PASSWORD`).

## Env reference

Every variable lives in `.env` (copy or generate from `.env.example`).

| Var | Default | Meaning |
|---|---|---|
| `RSSCHAT_DOMAIN` | required | public hostname; drives every URL the server emits |
| `PRODUCT_NAME` | `rss.chat` | display name, confirmation email subject/copy |
| `WHITELIST` | empty | comma-separated emails allowed to sign up; empty = open signup |
| `RSSCLOUD_ENABLED` | `true` | ping rpc.rsscloud.io on publish (outbound only) |
| `MYSQL_ROOT_PASSWORD` | required | MySQL root password (container init only) |
| `MYSQL_PASSWORD` | required | app DB user password |
| `MYSQL_DATABASE` | `rsschat` | database name |
| `MYSQL_USER` | `rsschat` | app DB user |
| `SMTP_HOST` | `mailpit` | SMTP relay host |
| `SMTP_PORT` | `1025` | SMTP relay port |
| `SMTP_USERNAME` | empty | SMTP auth (leave empty for MailPit) |
| `SMTP_PASSWORD` | empty | SMTP auth (leave empty for MailPit) |
| `MAIL_SENDER` | `rsschat@localhost` | From: address on magic-link emails |
| `MAILPIT_USER` | `mail` | basic-auth username for `/mail` |
| `MAILPIT_PASSWORD` | required | basic-auth password for `/mail` (plaintext, for your own reference) |
| `MAILPIT_PASSWORD_HASH` | required | bcrypt hash of the above; this is what Caddy actually checks |
| `TZ` | `UTC` | container timezone |

## Mail

MailPit is a catcher, not a relay: it accepts SMTP and shows you what was
sent, but it never delivers to the outside world. That's the right default
for local development or a private, whitelisted instance -- zero config,
zero risk of misdelivery. For an instance with real users, point `SMTP_*`
at an actual relay (Postfix, SES, Mailgun, etc.) and set `MAIL_SENDER` to an
address whose domain authorizes that relay via SPF/DKIM. Skip this and
magic-link mail lands in spam or gets rejected outright -- this is the same
lesson upstream hit in their own 7/11/26 worknotes.

### The mail catcher is protected, and that matters

`/mail` is MailPit's web UI *and* its API, and both display full message
bodies -- including every sign-in magic link ever sent. An unauthenticated
`/mail` is an account-takeover endpoint: anyone who finds it can read a
user's magic link and sign in as them. Caddy puts HTTP basic auth in front
of the whole `/mail*` path (see `Caddyfile`), checked against
`MAILPIT_USER` / `MAILPIT_PASSWORD_HASH`.

`scripts/generate-env.sh` generates all three mail-catcher variables for
you: a random password, and its bcrypt hash via
`docker run --rm caddy:2-alpine caddy hash-password --plaintext '...'`. If
you ever need to rotate the password, run that same command yourself and
update `.env` by hand -- but watch the escaping: docker compose
re-interpolates any `$name`-shaped sequence it finds inside a `.env` value,
so a bcrypt hash (which is full of `$`) must have every `$` doubled to `$$`
before you paste it in, or compose silently mangles it and basic auth
starts rejecting the right password. `generate-env.sh` does this escaping
for you; a hand-edited hash does not get it for free.

## Feeds

Feeds live on the `feeds-data` volume, mounted read-only into Caddy and
read-write into the app container. They are plain static XML -- nothing
about them requires this instance or any particular reader:

- `https://DOMAIN/feeds/users/{screenname}/rss.xml` -- one user's feed
- `https://DOMAIN/feeds/users/{screenname}/comments/{id}.xml` -- replies to one item
- `https://DOMAIN/feeds/users/rss.xml` -- the "everyone" firehose feed
- `https://DOMAIN/feeds/subs.opml` -- the subscription list (OPML)

Anyone can subscribe to any of these in any feed reader; that's the point
of the network.

## Upgrading

```bash
git pull                                       # upstream client/ and server/
cd deploy
docker compose build --no-cache rsschat
docker compose up -d
```

If the build fails inside `patch-client` or on a vendor hash mismatch,
upstream changed something the overlay depends on (a CDN URL in
`index.html`/`globals.js`, or the content behind a pinned URL). That's by
design -- strict pinning means drift surfaces at build time, not in
production. Fix it deliberately:

- vendor hash mismatch: re-run `./pin-vendors.sh`, review the diff to
  `vendor.lock` before rebuilding.
- patch mismatch: open `patches/patch-client.sh`, find the `rep` call whose
  `FROM` string no longer appears in the file it targets, and adjust it to
  match the new upstream text.

Then rebuild and re-run the test suite (below) before trusting the result.

## Backup & restore

```bash
./scripts/backup.sh                 # writes deploy/backups/db-<stamp>.sql.gz + feeds-<stamp>.tar.gz, keeps the newest 14 of each
```

To restore onto a fresh stack:

```bash
docker compose up -d                                                  # empty stack, schema applied by db/init
gunzip < backups/db-<stamp>.sql.gz | docker compose exec -T mysql mysql -u"$MYSQL_USER" "$MYSQL_DATABASE"
docker compose exec -T rsschat tar -xzf - -C /feeds < backups/feeds-<stamp>.tar.gz
```

Restoring the feeds tarball is optional -- the app regenerates each feed
file the next time that user or item is written -- but restoring it gives
you back everything immediately instead of waiting for activity.

Schema changes to an existing install go through
`./scripts/migrate.sh deploy/db/migrations/<file>.sql`; fresh installs
already have the current schema via `db/init/01-schema.sql`.

## Testing

```bash
node --test deploy/                        # daves3 shim + config generator unit tests
bash deploy/test-vendor.sh                  # vendor.lock hashes match fetched content
bash deploy/patches/test-patch-client.sh    # patch-client.sh rewrites cleanly, leaves no external URLs
bash deploy/scripts/e2e-test.sh             # full posting flow against a running stack
```

`e2e-test.sh` runs against `https://localhost` and creates a throwaway user
on every run (via the real magic-link flow, pulled from MailPit's API), so
it requires `RSSCLOUD_ENABLED=false` and an empty `WHITELIST` in `.env` --
open signup, and no outbound pings for a test account nobody subscribes to.
It ends with `E2E: ALL CHECKS PASSED` on success.

## Notes on this deployment

A few deliberate departures from upstream's defaults, and one upstream
quirk worth knowing about:

- **`prefs` defaults to `{}`, not `NULL`.** Upstream's `server/docs/install.md`
  schema allows `prefs` to be NULL. `server/code/rssnetwork.js:638`
  (`buildFeedForUser`) reads `userRec.prefs.myFeedTitle` unguarded, so a
  user created through the API who posts before ever saving prefs crashed
  the server process. `db/init/01-schema.sql` defaults new rows to an empty
  JSON object instead. Existing installs: apply
  `deploy/db/migrations/2026-07-13-prefs-not-null.sql` via `scripts/migrate.sh`.
- **`database.flUseMySql2: true`** in the generated config, so davesql uses
  the mysql2 driver -- MySQL 8's default auth plugin isn't supported by the
  legacy `mysql` driver this app also knows how to use.
- **"rss.network" still shows up** in the generator tag and the default
  per-user feed title/description. Those strings are hardcoded in
  `rssnetwork.js`, which this overlay never modifies. Set your own
  Title/Description per user under Settings to override them; there's no
  server-side default to change without patching upstream code.
- **`webSocketStartup: err.message == theWsServer.listen is not a function`**
  prints on every boot. It's harmless: the websocket server is already
  listening by the time that line runs, and the extra `.listen()` call is
  dead code upstream. Live updates (new posts, likes) work regardless.

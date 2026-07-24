# rss.chat deployment Makefile — design

Date: 2026-07-13
Status: implemented and shipped 2026-07-13; addendum 2026-07-24
Author: Ricardo (rmdes) with Claude Code

## Motivation

The Docker deployment overlay works, but a new user must know `docker compose`,
the `deploy/scripts/*.sh` set, and the `.env` bootstrap order. A `Makefile`
gives one memorable front door — `make install`, `make up`, `make backup` —
and smooths the first-run cliff.

## Goals

- `make install` takes a fresh clone to a running instance in one command.
- Full lifecycle: start/stop/update/logs/backup/migrate/test/e2e/clean.
- Wrap the existing scripts and compose; never duplicate their logic (DRY).
- Overlay-consistent: one new root file, nothing under `client/`/`server/`.

## Non-goals

- Replacing the scripts (the Makefile calls them).
- Any orchestration beyond a single-host compose stack.

## Mechanism

A single `Makefile` at the repo root. All compose invocations go through one
variable so paths resolve correctly when run from the clone root:

```
COMPOSE = docker compose --project-directory deploy -f deploy/docker-compose.yml
```

`--project-directory deploy` makes compose treat `deploy/` as the project
directory, so the compose file's relative paths (`./Caddyfile`, `./db/init`,
`./db/conf/my.cnf`) and the `.env` file resolve exactly as they do when run
from inside `deploy/`. This must be verified empirically against the running
stack (`make ps` / `$(COMPOSE) config` showing the `.env` values rendered),
not assumed — compose's project-dir vs. working-dir `.env` resolution is a
known footgun.

The `deploy/scripts/*.sh` already `cd "$(dirname "$0")/.."` into `deploy/`,
so the Makefile targets invoke them by path (`bash deploy/scripts/<x>.sh`)
with no path juggling.

## Targets

`.DEFAULT_GOAL := help`; all targets `.PHONY`. `make help` auto-generates its
listing from `## ` comments on each target (standard self-documenting idiom).

| Target | Behavior |
|---|---|
| `help` | List all targets with their `##` descriptions (default goal) |
| `install` | Bootstrap `.env` if missing (via `env`), then `build`, then `up -d --wait`; on success print the site URL and where to read mail |
| `up` | `$(COMPOSE) up -d --wait`; if `.env` is missing, run `env` first |
| `down` | `$(COMPOSE) down` |
| `restart` | `$(COMPOSE) restart` |
| `update` | `git pull` → `$(COMPOSE) build` → `$(COMPOSE) up -d --wait` |
| `build` | `$(COMPOSE) build` |
| `logs` | `$(COMPOSE) logs -f $(SERVICE)` (SERVICE optional) |
| `ps` | `$(COMPOSE) ps` |
| `shell` | `$(COMPOSE) exec rsschat bash` |
| `env` | `bash deploy/scripts/generate-env.sh` |
| `backup` | `bash deploy/scripts/backup.sh` |
| `migrate` | `bash deploy/scripts/migrate.sh $(FILE)`; error if `FILE` unset |
| `test` | `node --test deploy/daves3-shim/ deploy/test-make-config.js` (working invocation for this Node), `bash deploy/test-vendor.sh`, `bash deploy/patches/test-patch-client.sh` |
| `e2e` | `bash deploy/scripts/e2e-test.sh` |
| `clean` | `$(COMPOSE) down -v` — DESTROYS the mysql + feeds volumes; guarded by a typed `y` confirmation |

## Error handling / footguns

- Recipe lines use real tabs (Make requirement).
- `clean` prompts for an explicit `y` before `down -v`; anything else aborts.
- `migrate` fails with a usage message when `FILE=` is absent.
- `install`/`up` detect a missing `.env` and bootstrap it, so compose never
  fails on its `${VAR:?}` required-var guards during a first run.
- `up -d --wait` blocks until healthchecks pass, so `install` only prints
  "ready" when the stack actually is.

## Testing

Every non-destructive target is run against the live stack: `help`, `ps`,
`logs` (brief), `build`, `backup`, `e2e`, and `migrate FILE=<no-op .sql>`.
`clean` is verified with `make -n clean` (dry run) only — it must not wipe the
running data. `make help` output is checked to list every target.

## Docs

`deploy/README.md`: the quickstart re-leads with `make install`; a short
"Using make" section lists the targets. The existing root-`.dockerignore`
caveat (a root file is the one place an upstream `git pull` could conflict)
is extended to mention the `Makefile`.

## Overlay consistency

The `Makefile` is a new file at the repo root (like `.dockerignore`); no file
under `client/` or `server/` is touched. `git pull` from upstream stays
conflict-free unless upstream itself adds a root `Makefile`.

---

## Addendum (2026-07-24) — what shipped, and what moved since

The Makefile shipped on 2026-07-13 with every target in the table above, and
has been the documented front door since (the status line said "implementation
not started" until today; corrected). Two details have drifted from the table:

- **`test`** runs three unit files now, not two: `deploy/daves3-shim/test.js
  deploy/aws-sdk-shim/test.js deploy/test-make-config.js` — 18 tests, up from
  14. The aws-sdk shim arrived 2026-07-24; the reasoning is in the deploy
  design doc's maintenance addendum.
- **`clean`** destroys `mysql-data`, `static-data`, `rsschat-data`,
  `caddy-data` and `caddy-config`. There is no feeds volume: feeds moved into
  the database on 2026-07-16. The `##` help strings for `clean` and `backup`
  had described a feeds volume since before that move; corrected 2026-07-24
  to match what the targets actually do (`backup.sh` has dumped the database
  only, feeds included as `files` rows, since the switch).

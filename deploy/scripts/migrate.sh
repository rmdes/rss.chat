#!/bin/bash
#deploy/scripts/migrate.sh -- apply a SQL migration file to the app database
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -eq 1 ] || { echo "usage: migrate.sh <migration.sql>" >&2; exit 1; }

envval () { # read KEY=VALUE literally from .env, no shell evaluation
	grep -E "^$1=" .env | head -1 | cut -d= -f2-
}
MYSQL_PASSWORD=$(envval MYSQL_PASSWORD)
MYSQL_USER=$(envval MYSQL_USER)
MYSQL_DATABASE=$(envval MYSQL_DATABASE)
[ -n "$MYSQL_PASSWORD" ] || { echo "migrate: MYSQL_PASSWORD not set in .env" >&2; exit 1; }

# MYSQL_PWD still briefly shows up in this host's `docker compose exec` argv (ps), but no longer on the mysql client process's own command line.
docker compose exec -T -e MYSQL_PWD="$MYSQL_PASSWORD" mysql mysql -u"${MYSQL_USER:-rsschat}" "${MYSQL_DATABASE:-rsschat}" < "$1"
echo "migrate: applied $1"

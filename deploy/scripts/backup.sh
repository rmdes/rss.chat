#!/bin/bash
#deploy/scripts/backup.sh -- dump the database; keep the newest 14 dumps
#The feeds are rows in the files table (flFeedsInDatabase), so the dump holds them too.
set -euo pipefail
cd "$(dirname "$0")/.."

envval () { # read KEY=VALUE literally from .env, no shell evaluation
	grep -E "^$1=" .env | head -1 | cut -d= -f2-
}
MYSQL_PASSWORD=$(envval MYSQL_PASSWORD)
MYSQL_USER=$(envval MYSQL_USER)
MYSQL_DATABASE=$(envval MYSQL_DATABASE)
[ -n "$MYSQL_PASSWORD" ] || { echo "backup: MYSQL_PASSWORD not set in .env" >&2; exit 1; }

STAMP=$(date +%Y%m%d-%H%M%S)
DEST="${1:-./backups}"
mkdir -p "$DEST"
rm -f "$DEST"/*.partial

DB_FILE="$DEST/db-$STAMP.sql.gz"

# MYSQL_PWD still briefly shows up in this host's `docker compose exec` argv (ps), but no longer on the mysqldump process's own command line.
# --no-tablespaces: the app's mysql user has no PROCESS privilege and doesn't need it; without the flag mysqldump prints an error it then ignores.
docker compose exec -T -e MYSQL_PWD="$MYSQL_PASSWORD" mysql mysqldump --no-tablespaces -u"${MYSQL_USER:-rsschat}" "${MYSQL_DATABASE:-rsschat}" | gzip > "$DB_FILE.partial"
mv "$DB_FILE.partial" "$DB_FILE"

prune () { # keep the newest 14 files matching $1 glob
	local files
	mapfile -t files < <(ls -t "$DEST"/$1 2>/dev/null)
	local i
	for ((i = 14; i < ${#files[@]}; i++)); do
		rm -- "${files[$i]}"
	done
}
prune "db-*.sql.gz"

echo "backup: $DB_FILE"

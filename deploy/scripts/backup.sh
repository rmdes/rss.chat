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

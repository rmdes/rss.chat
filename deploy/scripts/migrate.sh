#!/bin/bash
#deploy/scripts/migrate.sh -- apply a SQL migration file to the app database
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -eq 1 ] || { echo "usage: migrate.sh <migration.sql>" >&2; exit 1; }
set -a; source .env; set +a
docker compose exec -T mysql mysql -u"${MYSQL_USER:-rsschat}" -p"$MYSQL_PASSWORD" "${MYSQL_DATABASE:-rsschat}" < "$1"
echo "migrate: applied $1"

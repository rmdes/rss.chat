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

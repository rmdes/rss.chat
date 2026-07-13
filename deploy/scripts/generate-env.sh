#!/bin/bash
#deploy/scripts/generate-env.sh -- create .env from .env.example with random passwords
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && { echo "generate-env: .env already exists, refusing to overwrite" >&2; exit 1; }
RP1=$(openssl rand -hex 24)
RP2=$(openssl rand -hex 24)
MAILPIT_PW=$(openssl rand -hex 12)
MAILPIT_HASH=$(docker run --rm caddy:2-alpine caddy hash-password --plaintext "$MAILPIT_PW")

sed -e "s/^MYSQL_ROOT_PASSWORD=.*/MYSQL_ROOT_PASSWORD=$RP1/" \
    -e "s/^MYSQL_PASSWORD=.*/MYSQL_PASSWORD=$RP2/" \
    -e "s/^MAILPIT_PASSWORD=.*/MAILPIT_PASSWORD=$MAILPIT_PW/" \
    .env.example > .env

# MAILPIT_PASSWORD_HASH is a bcrypt hash and may contain '$' and '/' -- unsafe
# as sed replacement text (delimiter/backreference collisions), so write it
# with awk instead, which treats the value as a literal string. '$' is doubled
# to '$$' because docker compose re-interpolates '$name'-shaped sequences it
# finds inside .env values (a single '$' would otherwise silently swallow part
# of the hash); compose un-escapes '$$' back to a literal '$' when it loads .env.
awk -v hash="$MAILPIT_HASH" 'BEGIN{FS=OFS="="} /^MAILPIT_PASSWORD_HASH=/{gsub(/\$/,"$$",hash); print "MAILPIT_PASSWORD_HASH=" hash; next} {print}' .env > .env.tmp
mv .env.tmp .env

echo "generate-env: wrote .env -- edit RSSCHAT_DOMAIN (and SMTP_* for real mail) before deploying"
echo "generate-env: mailpit UI credentials -- user: mail  password: $MAILPIT_PW"

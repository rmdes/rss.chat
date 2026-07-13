#!/bin/bash
#deploy/scripts/e2e-test.sh -- full posting flow against a local stack (RSSCHAT_DOMAIN=localhost)
#Signup happens via the magic link pulled from MailPit's API -- the same path a human takes.
set -euo pipefail
cd "$(dirname "$0")/.."
BASE="https://localhost"
C () { curl -sk "$@"; }

envval () { # read KEY=VALUE literally from .env, no shell evaluation
	grep -E "^$1=" .env | head -1 | cut -d= -f2-
}
MAILPIT_USER=$(envval MAILPIT_USER)
MAILPIT_PASSWORD=$(envval MAILPIT_PASSWORD)
[ -n "$MAILPIT_USER" ] && [ -n "$MAILPIT_PASSWORD" ] || { echo "E2E FAIL: MAILPIT_USER/MAILPIT_PASSWORD not set in .env" >&2; exit 1; }
M () { curl -sk -u "$MAILPIT_USER:$MAILPIT_PASSWORD" "$@"; }

EMAIL="e2e-$(date +%s)@example.com"
NAME="e2e$(date +%s)"
fail () { echo "E2E FAIL: $*" >&2; exit 1; }
jsonget () { node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const v=JSON.parse(s)$1;console.log(v===undefined?'':v)})"; }

echo "-- 1 sign up ($NAME)"
C "$BASE/createnewuser?email=$EMAIL&name=$NAME&urlredirect=$BASE/" > /dev/null
sleep 2

echo "-- 2 magic link from mailpit"
MSGID=$(M "$BASE/mail/api/v1/messages?limit=1" | jsonget ".messages[0].ID")
[ -n "$MSGID" ] || fail "no message in mailpit"
LINK=$(M "$BASE/mail/api/v1/message/$MSGID" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const m=JSON.parse(s);const t=(m.Text||'')+' '+(m.HTML||'');const x=t.match(/https?:\/\/[^\s\"'<>]+/g)||[];console.log(x.find(u=>u.includes('confirm'))||'')})")
[ -n "$LINK" ] || fail "no confirmation link in the email"

echo "-- 3 confirm; capture credentials from the redirect"
REDIR=$(C -o /dev/null -w '%{redirect_url}' "$LINK")
[ -n "$REDIR" ] || fail "confirmation did not redirect (inspect: curl -sk -i '$LINK')"
CODE=$(node -e "console.log(new URL(process.argv[1]).searchParams.get('code')||'')" "$REDIR")
SCREEN=$(node -e "console.log(new URL(process.argv[1]).searchParams.get('screenname')||'')" "$REDIR")
[ "$SCREEN" = "$NAME" ] || fail "screenname mismatch: got '$SCREEN'"
AUTH="emailaddress=$EMAIL&emailcode=$CODE"

echo "-- 4 post"
ID=$(C -G -X POST "$BASE/newpost?$AUTH" --data-urlencode 'jsontext={"description":"hello from the e2e test"}' | jsonget ".id")
[ -n "$ID" ] || fail "newpost returned no id"
sleep 1
C "$BASE/feeds/users/$NAME/rss.xml" | grep -q "hello from the e2e test" || fail "user feed missing the post"
C "$BASE/feeds/users/rss.xml"       | grep -q "hello from the e2e test" || fail "everyone feed missing the post"
C "$BASE/feeds/subs.opml"           | grep -q "$NAME" || fail "subs.opml missing the user"

echo "-- 5 reply -> comments feed"
RID=$(C -G -X POST "$BASE/newpost?$AUTH" --data-urlencode "jsontext={\"description\":\"a reply from e2e\",\"inReplyTo\":$ID}" | jsonget ".id")
[ -n "$RID" ] || fail "reply returned no id"
sleep 1
C "$BASE/feeds/users/$NAME/comments/$ID.xml" | grep -q "a reply from e2e" || fail "comments feed missing the reply"
C "$BASE/feeds/users/$NAME/rss.xml" | grep -q "source:comments" || fail "user feed missing source:comments"

echo "-- 6 like"
C -G -X POST "$BASE/togglelike?$AUTH" --data-urlencode "id=$ID" > /dev/null
LIKES=$(C "$BASE/getiteminfo?id=$ID&format=feedland&screenname=$NAME" | jsonget ".ctLikes")
[ "$LIKES" = "1" ] || fail "like count is '$LIKES', expected 1"

echo "-- 7 edit"
C -G -X POST "$BASE/updatepost?$AUTH" --data-urlencode "jsontext={\"id\":$ID,\"description\":\"hello edited by e2e\"}" > /dev/null
sleep 1
C "$BASE/feeds/users/$NAME/rss.xml" | grep -q "hello edited by e2e" || fail "edit not reflected in feed"

echo "-- 8 threadwalker walks our feeds"
TW=$(mktemp -d)
cp ../examples/threadwalker/walker.js ../examples/threadwalker/package.json "$TW/"
FROM="https://users.rss.network/manton/rss.xml" TO="$BASE/feeds/users/$NAME/rss.xml" perl -pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/' "$TW/walker.js"
FROM="https://rss.chat/?id=204" TO="$BASE/?id=$ID" perl -pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/' "$TW/walker.js"
(cd "$TW" && npm install --silent --no-audit --no-fund && NODE_TLS_REJECT_UNAUTHORIZED=0 node walker.js) > "$TW/out.txt" 2>/dev/null
grep -q "hello edited by e2e" "$TW/out.txt" || fail "threadwalker missed the post"
grep -q "a reply from e2e" "$TW/out.txt" || fail "threadwalker missed the reply"
rm -rf "$TW"

echo "-- 9 delete the reply"
C -G -X POST "$BASE/deletepost?$AUTH" --data-urlencode "id=$RID" > /dev/null
sleep 1
C "$BASE/feeds/users/$NAME/comments/$ID.xml" | grep -q "a reply from e2e" && fail "deleted reply still in comments feed"

echo "-- 10 no external calls"
#the startup config echo legitimately contains "flRssCloudEnabled": false -- not an external call
docker compose logs rsschat 2>&1 | grep -v '"flRssCloudEnabled"' | grep -iE "amazonaws|scripting\.com|rsscloud" && fail "server log mentions external hosts" || true

echo "E2E: ALL CHECKS PASSED"

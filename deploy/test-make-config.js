//deploy/test-make-config.js -- run with: node --test deploy/test-make-config.js
const test = require ("node:test");
const assert = require ("node:assert");
const child = require ("child_process");
const path = require ("path");

const script = path.join (__dirname, "make-config.js");
function run (env) {
	return (child.spawnSync (process.execPath, [script], {env: Object.assign ({}, process.env, env), encoding: "utf8"}));
	}
const goodEnv = {RSSCHAT_DOMAIN: "chat.example.com", MYSQL_PASSWORD: "s3cr3t"};

test ("produces valid json with domain-derived urls", function () {
	const result = run (goodEnv);
	assert.strictEqual (result.status, 0);
	const config = JSON.parse (result.stdout);
	assert.strictEqual (config.myDomain, "chat.example.com");
	assert.strictEqual (config.urlServerForClient, "https://chat.example.com/");
	assert.strictEqual (config.urlWebsocketServerForClient, "wss://chat.example.com/");
	assert.strictEqual (config.rssFeedUrl, "https://chat.example.com/feeds/users/");
	assert.strictEqual (config.opmlListUrl, "https://chat.example.com/feeds/subs.opml");
	assert.strictEqual (config.rssS3Path, "/users/");
	assert.strictEqual (config.opmlS3Path, "/subs.opml");
	assert.strictEqual (config.port, 1452);
	assert.strictEqual (config.websocketPort, 1462);
	assert.strictEqual (config.database.password, "s3cr3t");
	assert.strictEqual (config.database.host, "mysql");
	assert.strictEqual (config.smtpHost, "mailpit");
	assert.strictEqual (config.whitelist, undefined); //empty WHITELIST means open signup
	});
test ("whitelist csv becomes an array", function () {
	const result = run (Object.assign ({WHITELIST: " a@b.com, c@d.com "}, goodEnv));
	assert.deepStrictEqual (JSON.parse (result.stdout).whitelist, ["a@b.com", "c@d.com"]);
	});
test ("rsscloud can be disabled", function () {
	const result = run (Object.assign ({RSSCLOUD_ENABLED: "false"}, goodEnv));
	assert.strictEqual (JSON.parse (result.stdout).flRssCloudEnabled, false);
	});
test ("missing required vars fail with a message", function () {
	const result = run ({RSSCHAT_DOMAIN: "chat.example.com"});
	assert.strictEqual (result.status, 1);
	assert.match (result.stderr, /MYSQL_PASSWORD/);
	});
test ("whitelist of only separators and spaces stays absent", function () {
	const result = run (Object.assign ({WHITELIST: " , , "}, goodEnv));
	assert.strictEqual (JSON.parse (result.stdout).whitelist, undefined);
	});

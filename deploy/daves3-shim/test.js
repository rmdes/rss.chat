const test = require ("node:test");
const assert = require ("node:assert");
const fs = require ("fs");
const path = require ("path");
const os = require ("os");

const feedsRoot = fs.mkdtempSync (path.join (os.tmpdir (), "feeds-shim-test-"));
process.env.FEEDS_ROOT = feedsRoot;
const daves3 = require ("./daves3.js");

test ("newObject writes the file under FEEDS_ROOT, creating folders", function (t, done) {
	daves3.newObject ("/users/dave/rss.xml", "<rss/>", "text/xml", "public-read", function (err, data) {
		assert.strictEqual (err, undefined);
		const written = fs.readFileSync (path.join (feedsRoot, "users/dave/rss.xml"), "utf8");
		assert.strictEqual (written, "<rss/>");
		done ();
		});
	});
test ("newObject overwrites an existing file", function (t, done) {
	daves3.newObject ("/subs.opml", "v1", "text/xml", "public-read", function (err) {
		assert.strictEqual (err, undefined);
		daves3.newObject ("/subs.opml", "v2", "text/xml", "public-read", function (err) {
			assert.strictEqual (err, undefined);
			assert.strictEqual (fs.readFileSync (path.join (feedsRoot, "subs.opml"), "utf8"), "v2");
			done ();
			});
		});
	});
test ("newObject rejects a path that escapes the feeds root", function (t, done) {
	daves3.newObject ("/../evil.xml", "x", "text/xml", "public-read", function (err) {
		assert.ok (err !== undefined);
		assert.match (err.message, /escapes/);
		assert.ok (!fs.existsSync (path.join (feedsRoot, "..", "evil.xml")));
		done ();
		});
	});
test ("any other daves3 call throws loudly", function () {
	assert.throws (function () {
		return (daves3.getObject);
		}, /unimplemented/);
	});

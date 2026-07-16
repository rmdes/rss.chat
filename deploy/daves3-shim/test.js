const test = require ("node:test");
const assert = require ("node:assert");
const daves3 = require ("./daves3.js");

test ("newObject throws -- feeds live in the database, nothing may reach s3", function () {
	assert.throws (function () {
		daves3.newObject ("/users/dave/rss.xml", "<rss/>", "text/xml", "public-read", function () {});
		}, /flFeedsInDatabase/);
	});
test ("any other daves3 call throws too", function () {
	assert.throws (function () {
		return (daves3.getObject);
		}, /daves3 shim/);
	});
test ("introspection probes stay quiet", function () { //a bare require or a console.log must not blow up
	assert.strictEqual (daves3.then, undefined);
	assert.strictEqual (typeof daves3.toString, "function");
	});

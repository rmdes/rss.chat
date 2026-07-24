const test = require ("node:test");
const assert = require ("node:assert");
const AWS = require ("./aws-sdk.js");

test ("the SES client constructs -- davemail builds one while sendmail.js loads", function () {
	const ses = new AWS.SES ({apiVersion: "2010-12-01", region: "us-east-1"});
	assert.strictEqual (typeof ses.sendEmail, "function");
	});
test ("sending through SES throws -- mail leaves over smtp", function () {
	const ses = new AWS.SES ({});
	assert.throws (function () {
		ses.sendEmail ({Destination: {}}, function () {});
		}, /aws-sdk shim/);
	});
test ("any other aws service throws too", function () {
	assert.throws (function () {
		return (AWS.S3);
		}, /aws-sdk shim/);
	});
test ("introspection probes stay quiet", function () { //a bare require or a console.log must not blow up
	assert.strictEqual (AWS.then, undefined);
	assert.strictEqual (typeof AWS.toString, "function");
	});

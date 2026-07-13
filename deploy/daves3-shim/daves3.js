//deploy/daves3-shim/daves3.js -- drop-in replacement for the daves3 package.
//Part of the deploy overlay, not upstream code. Writes "S3 objects" to a local
//folder instead of Amazon; Caddy serves that folder at /feeds/*.
//rssnetwork.js only ever calls newObject. Anything else throws, loudly, so an
//upstream change surfaces as an error instead of silent data loss.

const fs = require ("fs");
const path = require ("path");

const feedsRoot = path.resolve (process.env.FEEDS_ROOT || "/feeds");

function newObject (s3path, data, type, acl, callback) {
	try {
		const relpath = String (s3path).replace (/^\/+/, "");
		const resolved = path.resolve (path.join (feedsRoot, relpath));
		if (!resolved.startsWith (feedsRoot + path.sep)) {
			throw (new Error ("daves3 shim: path escapes the feeds root: " + s3path));
			}
		fs.mkdirSync (path.dirname (resolved), {recursive: true});
		const tmppath = resolved + ".tmp-" + process.pid; //atomic publish: write then rename
		fs.writeFileSync (tmppath, data);
		fs.renameSync (tmppath, resolved);
		if (callback !== undefined) {
			callback (undefined, {location: resolved});
			}
		}
	catch (err) {
		if (callback !== undefined) {
			callback (err);
			}
		}
	}

module.exports = new Proxy ({newObject}, {
	get: function (target, prop) {
		if (typeof prop === "symbol") {
			return (undefined);
			}
		if (prop in target) { //includes Object.prototype (toString etc), which keeps introspection happy
			return (target [prop]);
			}
		if ((prop === "then") || (prop === "inspect")) { //async/console probes
			return (undefined);
			}
		throw (new Error ("daves3 shim: unimplemented call \"" + prop + "\" -- upstream now uses more of daves3 than newObject."));
		}
	});

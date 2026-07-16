//deploy/daves3-shim/daves3.js -- drop-in replacement for the daves3 package.
//Part of the deploy overlay, not upstream code.
//rssnetwork.js requires daves3 unconditionally, but with flFeedsInDatabase set
//(see deploy/make-config.js) every feed write goes to the database instead, so
//nothing here is ever called. This stub keeps the require satisfied without
//pulling Amazon into the image, and throws loudly if that ever stops being
//true -- a config regression or an upstream change surfaces as an error rather
//than as a silent write to somebody else's S3 bucket.

module.exports = new Proxy ({}, {
	get: function (target, prop) {
		if (typeof prop === "symbol") {
			return (undefined);
			}
		if (prop in target) { //Object.prototype (toString etc), which keeps introspection happy
			return (target [prop]);
			}
		if ((prop === "then") || (prop === "inspect")) { //async/console probes
			return (undefined);
			}
		throw (new Error ("daves3 shim: \"" + prop + "\" was called, but this server stores feeds in the database (flFeedsInDatabase). Nothing should reach daves3."));
		}
	});

//deploy/aws-sdk-shim/aws-sdk.js -- drop-in replacement for the aws-sdk package.
//Part of the deploy overlay, not upstream code.
//davemail requires aws-sdk at the top of sendmail.js and constructs an SES client
//while the module loads, before it knows which transport it will use -- so the real
//v2 SDK (101mb, end-of-support) ships in the image for a code path that cannot run
//here: deploy/make-config.js always sets smtpHost, and daveappserver turns that into
//flUseSes: false, which routes every message through nodemailer instead.
//The constructor therefore has to succeed. Anything that would actually talk to
//Amazon throws, so a config regression surfaces as an error rather than as mail
//quietly handed to SES.

const theStub = {
	SES: function () { //davemail does `new AWS.SES ({apiVersion, region})` at load time
		return ({
			sendEmail: function () {
				throw (new Error ("aws-sdk shim: SES.sendEmail was called, but this server sends mail over SMTP (smtpHost is always set, so daveappserver chooses flUseSes: false). Nothing should reach Amazon."));
				}
			});
		}
	};

module.exports = new Proxy (theStub, {
	get: function (target, prop) {
		if (typeof prop === "symbol") {
			return (undefined);
			}
		if (prop in target) { //SES, plus Object.prototype (toString etc), which keeps introspection happy
			return (target [prop]);
			}
		if ((prop === "then") || (prop === "inspect")) { //async/console probes
			return (undefined);
			}
		throw (new Error ("aws-sdk shim: \"" + prop + "\" was requested, but this server talks to no Amazon service. Nothing should reach aws-sdk."));
		}
	});

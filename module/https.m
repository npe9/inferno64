#
# HTTPS client over this tree's own TLS - tls12(2), which verifies the
# server's certificate chain (see its man page for what that does and
# does not cover). Exists so network clients need no host command as a
# transport (CLAUDE.md's own rule; bsky(1)/masto(1) are the first
# users). Include sys.m, keyring.m and tls12.m before this file.
#

Https: module
{
	PATH: con "/dis/lib/https.dis";

	init: fn(): string;

	# One HTTP/1.1 request over TLS. method is "GET"/"POST"/...; url
	# must be https://host[:port]/path?query; hdrs are extra request
	# headers sent as given; body is the request body (nil for none;
	# Content-Length is added automatically when non-nil).
	#
	# Returns (status, response headers, response body, error). error
	# is nil whenever a complete HTTP response came back - an HTTP
	# error status (4xx/5xx) is a result, not an error, and its body
	# is returned like any other (APIs put their diagnostics there).
	# Redirects are not followed. Connection: close is used - one TLS
	# session per request, no reuse.
	#
	# The host is resolved by dialling the name (works when /net/cs
	# is served, e.g. by ndb/cs), falling back to the hosted emu's
	# built-in $Srv resolver - so hostname URLs work in hosted mode
	# even without a connection server running.
	request: fn(method, url: string, hdrs: list of (string, string), body: array of byte):
		(int, list of (string, string), array of byte, string);

	# test seam (httpstest(1), same convention as bsky(1)'s own
	# seams): decode a complete chunked transfer-coding body from a
	# byte buffer, no network involved - the live hosts this tree
	# tests against all answer with Content-Length today, so the
	# chunked path can only be exercised offline.
	chunkedtest: fn(raw: array of byte): (array of byte, string);
};

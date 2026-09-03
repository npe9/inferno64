implement Command;

# httpstest(1) - live test of https(2), the HTTP/1.1-over-tls12(2)
# client that lets network clients off the #C/curl stopgap (step 9 of
# doc/ssl-modernization-plan.md). All legs run against the real
# network:
#
#   1. GET a public Bluesky API endpoint BY HOSTNAME - exercises the
#      $Srv resolver fallback (no /net/cs runs in this emu instance,
#      dialtest(1)'s tracked gap) plus a Content-Length response
#   2. GET mastodon.social's instance endpoint - a large response,
#      historically chunked, exercising whichever framing the server
#      picks (the framing seen is printed, so a PASS says which paths
#      really ran)
#   3. a request for a nonexistent endpoint must return its HTTP
#      error status AS A RESULT with err nil - APIs put diagnostics
#      in error-status bodies, so treating 4xx as failure would break
#      every caller
#   4. a nonexistent hostname must fail with a resolution error
#   5. a literal-IP https URL must FAIL certificate verification end
#      to end: the URL's host is the verification hostname, and no
#      public cert names a bare IP - this drives the full
#      wrong-certificate path through https(2), not just through
#      x509(2) the way tls12test(1)'s controls do

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
include "security.m";
include "tls12.m";
include "https.m";
	https: Https;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

stderr: ref Sys->FD;
failures := 0;

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	https = load Https Https->PATH;
	if(https == nil){
		sys->fprint(stderr, "httpstest: cannot load %s: %r\n", Https->PATH);
		raise "fail:load";
	}
	if((err := https->init()) != nil){
		sys->fprint(stderr, "httpstest: %s\n", err);
		raise "fail:init";
	}

	# 1: hostname URL, public endpoint, JSON back
	(st, hdrs, body, rerr) := https->request("GET",
		"https://public.api.bsky.app/xrpc/app.bsky.actor.getProfile?actor=bsky.app",
		nil, nil);
	if(rerr != nil)
		fail("bsky profile: "+rerr);
	else if(st != 200)
		fail(sys->sprint("bsky profile: status %d, expected 200", st));
	else if(!contains(string body, "bsky.app"))
		fail("bsky profile: response does not mention bsky.app");
	else
		sys->print("public.api.bsky.app: 200, %d bytes (%s): PASS\n",
			len body, framing(hdrs));

	# 2: a big response, framing per the server's choice
	(st, hdrs, body, rerr) = https->request("GET",
		"https://mastodon.social/api/v1/instance", nil, nil);
	if(rerr != nil)
		fail("mastodon instance: "+rerr);
	else if(st != 200)
		fail(sys->sprint("mastodon instance: status %d, expected 200", st));
	else if(!contains(string body, "mastodon.social"))
		fail("mastodon instance: response does not mention mastodon.social");
	else
		sys->print("mastodon.social: 200, %d bytes (%s): PASS\n",
			len body, framing(hdrs));

	# 3: HTTP error statuses are results, not errors
	(st, nil, body, rerr) = https->request("GET",
		"https://bsky.social/xrpc/no.such.endpoint.exists", nil, nil);
	if(rerr != nil)
		fail("error-status leg: transport error instead of a status: "+rerr);
	else if(st < 400 || st > 599)
		fail(sys->sprint("error-status leg: status %d, expected 4xx/5xx", st));
	else
		sys->print("nonexistent endpoint: status %d with %d byte body, err nil: PASS\n", st, len body);

	# 4: resolution failure is an error
	(nil, nil, nil, rerr) = https->request("GET",
		"https://no-such-host.invalid/", nil, nil);
	if(rerr == nil)
		fail("nonexistent hostname SUCCEEDED");
	else
		sys->print("nonexistent hostname: refused (%s): PASS\n", rerr);

	# offline: the chunked transfer-coding decoder, via the module's
	# own test seam - every live host above answers with
	# Content-Length today, so this path cannot be reached over the
	# network. A two-chunk body with a chunk extension and a trailer
	# must decode exactly; a truncated body must error, not hang or
	# crash; a garbage size line must error.
	# the middle chunks' sizes are deliberately multi-digit ("10" =
	# 16 bytes, both digits decimal; "1A" mixes in a hex letter): an
	# early negative control corrupted the decoder's size arithmetic
	# (*16 -> *15) and every original chunk sailed through - a
	# single-digit size never exercises the multiplier, and "1A"
	# routes its second digit through the letter arm, missing a
	# corruption of the digit arm. Both shapes are needed.
	good := array of byte ("5;ext=1\r\nhello\r\n10\r\n, 16 more bytes!\r\n1A\r\n" +
		" and then 26 more bytes...\r\n0\r\nTrailer: x\r\n\r\n");
	want := "hello, 16 more bytes! and then 26 more bytes...";
	(dec, cerr) := https->chunkedtest(good);
	if(cerr != nil)
		fail("chunked decode: "+cerr);
	else if(string dec != want)
		fail(sys->sprint("chunked decode: got %q, expected %q", string dec, want));
	else
		sys->print("chunked decode (multi-digit size, extension, trailer): PASS\n");
	(nil, cerr) = https->chunkedtest(good[0:12]);
	if(cerr == nil)
		fail("truncated chunked body decoded without error");
	else
		sys->print("truncated chunked body: refused (%s): PASS\n", cerr);
	(nil, cerr) = https->chunkedtest(array of byte "zz\r\nhello\r\n0\r\n\r\n");
	if(cerr == nil)
		fail("garbage chunk size line decoded without error");
	else
		sys->print("garbage chunk size: refused: PASS\n");

	# 5: certificate verification failure, end to end - a literal-IP
	# host can never match a public certificate's names
	(nil, nil, nil, rerr) = https->request("GET",
		"https://151.101.1.55/", nil, nil);
	if(rerr == nil)
		fail("literal-IP https URL VERIFIED - certificate checking is not on this path");
	else if(!contains(rerr, "certificate") && !contains(rerr, "tls"))
		fail("literal-IP https URL failed, but not at the TLS/certificate layer: "+rerr);
	else
		sys->print("literal-IP url: refused (%s): PASS\n", rerr);

	if(failures){
		sys->fprint(stderr, "httpstest: %d FAILURE(S)\n", failures);
		raise "fail:test";
	}
	sys->print("all tests passed\n");
}

framing(hdrs: list of (string, string)): string
{
	for(; hdrs != nil; hdrs = tl hdrs){
		(hn, hv) := hd hdrs;
		if(hn == "transfer-encoding" && hv == "chunked")
			return "chunked";
		if(hn == "content-length")
			return "content-length "+hv;
	}
	return "read-to-close";
}

contains(s, sub: string): int
{
	n := len sub;
	for(i := 0; i+n <= len s; i++)
		if(s[i:i+n] == sub)
			return 1;
	return 0;
}

fail(msg: string)
{
	sys->fprint(stderr, "FAIL: %s\n", msg);
	failures++;
}

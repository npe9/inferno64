implement Bsky;

# bsky(1) - Bluesky (AT Protocol) client, first vertical slice: log in
# with a handle + app password, print the home timeline. One network,
# no abstraction, no GUI yet - see man page BUGS.
#
# Transport is https(2) - this tree's OWN TLS 1.2 stack (tls12(2),
# which verifies the server's certificate chain), not a host command.
# This command originally drove the host's curl(1) through #C because
# module/ssl3.m was SSLv3-era and could not reach a modern HTTPS host;
# that stopgap is gone, per CLAUDE.md's rule that no network client
# uses #C as a transport (the SSL modernization it demanded is done -
# doc/ssl-modernization-plan.md). Name resolution still leans on the
# hosted emu's $Srv resolver when no connection server is mounted, so
# hosted mode remains the tested configuration.

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "json.m";
	json: JSON;
	JValue: import json;
include "keyring.m";
include "security.m";
include "tls12.m";
include "https.m";
	https: Https;

Bsky: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
	# test seams, same justification as danby-aerobraking(1)'s own
	# run()/viewtest(): hit real Bluesky endpoints so bskytest(1)
	# exercises the actual https(2)/JSON path this command uses,
	# without needing live credentials.
	pubtest: fn(): string;
	postpubtest: fn(): string;
	feedtest: fn(): string;
};

stderr: ref Sys->FD;

init(nil: ref Draw->Context, argv: list of string)
{
	err := ensureloaded();
	if(err != nil){
		if(sys == nil)
			raise "fail:load";
		fail("bsky: "+err);
	}
	stderr = sys->fildes(2);

	argv = tl argv;
	if(argv == nil || tl argv != nil)
		fail("usage: bsky credfile");
	credfile := hd argv;

	(handle, password, cerr) := readcreds(credfile);
	if(cerr != nil)
		fail("bsky: "+cerr);

	(jwt, nil, lerr) := login(handle, password);
	password = nil;	# done with it; don't keep it around any longer than needed
	if(lerr != nil)
		fail("bsky: login: "+lerr);

	(lines, terr) := timeline(jwt);
	if(terr != nil)
		fail("bsky: timeline: "+terr);

	for(l := lines; l != nil; l = tl l)
		sys->print("%s\n", hd l);
}

# loads each support module independently rather than gating the
# whole block on one variable being nil (see masto.b's own comment on
# this same helper - the real bug it fixes there: a caller that runs
# one test seam before another can leave a later seam's own coarser
# guard wrongly believing everything is already loaded).

ensureloaded(): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	if(https == nil){
		https = load Https Https->PATH;
		if(https == nil)
			return "cannot load Https";
		if((err := https->init()) != nil)
			return err;
	}
	if(bufio == nil)
		bufio = load Bufio Bufio->PATH;
	if(bufio == nil)
		return "cannot load Bufio";
	if(json == nil){
		json = load JSON JSON->PATH;
		if(json == nil)
			return "cannot load JSON";
		json->init(bufio);
	}
	return nil;
}

fail(msg: string)
{
	sys->fprint(stderr, "%s\n", msg);
	raise "fail:bsky";
}

# --- credentials ---
# two lines: handle, then app password (an app password, from Bluesky's
# own Settings > App Passwords - never the real account password, and
# never a literal in source). Never echoed - not even into the argv a
# "ps" could see, which is exactly why this reads a file rather than
# taking the password on the command line.

readcreds(path: string): (string, string, string)
{
	b := bufio->open(path, Bufio->OREAD);
	if(b == nil)
		return (nil, nil, sys->sprint("cannot open %q: %r", path));
	handle := chomp(b.gets('\n'));
	password := chomp(b.gets('\n'));
	b.close();
	if(handle == nil || password == nil)
		return (nil, nil, "credentials file must have handle and app password on two lines");
	return (handle, password, nil);
}

chomp(s: string): string
{
	if(s == nil)
		return nil;
	n := len s;
	while(n > 0 && (s[n-1] == '\n' || s[n-1] == '\r'))
		n--;
	return s[0:n];
}

# --- minimal JSON string helpers ---
# JValue.text() JSON-serializes (quotes) a String value rather than
# returning its raw content - checked in appl/lib/json.b directly
# before assuming otherwise - so extracting a plain string needs its
# own accessor.

jstring(v: ref JValue): string
{
	if(v == nil)
		return nil;
	pick r := v {
	String =>
		return r.s;
	* =>
		return nil;
	}
}

jsonquote(s: string): string
{
	out := "\"";
	for(i := 0; i < len s; i++){
		c := s[i];
		case c {
		'"' =>	out += "\\\"";
		'\\' =>	out += "\\\\";
		'\n' =>	out += "\\n";
		'\r' =>	out += "\\r";
		'\t' =>	out += "\\t";
		* =>
			if(c < 16r20)
				out += sys->sprint("\\u%04x", c);
			else
				out += sys->sprint("%c", c);
		}
	}
	return out+"\"";
}

# --- Bluesky (AT Protocol) calls ---

login(handle, password: string): (string, string, string)
{
	body := sys->sprint("{\"identifier\":%s,\"password\":%s}",
		jsonquote(handle), jsonquote(password));
	(out, err) := fetch("POST",
		"https://bsky.social/xrpc/com.atproto.server.createSession",
		("Content-Type", "application/json") :: nil, body);
	if(err != nil)
		return (nil, nil, err);
	(v, jerr) := json->readjson(bufio->sopen(out));
	if(jerr != nil || v == nil || !v.isobject())
		return (nil, nil, "bad response: "+out);
	errf := v.get("error");
	if(errf != nil)
		return (nil, nil, sys->sprint("%s: %s", jstring(errf), jstring(v.get("message"))));
	jwt := jstring(v.get("accessJwt"));
	if(jwt == nil)
		return (nil, nil, "no accessJwt in response: "+out);
	return (jwt, jstring(v.get("did")), nil);
}

timeline(jwt: string): (list of string, string)
{
	(out, err) := fetch("GET",
		"https://bsky.social/xrpc/app.bsky.feed.getTimeline?limit=30",
		("Authorization", "Bearer "+jwt) :: nil, nil);
	if(err != nil)
		return (nil, err);
	return decode(out);
}

# split out of timeline() so the actual feed-array walk - the code path
# every real invocation of this command runs, and which none of the
# test seams above ever touched - can be driven from a plain JSON
# string, the same shape fetch() itself returns, without a live account.

decode(out: string): (list of string, string)
{
	(v, jerr) := json->readjson(bufio->sopen(out));
	if(jerr != nil || v == nil || !v.isobject())
		return (nil, "bad response: "+out);
	errf := v.get("error");
	if(errf != nil)
		return (nil, sys->sprint("%s: %s", jstring(errf), jstring(v.get("message"))));
	feedf := v.get("feed");
	if(feedf == nil || !feedf.isarray())
		return (nil, "no feed array in response: "+out);
	a: array of ref JValue;
	pick r := feedf {
	Array => a = r.a;
	}
	lines: list of string;
	for(i := 0; i < len a; i++){
		post := a[i].get("post");
		if(post == nil)
			continue;
		handle := "?";
		author := post.get("author");
		if(author != nil){
			h := jstring(author.get("handle"));
			if(h != nil)
				handle = h;
		}
		text := "";
		record := post.get("record");
		if(record != nil){
			t := jstring(record.get("text"));
			if(t != nil)
				text = t;
		}
		lines = sys->sprint("@%s: %s", handle, oneline(text)) :: lines;
	}
	# feed arrives newest-first; the cons above reversed it, so reverse
	# once more to hand back the API's own order.
	rev: list of string;
	for(l := lines; l != nil; l = tl l)
		rev = hd l :: rev;
	return (rev, nil);
}

oneline(s: string): string
{
	out := "";
	for(i := 0; i < len s; i++)
		if(s[i] == '\n')
			out += " / ";
		else
			out += sys->sprint("%c", s[i]);
	return out;
}

# --- transport: https(2), this tree's own TLS ---
# transport-level failures (dial, TLS, certificate verification, HTTP
# framing) come back as err; an HTTP error STATUS does not - Bluesky
# answers errors with a JSON body carrying error/message fields, and
# every caller here decodes that body, so the status would be
# redundant (and curl -s without -f, which this replaced, behaved the
# same way).

fetch(method, url: string, hdrs: list of (string, string), body: string): (string, string)
{
	b: array of byte;
	if(body != nil)
		b = array of byte body;
	(nil, nil, rbody, err) := https->request(method, url, hdrs, b);
	if(err != nil)
		return (nil, err);
	return (string rbody, nil);
}

# --- test seam: decode(), no network needed ---
# the feed-array walk in decode() is the code path every real
# invocation of bsky(1) runs, and none of the other seams here ever
# exercised it (they only ever checked profile/login shapes, never a
# timeline). A four-post JSON array, in the real
# app.bsky.feed.getTimeline response shape (feed: [{post: {author:
# {handle}, record: {text}}}]), exercises: a missing post entirely
# (skipped, not crashed), missing author/record (the "?" and ""
# fallbacks), and the double-reverse meant to preserve the API's own
# newest-first order.

feedtest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "feedtest: "+e;
	body := "{\"feed\":[" +
		"{\"post\":{\"author\":{\"handle\":\"alice.bsky.social\"}," +
		 "\"record\":{\"text\":\"hello world\"}}}," +
		"{\"post\":{\"author\":{\"handle\":\"bob.bsky.social\"}," +
		 "\"record\":{\"text\":\"line one\\nline two\"}}}," +
		"{\"post\":{\"record\":{\"text\":\"no author field\"}}}," +
		"{\"post\":{\"author\":{\"handle\":\"carol.bsky.social\"}}}," +
		"{\"nopost\":true}" +
		"]}";
	(lines, err) := decode(body);
	if(err != nil)
		return "feedtest: "+err;
	want := array[] of {
		"@alice.bsky.social: hello world",
		"@bob.bsky.social: line one / line two",
		"@?: no author field",
		"@carol.bsky.social: ",
	};
	n := len lines;
	got := array[n] of string;
	i := 0;
	for(l := lines; l != nil; l = tl l){
		got[i] = hd l;
		i++;
	}
	if(n != len want)
		return sys->sprint("feedtest: got %d lines, want %d", n, len want);
	for(i = 0; i < n; i++)
		if(got[i] != want[i])
			return sys->sprint("feedtest: line %d = %q, want %q", i, got[i], want[i]);
	return nil;
}

# --- test seam ---
# app.bsky.actor.getProfile is a real, public, unauthenticated Bluesky
# endpoint (Bluesky's own read-only AppView, no session needed) - this
# drives the exact same fetch()/json path login()/timeline() use, end
# to end, over the real network, without needing a credentials file.

pubtest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "pubtest: "+e;
	(out, err) := fetch("GET",
		"https://public.api.bsky.app/xrpc/app.bsky.actor.getProfile?actor=bsky.app",
		nil, nil);
	if(err != nil)
		return "pubtest: "+err;
	(v, jerr) := json->readjson(bufio->sopen(out));
	if(jerr != nil || v == nil || !v.isobject())
		return "pubtest: bad response: "+out;
	errf := v.get("error");
	if(errf != nil)
		return "pubtest: server error: "+jstring(errf);
	handle := jstring(v.get("handle"));
	if(handle != "bsky.app")
		return sys->sprint("pubtest: got handle %q, want \"bsky.app\": %s", handle, out);
	return nil;
}

# login() is the only caller of fetch()'s POST-with-request-body
# branch, and of jsonquote() - neither is exercised by pubtest() above,
# which only ever GETs. A deliberately bogus login can't reach a real
# account, but bsky.social can only answer with a real, well-formed
# error (checked live against the real server, not guessed:
# com.atproto.server.createSession replied 'AuthenticationRequired:
# Invalid identifier or password' to a bogus identifier/password pair
# on a first attempt) if the JSON body this sends actually arrived
# intact - a body that got mangled or truncated in transit would
# instead fail to parse as the request Bluesky expects (a transport
# failure, or decode()'s own "bad response"/"no accessJwt" fallback
# text, neither of which is a real decoded error field). Accepts any of the error codes the real server is known to
# answer a bogus login with, not just one: repeated runs of this exact
# test in one session are themselves enough to trip bsky.social's own
# rate limiter, which answers with RateLimitExceeded instead of
# AuthenticationRequired - a different real, well-formed server error,
# not a sign anything here is broken (confirmed by re-running: the
# error persisted across repeats once the limiter had tripped, and
# only the code -> text mattered, not which specific code).

postpubtest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "postpubtest: "+e;
	(nil, nil, lerr) := login("x.invalid-handle-for-testing", "wrong-password-x");
	if(lerr == nil)
		return "postpubtest: bogus login unexpectedly succeeded";
	if(!prefix("AuthenticationRequired:", lerr) && !prefix("RateLimitExceeded:", lerr))
		return "postpubtest: want a real decoded server error, got: "+lerr;
	return nil;
}

prefix(p, s: string): int
{
	return len s >= len p && s[0:len p] == p;
}

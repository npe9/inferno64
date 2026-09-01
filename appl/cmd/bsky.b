implement Bsky;

# bsky(1) - Bluesky (AT Protocol) client, first vertical slice: log in
# with a handle + app password, print the home timeline. One network,
# no abstraction, no GUI yet - see man page BUGS.
#
# This tree's own module/ssl3.m is SSLv3-era: RC4/DES/3DES/IDEA bulk
# ciphers, static RSA/DH key exchange, no AES, no GCM/ChaCha, no SNI
# (checked directly - its own cipher-suite list and emu/port/devssl.c's,
# neither names anything past that) - it cannot complete a TLS 1.2+
# handshake, which is what bsky.social (and every other real HTTPS host
# now) requires. Rather than build a fake TLS stack, or claim this can
# reach the network when it can't, this drives the HOST's own curl(1)
# (real TLS 1.3, SNI, everything) through #C (see man/3/cmd) - the
# "virtualize the capability, not the host structure" shape, and the
# same host-command-execution device p9/cmd/prtest.b's runhost() uses
# as a test oracle. This is therefore hosted-mode only: it does not
# work standalone under a native kernel with no #C.

include "sys.m";
	sys: Sys;
include "draw.m";
include "string.m";
	str: String;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "json.m";
	json: JSON;
	JValue: import json;

Bsky: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
	# test seams, same justification as danby-aerobraking(1)'s own
	# run()/viewtest(): hit real Bluesky endpoints so bskytest(1)
	# exercises the actual #C/curl/JSON path this command uses,
	# without needing live credentials.
	pubtest: fn(): string;
	postpubtest: fn(): string;
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
	if(str == nil)
		str = load String String->PATH;
	if(str == nil)
		return "cannot load String";
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
	args := "-s" :: "-S" ::
		"-X" :: "POST" ::
		"-H" :: "Content-Type: application/json" ::
		"--data-binary" :: "@-" ::
		"https://bsky.social/xrpc/com.atproto.server.createSession" :: nil;
	(out, err) := curl(args, body);
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
	args := "-s" :: "-S" ::
		"-H" :: "Authorization: Bearer "+jwt ::
		"https://bsky.social/xrpc/app.bsky.feed.getTimeline?limit=30" :: nil;
	(out, err) := curl(args, nil);
	if(err != nil)
		return (nil, err);
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

# --- host curl, via #C (see man/3/cmd) ---
# adapted from p9/cmd/prtest.b's own runhost() (itself adapted from
# appl/cmd/os.b's working use of this device): wait must be opened
# before "exec" is written to ctl, and /data is opened once for
# writing (the request body, if any) and once for reading (the
# response), not the same fd both ways. Body and response here are
# both small (a short JSON object, or none, in; one HTTP response
# out) so a plain blocking write-then-read is safe - no need for
# os.b's concurrent copy() procs, which exist there for a large or
# open-ended interactive pass-through this never does.

curl(args: list of string, body: string): (string, string)
{
	(ok, nil) := sys->stat("/cmd/clone");
	if(ok == -1)
		if(sys->bind("#C", "/", Sys->MBEFORE) < 0)
			return (nil, sys->sprint("bind #C /: %r"));

	cfd := sys->open("/cmd/clone", Sys->ORDWR);
	if(cfd == nil)
		return (nil, sys->sprint("cannot open /cmd/clone: %r"));
	buf := array[32] of byte;
	n := sys->read(cfd, buf, len buf);
	if(n <= 0)
		return (nil, "cannot read /cmd/clone");
	dir := "/cmd/"+string buf[0:n];

	wfd := sys->open(dir+"/wait", Sys->OREAD);

	cmd := "curl" :: args;
	if(sys->fprint(cfd, "exec %s", str->quoted(cmd)) < 0)
		return (nil, sys->sprint("cannot exec curl: %r"));

	if(body != nil){
		tocmd := sys->open(dir+"/data", Sys->OWRITE);
		if(tocmd == nil)
			return (nil, sys->sprint("cannot open %s/data for writing: %r", dir));
		bb := array of byte body;
		if(sys->write(tocmd, bb, len bb) != len bb)
			return (nil, sys->sprint("short write to curl stdin: %r"));
		tocmd = nil;	# close: signals EOF on curl's stdin
	}

	fromcmd := sys->open(dir+"/data", Sys->OREAD);
	if(fromcmd == nil)
		return (nil, sys->sprint("cannot open %s/data for reading: %r", dir));
	errcmd := sys->open(dir+"/stderr", Sys->OREAD);

	out := "";
	rb := array[8192] of byte;
	for(;;){
		rn := sys->read(fromcmd, rb, len rb);
		if(rn <= 0)
			break;
		out += string rb[0:rn];
	}
	errout := "";
	if(errcmd != nil){
		for(;;){
			rn := sys->read(errcmd, rb, len rb);
			if(rn <= 0)
				break;
			errout += string rb[0:rn];
		}
	}
	# curl's own exit status (via #C's "wait" line: pid user sys real
	# status - the 5th field is empty on a clean exit, matching
	# appl/cmd/os.b's own use of this same device). Checked first: a
	# curl-level failure (bad host, connection refused, ...) can leave
	# BOTH out and errout empty, which without this would silently
	# come back as success with an empty body, rather than the real
	# failure it is.
	if(wfd != nil){
		sb := array[1024] of byte;
		wn := sys->read(wfd, sb, len sb);
		if(wn > 0){
			flds := str->unquoted(string sb[0:wn]);
			if(len flds >= 5){
				waitstatus := hd tl tl tl tl flds;
				if(waitstatus != nil){
					msg := "curl: "+waitstatus;
					if(errout != nil)
						msg += ": "+errout;
					return (nil, msg);
				}
			}
		}
	}
	if(out == nil && errout != nil)
		return (nil, errout);
	return (out, nil);
}

# --- test seam ---
# app.bsky.actor.getProfile is a real, public, unauthenticated Bluesky
# endpoint (Bluesky's own read-only AppView, no session needed) - this
# drives the exact same curl()/json path login()/timeline() use, end
# to end, over the real network, without needing a credentials file.

pubtest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "pubtest: "+e;
	args := "-s" :: "-S" ::
		"https://public.api.bsky.app/xrpc/app.bsky.actor.getProfile?actor=bsky.app" :: nil;
	(out, err) := curl(args, nil);
	if(err != nil)
		return "pubtest: curl: "+err;
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

# login() is the only caller of curl()'s request-body (OWRITE /data)
# branch, and of jsonquote() - neither is exercised by pubtest() above,
# which only ever GETs. A deliberately bogus login can't reach a real
# account, but bsky.social can only answer with the SPECIFIC
# "AuthenticationRequired" shape (checked live against the real
# server, not guessed: com.atproto.server.createSession replied
# 'AuthenticationRequired: Invalid identifier or password' to a bogus
# identifier/password pair) if the JSON body this sends actually
# arrived intact - a body that got mangled or truncated by the write/
# close-to-EOF path would instead fail to parse as the request Bluesky
# expects (a different, distinguishable error shape, e.g. InvalidRequest
# or a straight curl-level failure).

postpubtest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "postpubtest: "+e;
	(nil, nil, lerr) := login("x.invalid-handle-for-testing", "wrong-password-x");
	if(lerr == nil)
		return "postpubtest: bogus login unexpectedly succeeded";
	if(!prefix("AuthenticationRequired:", lerr))
		return "postpubtest: want AuthenticationRequired error, got: "+lerr;
	return nil;
}

prefix(p, s: string): int
{
	return len s >= len p && s[0:len p] == p;
}

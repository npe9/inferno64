implement Masto;

# masto(1) - Mastodon client, second vertical slice (see bsky(1) for
# the first, and its own header comment for why this drives host
# curl(1) through #C rather than this tree's own SSLv3-era module/
# ssl3.m: the same reasoning applies here unchanged, so it isn't
# repeated in full - see bsky.b).
#
# Deliberately self-contained, not sharing curl()/jstring()/jsonquote()
# with bsky.b: matches this tree's own standalone-command convention
# (appl/danby/aerobraking.b is standalone for the same reason - "one
# file, nothing else"), and a shared plumbing library is a decision to
# make once a second real client has actually proven what the shared
# shape needs to be, not before (see bsky.b's own commit message).
#
# Auth is a personal access token (Settings > Development > New
# Application, with "read" scope), not the OAuth2 redirect dance -
# Mastodon supports this directly, so there is no authorization-code
# exchange to implement, matching Bluesky's own app-password shortcut.

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

Masto: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
	# test seams, same justification as bsky.b's pubtest()
	pubtest: fn(): string;
	htmltest: fn(): string;
	feedtest: fn(): string;
};

stderr: ref Sys->FD;

init(nil: ref Draw->Context, argv: list of string)
{
	err := ensureloaded();
	if(err != nil){
		if(sys == nil)
			raise "fail:load";
		fail("masto: "+err);
	}
	stderr = sys->fildes(2);

	argv = tl argv;
	if(argv == nil || tl argv != nil)
		fail("usage: masto credfile");
	credfile := hd argv;

	(inst, token, cerr) := readcreds(credfile);
	if(cerr != nil)
		fail("masto: "+cerr);

	(lines, terr) := timeline(inst, token);
	token = nil;	# done with it; don't keep it around any longer than needed
	if(terr != nil)
		fail("masto: timeline: "+terr);

	for(l := lines; l != nil; l = tl l)
		sys->print("%s\n", hd l);
}

# loads each support module independently rather than gating the
# whole block on one variable being nil - a real bug, found by
# actually running the tests in an order that exposed it: htmltest()
# only ever needed sys, so a caller that ran htmltest() before
# pubtest() left pubtest()'s own old "if(sys == nil){ load
# everything }" guard skipping str/bufio/json entirely, since sys
# was already set - "module not loaded" calling through a still-nil
# module reference, not a real load failure.

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
	raise "fail:masto";
}

# --- credentials ---
# two lines: instance hostname (no scheme - "mastodon.social", not
# "https://mastodon.social"), then a personal access token. Never a
# literal in source, never on a command line, never logged.

readcreds(path: string): (string, string, string)
{
	b := bufio->open(path, Bufio->OREAD);
	if(b == nil)
		return (nil, nil, sys->sprint("cannot open %q: %r", path));
	inst := chomp(b.gets('\n'));
	token := chomp(b.gets('\n'));
	b.close();
	if(inst == nil || token == nil)
		return (nil, nil, "credentials file must have instance hostname and access token on two lines");
	return (inst, token, nil);
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

# --- minimal JSON string helper (see bsky.b: JValue.text() quotes) ---

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

# --- Mastodon (REST) calls ---

timeline(inst, token: string): (list of string, string)
{
	args := "-s" :: "-S" ::
		"-H" :: "Authorization: Bearer "+token ::
		"https://"+inst+"/api/v1/timelines/home?limit=30" :: nil;
	(out, err) := curl(args);
	if(err != nil)
		return (nil, err);
	return decode(out);
}

# split out of timeline() so the actual status-array walk - the code
# path every real invocation of this command runs, and which none of
# the test seams above ever touched - can be driven from a plain JSON
# string, the same shape curl() itself returns, without a live account.

decode(out: string): (list of string, string)
{
	(v, jerr) := json->readjson(bufio->sopen(out));
	if(jerr != nil || v == nil)
		return (nil, "bad response: "+out);
	if(v.isobject()){
		# an object response here is Mastodon's own error shape
		# ({"error":"..."}), never a timeline (that's always an array)
		errf := v.get("error");
		if(errf != nil)
			return (nil, "server error: "+jstring(errf));
		return (nil, "unexpected response: "+out);
	}
	if(!v.isarray())
		return (nil, "unexpected response: "+out);
	a: array of ref JValue;
	pick r := v {
	Array => a = r.a;
	}
	lines: list of string;
	for(i := 0; i < len a; i++){
		status := a[i];
		handle := "?";
		account := status.get("account");
		if(account != nil){
			h := jstring(account.get("acct"));
			if(h != nil)
				handle = h;
		}
		text := "";
		t := jstring(status.get("content"));
		if(t != nil)
			text = detag(t);
		lines = sys->sprint("@%s: %s", handle, oneline(text)) :: lines;
	}
	# the API hands back newest-first; the cons above reversed it, so
	# reverse once more to keep that same order.
	rev: list of string;
	for(l := lines; l != nil; l = tl l)
		rev = hd l :: rev;
	return (rev, nil);
}

# Mastodon's own "content" field is a small fragment of HTML (typically
# <p>...</p>, with <br> for line breaks and <a>/<span> for mentions and
# hashtags) - not plain text. Strip tags and decode the handful of
# entities Mastodon's own renderer actually emits, rather than pull in
# a real HTML parser for a few paragraphs of status text.

detag(s: string): string
{
	out := "";
	tag := "";
	intag := 0;
	inquote := 0;	# 0, or the quote character currently open
	for(i := 0; i < len s; i++){
		c := s[i];
		if(intag){
			if(inquote != 0){
				# a '>' inside a quoted attribute value (e.g. a
				# title="a > b") does not end the tag - without this,
				# it would end the tag early and leak the rest of the
				# markup into the output as plain text (this tree's
				# own man page named the gap; closing it here rather
				# than leaving it as a documented limitation).
				if(c == inquote)
					inquote = 0;
				tag += sys->sprint("%c", c);
				continue;
			}
			if(c == '"' || c == '\''){
				inquote = c;
				tag += sys->sprint("%c", c);
				continue;
			}
			if(c == '>'){
				intag = 0;
				# <br> and </p> are the two tags Mastodon's own
				# content actually uses to separate lines/paragraphs -
				# stripping them with no replacement glued adjacent
				# words together (found by tracing this by hand, not
				# by a failing run: "line1<br>line2" detagged straight
				# to "line1line2").
				if(isbreak(tag))
					out += "\n";
				tag = "";
				continue;
			}
			tag += sys->sprint("%c", c);
			continue;
		}
		if(c == '<'){
			intag = 1;
			tag = "";
			inquote = 0;
			continue;
		}
		out += sys->sprint("%c", c);
	}
	out = unentity(out);
	return trim(out);
}

isbreak(tag: string): int
{
	t := lower(tag);
	n := len t;
	if(n > 0 && t[n-1] == '/')	# self-closing <br/>
		n--;
	sp := n;
	for(i := 0; i < n; i++)
		if(t[i] == ' ' || t[i] == '\t'){
			sp = i;
			break;
		}
	name := t[0:sp];
	return name == "br" || name == "/p";
}

lower(s: string): string
{
	out := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c >= 'A' && c <= 'Z')
			c = c-'A'+'a';
		out += sys->sprint("%c", c);
	}
	return out;
}

trim(s: string): string
{
	n := len s;
	while(n > 0 && s[n-1] == '\n')
		n--;
	i := 0;
	while(i < n && s[i] == '\n')
		i++;
	return s[i:n];
}

unentity(s: string): string
{
	out := "";
	i := 0;
	while(i < len s){
		if(s[i] == '&'){
			(ent, rest) := entityat(s, i);
			if(ent != nil){
				out += ent;
				i = rest;
				continue;
			}
		}
		out += sys->sprint("%c", s[i]);
		i++;
	}
	return out;
}

entityat(s: string, i: int): (string, int)
{
	n := len s;
	j := i+1;
	while(j < n && j < i+10 && s[j] != ';')
		j++;
	if(j >= n || s[j] != ';')
		return (nil, i);
	name := s[i+1:j];
	e := "";
	case name {
	"amp" =>	e = "&";
	"lt" =>	e = "<";
	"gt" =>	e = ">";
	"quot" =>	e = "\"";
	"apos" =>	e = "'";
	"#39" =>	e = "'";
	* =>	return (nil, i);
	}
	return (e, j+1);
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
# GET-only here (no request body needed by anything masto(1) itself
# calls), so this is simpler than bsky.b's own curl() - see that
# file's comment for the write-then-read /data protocol this is
# adapted from, which this doesn't need.

curl(args: list of string): (string, string)
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
	# curl's own exit status (see bsky.b's curl() for why this is
	# checked first, not just errout: a curl-level failure can leave
	# both out and errout empty, which would otherwise silently come
	# back as success with an empty body).
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

# --- test seam: decode(), no network needed ---
# the status-array walk in decode() is the code path every real
# invocation of masto(1) runs, and none of the seams above ever
# exercised it (they only ever checked instance metadata, never a
# timeline shape). A four-status JSON array, built by hand in the
# real shape api/v1/timelines/home returns (checked against Mastodon's
# own documented response shape, and against the real content-HTML
# shape seen live in pubtest()'s own api/v1/instance response),
# exercises: the account/content fields present and absent (the "?"
# and "" fallbacks), <br> handling composed with detag() the same way
# the real caller composes it, entity decoding, and the double-reverse
# that's meant to preserve the API's own newest-first order.

feedtest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "feedtest: "+e;
	body := "[" +
		"{\"account\":{\"acct\":\"alice@example.social\"}," +
		 "\"content\":\"<p>hello &amp; welcome</p>\"}," +
		"{\"account\":{\"acct\":\"bob@example.social\"}," +
		 "\"content\":\"<p>line one<br>line two</p>\"}," +
		"{\"content\":\"<p>no account field</p>\"}," +
		"{\"account\":{\"acct\":\"carol@example.social\"}}" +
		"]";
	(lines, err) := decode(body);
	if(err != nil)
		return "feedtest: "+err;
	want := array[] of {
		"@alice@example.social: hello & welcome",
		"@bob@example.social: line one / line two",
		"@?: no account field",
		"@carol@example.social: ",
	};
	got: array of string;
	n := len lines;
	got = array[n] of string;
	i := 0;
	for(l := lines; l != nil; l = tl l){
		got[i] = hd l;
		i++;
	}
	if(n != len want)
		return sys->sprint("feedtest: got %d lines, want %d: %s", n, len want, out2str(got));
	for(i = 0; i < n; i++)
		if(got[i] != want[i])
			return sys->sprint("feedtest: line %d = %q, want %q", i, got[i], want[i]);
	return nil;
}

out2str(a: array of string): string
{
	s := "";
	for(i := 0; i < len a; i++){
		if(i != 0)
			s += " | ";
		s += a[i];
	}
	return s;
}

# --- test seam: detag()/unentity(), no network needed ---
# a pure function, so a table of input HTML fragment -> expected
# plain text is a real, deterministic regression test - this is the
# one that caught the <br>/</p> gluing bug above (found by tracing
# the code by hand, then confirmed here: "line1<br>line2" really did
# come out "line1line2" before the isbreak() fix, and does not now).

htmltest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "htmltest: "+e;
	cases := array[] of {
		("<p>hello</p>", "hello"),
		("<p>a &amp; b</p>", "a & b"),
		("line1<br>line2", "line1\nline2"),
		("line1<br/>line2", "line1\nline2"),
		("<p>first</p><p>second</p>", "first\nsecond"),
		("<a href=\"http://x\">link</a> text", "link text"),
		("a &lt;tag&gt; here", "a <tag> here"),
		("a & b", "a & b"),
		("trailing &amp", "trailing &amp"),
		("&amp;&amp;", "&&"),
		# unterminated real entity name is longer than entityat()'s own
		# 9-char cap - traced by hand: the cap stops the scan before it
		# ever reaches the real ";", so this falls through to literal
		# passthrough rather than actually finding and rejecting the
		# terminator; the OUTPUT is the same (unrecognized -> literal)
		# either way, but worth pinning down since it's not obviously
		# the intended path.
		("&unknownentity;text", "&unknownentity;text"),
		("a<br><br>b", "a\n\nb"),
		("<a title=\"a > b\" href=\"http://x\">link</a> text", "link text"),
	};
	for(i := 0; i < len cases; i++){
		(input, want) := cases[i];
		got := detag(input);
		if(got != want)
			return sys->sprint("htmltest: detag(%q) = %q, want %q", input, got, want);
	}
	return nil;
}

# --- test seam ---
# api/v1/instance is Mastodon's own real public, unauthenticated
# endpoint (a server description, not a session) - drives the exact
# same curl()/json path timeline() uses, over the real network,
# without needing an access token.

pubtest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "pubtest: "+e;
	args := "-s" :: "-S" :: "https://mastodon.social/api/v1/instance" :: nil;
	(out, err) := curl(args);
	if(err != nil)
		return "pubtest: curl: "+err;
	(v, jerr) := json->readjson(bufio->sopen(out));
	if(jerr != nil || v == nil || !v.isobject())
		return "pubtest: bad response: "+out;
	title := jstring(v.get("title"));
	if(title == nil)
		return "pubtest: no title in response: "+out;
	return nil;
}

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
	# test seam, same justification as bsky.b's pubtest()
	pubtest: fn(): string;
};

stderr: ref Sys->FD;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	bufio = load Bufio Bufio->PATH;
	json = load JSON JSON->PATH;
	if(sys == nil)
		raise "fail:load";
	stderr = sys->fildes(2);
	if(str == nil || bufio == nil || json == nil)
		fail("masto: cannot load support modules");
	json->init(bufio);

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
	intag := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c == '<'){
			intag = 1;
			continue;
		}
		if(c == '>'){
			intag = 0;
			continue;
		}
		if(!intag)
			out += sys->sprint("%c", c);
	}
	out = unentity(out);
	return out;
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
	if(wfd != nil){
		sb := array[1024] of byte;
		sys->read(wfd, sb, len sb);
	}
	if(out == nil && errout != nil)
		return (nil, errout);
	return (out, nil);
}

# --- test seam ---
# api/v1/instance is Mastodon's own real public, unauthenticated
# endpoint (a server description, not a session) - drives the exact
# same curl()/json path timeline() uses, over the real network,
# without needing an access token.

pubtest(): string
{
	if(sys == nil){
		sys = load Sys Sys->PATH;
		str = load String String->PATH;
		bufio = load Bufio Bufio->PATH;
		json = load JSON JSON->PATH;
		if(sys == nil || str == nil || bufio == nil || json == nil)
			return "pubtest: cannot load support modules";
		json->init(bufio);
	}
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

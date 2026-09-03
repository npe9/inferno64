implement Masto;

# masto(1) - Mastodon client: timeline, posting, replies, favourites,
# boosts, follows, notifications, profiles and threads. Transport is
# https(2) - this tree's own TLS 1.2 stack (tls12(2), which verifies
# the server's certificate chain), not a host command; the original
# #C/curl stopgap is gone, per CLAUDE.md's rule that no network
# client uses #C as a transport (see bsky.b's header and
# doc/ssl-modernization-plan.md).
#
# Deliberately self-contained, not sharing fetch()/jstring() plumbing
# with bsky.b: matches this tree's own standalone-command convention
# (appl/danby/aerobraking.b is standalone for the same reason - "one
# file, nothing else"), and a shared plumbing library is a decision to
# make once a third real client has actually proven what the shared
# shape needs to be, not before.
#
# Auth is a personal access token (Settings > Development > New
# Application - "read" scope suffices for reading, "write" and
# "follow" for the rest), not the OAuth2 redirect dance - Mastodon
# supports this directly, so there is no authorization-code exchange
# to implement, matching Bluesky's own app-password shortcut.

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

Masto: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
	# test seams, same justification as bsky.b's: offline seams
	# decode hand-built JSON in each endpoint's real shape; live
	# seams hit real public or bogus-auth endpoints - no credentials
	# needed by any of them.
	pubtest: fn(): string;
	htmltest: fn(): string;
	feedtest: fn(): string;
	notiftest: fn(): string;
	profiletest: fn(): string;
	contexttest: fn(): string;
	buildtest: fn(): string;
	lookuptest: fn(): string;
	livecontexttest: fn(): string;
	authposttest: fn(): string;
};

stderr: ref Sys->FD;

USAGE: con "usage: masto credfile [timeline [-n nnn] [-max id] [-v] | post text | reply id text | fav id | boost id | follow acct | notifications [-n nnn] | profile [acct] | thread id]";

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
	if(argv == nil)
		fail(USAGE);
	credfile := hd argv;
	argv = tl argv;
	cmd := "timeline";
	if(argv != nil){
		cmd = hd argv;
		argv = tl argv;
	}
	# reject an unknown command before reading credentials or
	# touching the network (same reasoning as bsky.b's own check)
	case cmd {
	"timeline" or "post" or "reply" or "fav" or "boost" or
	"follow" or "notifications" or "profile" or "thread" =>
		;
	* =>
		fail(USAGE);
	}

	(inst, token, cerr) := readcreds(credfile);
	if(cerr != nil)
		fail("masto: "+cerr);

	case cmd {
	"timeline" =>	cmdtimeline(inst, token, argv);
	"post" =>	cmdpost(inst, token, nil, argv);
	"reply" =>
		if(argv == nil || tl argv == nil)
			fail(USAGE);
		cmdpost(inst, token, hd argv, tl argv);
	"fav" =>	cmdaction(inst, token, "favourite", "favourited", argv);
	"boost" =>	cmdaction(inst, token, "reblog", "boosted", argv);
	"follow" =>	cmdfollow(inst, token, argv);
	"notifications" =>	cmdnotifications(inst, token, argv);
	"profile" =>	cmdprofile(inst, token, argv);
	"thread" =>	cmdthread(inst, token, argv);
	* =>		fail(USAGE);
	}
}

# --- subcommands ---

cmdtimeline(inst, token: string, argv: list of string)
{
	limit := 30;
	maxid := "";
	verbose := 0;
	for(; argv != nil; argv = tl argv){
		case hd argv {
		"-n" =>
			argv = tl argv;
			if(argv == nil)
				fail(USAGE);
			limit = int hd argv;
		"-max" =>
			argv = tl argv;
			if(argv == nil)
				fail(USAGE);
			maxid = hd argv;
		"-v" =>
			verbose = 1;
		* =>
			fail(USAGE);
		}
	}
	if(limit < 1 || limit > 40)
		fail("masto: -n must be 1..40");
	url := sys->sprint("https://%s/api/v1/timelines/home?limit=%d", inst, limit);
	if(maxid != "")
		url += "&max_id="+maxid;
	(out, err) := authget(token, url);
	if(err != nil)
		fail("masto: timeline: "+err);
	(lines, lastid, derr) := decode(out, verbose);
	if(derr != nil)
		fail("masto: timeline: "+derr);
	for(l := lines; l != nil; l = tl l)
		sys->print("%s\n", hd l);
	if(lastid != nil)
		sys->print("more: masto ... timeline -max %s\n", lastid);
}

cmdpost(inst, token, inreplyto: string, argv: list of string)
{
	text := joinargs(argv);
	if(text == "")
		fail(USAGE);
	(out, err) := fetch("POST",
		sys->sprint("https://%s/api/v1/statuses", inst),
		("Authorization", "Bearer "+token) ::
		("Content-Type", "application/json") :: nil,
		statusbody(text, inreplyto));
	if(err != nil)
		fail("masto: post: "+err);
	(id, url, derr) := postresult(out);
	if(derr != nil)
		fail("masto: post: "+derr);
	verb := "posted";
	if(inreplyto != nil)
		verb = "replied";
	sys->print("%s %s (%s)\n", verb, id, url);
}

# favourite/reblog: an empty-bodied POST to the status's action
# endpoint; the response is the (updated) status itself

cmdaction(inst, token, action, verb: string, argv: list of string)
{
	if(argv == nil || tl argv != nil)
		fail(USAGE);
	id := hd argv;
	(out, err) := fetch("POST",
		sys->sprint("https://%s/api/v1/statuses/%s/%s", inst, id, action),
		("Authorization", "Bearer "+token) :: nil,
		"");
	if(err != nil)
		fail("masto: "+verb+": "+err);
	(rid, nil, derr) := postresult(out);
	if(derr != nil)
		fail("masto: "+verb+": "+derr);
	sys->print("%s %s\n", verb, rid);
}

cmdfollow(inst, token: string, argv: list of string)
{
	if(argv == nil || tl argv != nil)
		fail(USAGE);
	(id, acct, lerr) := lookup(inst, token, hd argv);
	if(lerr != nil)
		fail("masto: follow: "+lerr);
	(out, err) := fetch("POST",
		sys->sprint("https://%s/api/v1/accounts/%s/follow", inst, id),
		("Authorization", "Bearer "+token) :: nil,
		"");
	if(err != nil)
		fail("masto: follow: "+err);
	(v, jerr) := json->readjson(bufio->sopen(out));
	if(jerr != nil || v == nil || !v.isobject())
		fail("masto: follow: bad response: "+out);
	errf := v.get("error");
	if(errf != nil)
		fail("masto: follow: server error: "+jstring(errf));
	sys->print("followed @%s (%s)\n", acct, id);
}

cmdnotifications(inst, token: string, argv: list of string)
{
	limit := 30;
	for(; argv != nil; argv = tl argv){
		case hd argv {
		"-n" =>
			argv = tl argv;
			if(argv == nil)
				fail(USAGE);
			limit = int hd argv;
		* =>
			fail(USAGE);
		}
	}
	if(limit < 1 || limit > 40)
		fail("masto: -n must be 1..40");
	url := sys->sprint("https://%s/api/v1/notifications?limit=%d", inst, limit);
	(out, err) := authget(token, url);
	if(err != nil)
		fail("masto: notifications: "+err);
	(lines, derr) := notifdecode(out);
	if(derr != nil)
		fail("masto: notifications: "+derr);
	for(l := lines; l != nil; l = tl l)
		sys->print("%s\n", hd l);
}

cmdprofile(inst, token: string, argv: list of string)
{
	out, err: string;
	if(argv == nil)
		(out, err) = authget(token,
			sys->sprint("https://%s/api/v1/accounts/verify_credentials", inst));
	else if(tl argv == nil)
		(out, err) = authget(token,
			sys->sprint("https://%s/api/v1/accounts/lookup?acct=%s", inst, hd argv));
	else
		fail(USAGE);
	if(err != nil)
		fail("masto: profile: "+err);
	(lines, derr) := profiledecode(out);
	if(derr != nil)
		fail("masto: profile: "+derr);
	for(l := lines; l != nil; l = tl l)
		sys->print("%s\n", hd l);
}

cmdthread(inst, token: string, argv: list of string)
{
	if(argv == nil || tl argv != nil)
		fail(USAGE);
	id := hd argv;
	(sout, serr) := authget(token, sys->sprint("https://%s/api/v1/statuses/%s", inst, id));
	if(serr != nil)
		fail("masto: thread: "+serr);
	(cout, cerr) := authget(token, sys->sprint("https://%s/api/v1/statuses/%s/context", inst, id));
	if(cerr != nil)
		fail("masto: thread: "+cerr);
	(lines, derr) := contextdecode(sout, cout);
	if(derr != nil)
		fail("masto: thread: "+derr);
	for(l := lines; l != nil; l = tl l)
		sys->print("%s\n", hd l);
}

# loads each support module independently rather than gating the
# whole block on one variable being nil - a real bug, found by
# actually running the tests in an order that exposed it: htmltest()
# only ever needed sys, so a caller that ran htmltest() before
# pubtest() left pubtest()'s own old "if(sys == nil){ load
# everything }" guard skipping the other modules entirely, since sys
# was already set - "module not loaded" calling through a still-nil
# module reference, not a real load failure.

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

joinargs(argv: list of string): string
{
	s := "";
	for(; argv != nil; argv = tl argv){
		if(s != "")
			s += " ";
		s += hd argv;
	}
	return s;
}

# --- minimal JSON helpers (see bsky.b's own comment: JValue.text()
# re-serializes a String rather than returning its content) ---

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

jint(v: ref JValue): int
{
	if(v == nil)
		return 0;
	pick r := v {
	Int =>
		return int r.value;
	Real =>
		return int r.value;
	* =>
		return 0;
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

# --- request builder (pure; buildtest() pins its exact output) ---

statusbody(text, inreplyto: string): string
{
	b := "{\"status\":"+jsonquote(text);
	if(inreplyto != nil)
		b += ",\"in_reply_to_id\":"+jsonquote(inreplyto);
	return b+"}";
}

# --- Mastodon (REST) calls ---

authget(token, url: string): (string, string)
{
	return fetch("GET", url, ("Authorization", "Bearer "+token) :: nil, nil);
}

lookup(inst, token, acct: string): (string, string, string)
{
	(out, err) := authget(token,
		sys->sprint("https://%s/api/v1/accounts/lookup?acct=%s", inst, acct));
	if(err != nil)
		return (nil, nil, err);
	(v, jerr) := json->readjson(bufio->sopen(out));
	if(jerr != nil || v == nil || !v.isobject())
		return (nil, nil, "bad response: "+out);
	errf := v.get("error");
	if(errf != nil)
		return (nil, nil, "server error: "+jstring(errf));
	id := jstring(v.get("id"));
	if(id == nil)
		return (nil, nil, "no id in response: "+out);
	return (id, jstring(v.get("acct")), nil);
}

# a posted/actioned status comes back as the status object itself

postresult(out: string): (string, string, string)
{
	(v, jerr) := json->readjson(bufio->sopen(out));
	if(jerr != nil || v == nil || !v.isobject())
		return (nil, nil, "bad response: "+out);
	errf := v.get("error");
	if(errf != nil)
		return (nil, nil, "server error: "+jstring(errf));
	id := jstring(v.get("id"));
	if(id == nil)
		return (nil, nil, "no id in response: "+out);
	return (id, jstring(v.get("url")), nil);
}

# --- timeline decoding ---
# split out so the actual status-array walk - the code path every
# real invocation of this command runs - can be driven from a plain
# JSON string, the same shape fetch() itself returns, without a live
# account. Returns (lines, last status id for -max paging, err).

decode(out: string, verbose: int): (list of string, string, string)
{
	(v, jerr) := json->readjson(bufio->sopen(out));
	if(jerr != nil || v == nil)
		return (nil, nil, "bad response: "+out);
	if(v.isobject()){
		# an object response here is Mastodon's own error shape
		# ({"error":"..."}), never a timeline (that's always an array)
		errf := v.get("error");
		if(errf != nil)
			return (nil, nil, "server error: "+jstring(errf));
		return (nil, nil, "unexpected response: "+out);
	}
	if(!v.isarray())
		return (nil, nil, "unexpected response: "+out);
	a: array of ref JValue;
	pick r := v {
	Array => a = r.a;
	}
	lines: list of string;
	lastid: string;
	for(i := 0; i < len a; i++){
		status := a[i];
		id := jstring(status.get("id"));
		if(id != nil)
			lastid = id;
		lines = statusline(status) :: lines;
		if(verbose && id != nil)
			lines = "  id "+id :: lines;
	}
	# the API hands back newest-first; the cons above reversed it, so
	# reverse once more to keep that same order.
	rev: list of string;
	for(l := lines; l != nil; l = tl l)
		rev = hd l :: rev;
	return (rev, lastid, nil);
}

# one status -> one line; a boost (reblog non-null) names both the
# booster and the original author

statusline(status: ref JValue): string
{
	handle := "?";
	account := status.get("account");
	if(account != nil){
		h := jstring(account.get("acct"));
		if(h != nil)
			handle = h;
	}
	reblog := status.get("reblog");
	if(reblog != nil && reblog.isobject()){
		orig := "?";
		racct := reblog.get("account");
		if(racct != nil){
			h := jstring(racct.get("acct"));
			if(h != nil)
				orig = h;
		}
		text := "";
		t := jstring(reblog.get("content"));
		if(t != nil)
			text = detag(t);
		return sys->sprint("@%s boosted @%s: %s", handle, orig, oneline(text));
	}
	text := "";
	t := jstring(status.get("content"));
	if(t != nil)
		text = detag(t);
	return sys->sprint("@%s: %s", handle, oneline(text));
}

# --- notifications decoding ---

notifdecode(out: string): (list of string, string)
{
	(v, jerr) := json->readjson(bufio->sopen(out));
	if(jerr != nil || v == nil)
		return (nil, "bad response: "+out);
	if(v.isobject()){
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
		n := a[i];
		ntype := jstring(n.get("type"));
		if(ntype == nil)
			ntype = "?";
		handle := "?";
		account := n.get("account");
		if(account != nil){
			h := jstring(account.get("acct"));
			if(h != nil)
				handle = h;
		}
		text := "";
		status := n.get("status");
		if(status != nil && status.isobject()){
			t := jstring(status.get("content"));
			if(t != nil)
				text = ": "+oneline(detag(t));
		}
		lines = sys->sprint("%s @%s%s", ntype, handle, text) :: lines;
	}
	rev: list of string;
	for(l := lines; l != nil; l = tl l)
		rev = hd l :: rev;
	return (rev, nil);
}

# --- profile decoding ---

profiledecode(out: string): (list of string, string)
{
	(v, jerr) := json->readjson(bufio->sopen(out));
	if(jerr != nil || v == nil || !v.isobject())
		return (nil, "bad response: "+out);
	errf := v.get("error");
	if(errf != nil)
		return (nil, "server error: "+jstring(errf));
	acct := jstring(v.get("acct"));
	if(acct == nil)
		return (nil, "no acct in response: "+out);
	lines: list of string;
	lines = sys->sprint("@%s (%s)", acct, jstring(v.get("id"))) :: lines;
	dn := jstring(v.get("display_name"));
	if(dn != nil && dn != "")
		lines = dn :: lines;
	note := jstring(v.get("note"));
	if(note != nil && note != "")
		lines = oneline(detag(note)) :: lines;
	lines = sys->sprint("%d posts, %d followers, %d following",
		jint(v.get("statuses_count")), jint(v.get("followers_count")),
		jint(v.get("following_count"))) :: lines;
	rev: list of string;
	for(l := lines; l != nil; l = tl l)
		rev = hd l :: rev;
	return (rev, nil);
}

# --- thread (context) decoding ---
# /statuses/:id gives the subject, /statuses/:id/context its flat
# ancestor and descendant lists; ancestors print first, the subject
# is marked with ">", descendants indent below it

contextdecode(statusout, contextout: string): (list of string, string)
{
	(sv, sjerr) := json->readjson(bufio->sopen(statusout));
	if(sjerr != nil || sv == nil || !sv.isobject())
		return (nil, "bad status response: "+statusout);
	errf := sv.get("error");
	if(errf != nil)
		return (nil, "server error: "+jstring(errf));
	(cv, cjerr) := json->readjson(bufio->sopen(contextout));
	if(cjerr != nil || cv == nil || !cv.isobject())
		return (nil, "bad context response: "+contextout);
	errf = cv.get("error");
	if(errf != nil)
		return (nil, "server error: "+jstring(errf));

	lines: list of string;
	lines = addstatuslist(lines, cv.get("ancestors"), "");
	lines = "> "+statusline(sv) :: lines;
	lines = addstatuslist(lines, cv.get("descendants"), "  ");
	rev: list of string;
	for(l := lines; l != nil; l = tl l)
		rev = hd l :: rev;
	return (rev, nil);
}

addstatuslist(lines: list of string, v: ref JValue, indent: string): list of string
{
	if(v == nil || !v.isarray())
		return lines;
	a: array of ref JValue;
	pick r := v {
	Array => a = r.a;
	}
	for(i := 0; i < len a; i++)
		lines = indent+statusline(a[i]) :: lines;
	return lines;
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

# --- transport: https(2), this tree's own TLS ---
# Transport-level failures (dial, TLS, certificate verification,
# HTTP framing) come back as err; an HTTP error STATUS does not -
# Mastodon answers errors with a JSON body, and the callers decode
# that body (curl -s without -f, which this replaced, behaved the
# same way). An empty-but-non-nil body string sends a bodyless POST
# with Content-Length: 0 - what the favourite/reblog/follow action
# endpoints take.

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
# the status-array walk is the code path every real invocation of
# masto(1) runs. A JSON array in the real api/v1/timelines/home
# response shape exercises: account/content present and absent (the
# "?" and "" fallbacks), <br> handling composed with detag() the
# same way the real caller composes it, entity decoding, a boost
# (reblog) naming both accounts, the double-reverse that preserves
# the API's own newest-first order, -v id lines, and -max paging id
# extraction.

feedtest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "feedtest: "+e;
	body := "[" +
		"{\"id\":\"401\",\"account\":{\"acct\":\"alice@example.social\"}," +
		 "\"content\":\"<p>hello &amp; welcome</p>\"}," +
		"{\"id\":\"302\",\"account\":{\"acct\":\"bob@example.social\"}," +
		 "\"content\":\"<p>line one<br>line two</p>\"}," +
		"{\"id\":\"203\",\"content\":\"<p>no account field</p>\"}," +
		"{\"id\":\"104\",\"account\":{\"acct\":\"carol@example.social\"}}," +
		"{\"id\":\"55\",\"account\":{\"acct\":\"dan@example.social\"}," +
		 "\"reblog\":{\"account\":{\"acct\":\"erin@example.social\"}," +
		  "\"content\":\"<p>the original</p>\"}}" +
		"]";
	(lines, lastid, err) := decode(body, 0);
	if(err != nil)
		return "feedtest: "+err;
	if(lastid != "55")
		return sys->sprint("feedtest: last id %q, want \"55\"", lastid);
	want := array[] of {
		"@alice@example.social: hello & welcome",
		"@bob@example.social: line one / line two",
		"@?: no account field",
		"@carol@example.social: ",
		"@dan@example.social boosted @erin@example.social: the original",
	};
	if((e = wantlines("feedtest", lines, want)) != nil)
		return e;
	(vlines, nil, verr) := decode(body, 1);
	if(verr != nil)
		return "feedtest: verbose: "+verr;
	if(vlines == nil || tl vlines == nil)
		return "feedtest: verbose: too few lines";
	if(hd tl vlines != "  id 401")
		return sys->sprint("feedtest: verbose line = %q, want \"  id 401\"", hd tl vlines);
	return nil;
}

# --- test seam: notifdecode(), no network needed ---
# notifications need auth, so there is no unauthenticated live leg;
# the decode walk is pinned offline in the endpoint's real shape
# (type, account, status present and absent).

notiftest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "notiftest: "+e;
	body := "[" +
		"{\"type\":\"favourite\",\"account\":{\"acct\":\"alice@example.social\"}," +
		 "\"status\":{\"content\":\"<p>my &lt;post&gt;</p>\"}}," +
		"{\"type\":\"follow\",\"account\":{\"acct\":\"bob@example.social\"}}," +
		"{\"type\":\"mention\"}" +
		"]";
	(lines, err) := notifdecode(body);
	if(err != nil)
		return "notiftest: "+err;
	want := array[] of {
		"favourite @alice@example.social: my <post>",
		"follow @bob@example.social",
		"mention @?",
	};
	return wantlines("notiftest", lines, want);
}

# --- test seam: profiledecode(), no network needed ---

profiletest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "profiletest: "+e;
	body := "{\"id\":\"13179\",\"acct\":\"Mastodon\",\"display_name\":\"Mastodon\"," +
		"\"note\":\"<p>a &amp; b</p>\"," +
		"\"statuses_count\":564,\"followers_count\":878022,\"following_count\":51}";
	(lines, err) := profiledecode(body);
	if(err != nil)
		return "profiletest: "+err;
	want := array[] of {
		"@Mastodon (13179)",
		"Mastodon",
		"a & b",
		"564 posts, 878022 followers, 51 following",
	};
	return wantlines("profiletest", lines, want);
}

# --- test seam: contextdecode(), no network needed ---

contexttest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "contexttest: "+e;
	statusout := "{\"id\":\"2\",\"account\":{\"acct\":\"b@x\"},\"content\":\"<p>subject</p>\"}";
	contextout := "{\"ancestors\":[" +
		"{\"id\":\"1\",\"account\":{\"acct\":\"a@x\"},\"content\":\"<p>root</p>\"}" +
		"],\"descendants\":[" +
		"{\"id\":\"3\",\"account\":{\"acct\":\"c@x\"},\"content\":\"<p>reply</p>\"}" +
		"]}";
	(lines, err) := contextdecode(statusout, contextout);
	if(err != nil)
		return "contexttest: "+err;
	want := array[] of {
		"@a@x: root",
		"> @b@x: subject",
		"  @c@x: reply",
	};
	return wantlines("contexttest", lines, want);
}

# --- test seam: statusbody(), no network needed ---
# the whole write surface, pinned byte for byte including escaping

buildtest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "buildtest: "+e;
	got := statusbody("hi \"you\"\nthere", nil);
	want := "{\"status\":\"hi \\\"you\\\"\\nthere\"}";
	if(got != want)
		return sys->sprint("buildtest: got %s want %s", got, want);
	got = statusbody("re", "12345");
	want = "{\"status\":\"re\",\"in_reply_to_id\":\"12345\"}";
	if(got != want)
		return sys->sprint("buildtest: reply: got %s want %s", got, want);
	return nil;
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
# same fetch()/json path timeline() uses, over the real network,
# without needing an access token.

pubtest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "pubtest: "+e;
	(out, err) := fetch("GET", "https://mastodon.social/api/v1/instance", nil, nil);
	if(err != nil)
		return "pubtest: "+err;
	(v, jerr) := json->readjson(bufio->sopen(out));
	if(jerr != nil || v == nil || !v.isobject())
		return "pubtest: bad response: "+out;
	title := jstring(v.get("title"));
	if(title == nil)
		return "pubtest: no title in response: "+out;
	return nil;
}

# --- test seam ---
# accounts/lookup is public - the same resolution path cmdfollow()
# uses, live, plus profiledecode() over the real response.

lookuptest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "lookuptest: "+e;
	(out, err) := fetch("GET",
		"https://mastodon.social/api/v1/accounts/lookup?acct=Mastodon", nil, nil);
	if(err != nil)
		return "lookuptest: "+err;
	(lines, derr) := profiledecode(out);
	if(derr != nil)
		return "lookuptest: "+derr;
	if(lines == nil)
		return "lookuptest: no profile lines";
	first := hd lines;
	if(len first < 9 || first[0:9] != "@Mastodon")
		return sys->sprint("lookuptest: first line %q, want it to start \"@Mastodon\"", first);
	return nil;
}

# --- test seam ---
# a real thread from the real network: mastodon.social's own
# account's newest status, its context, and contextdecode() over
# both - the live counterpart of contexttest()'s hand-built shape.
# Public statuses and contexts need no auth on mastodon.social.

livecontexttest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "livecontexttest: "+e;
	(out, err) := fetch("GET",
		"https://mastodon.social/api/v1/accounts/lookup?acct=Mastodon", nil, nil);
	if(err != nil)
		return "livecontexttest: "+err;
	(v, jerr) := json->readjson(bufio->sopen(out));
	if(jerr != nil || v == nil || !v.isobject())
		return "livecontexttest: bad lookup response: "+out;
	id := jstring(v.get("id"));
	if(id == nil)
		return "livecontexttest: no account id";
	(sout, serr) := fetch("GET",
		sys->sprint("https://mastodon.social/api/v1/accounts/%s/statuses?limit=1", id), nil, nil);
	if(serr != nil)
		return "livecontexttest: "+serr;
	(slines, nil, sderr) := decode(sout, 0);
	if(sderr != nil)
		return "livecontexttest: statuses: "+sderr;
	if(slines == nil)
		return "livecontexttest: account has no statuses";
	(sv, sjerr) := json->readjson(bufio->sopen(sout));
	if(sjerr != nil || sv == nil || !sv.isarray())
		return "livecontexttest: bad statuses response";
	a: array of ref JValue;
	pick r := sv {
	Array => a = r.a;
	* => return "livecontexttest: no status array";
	}
	sid := jstring(a[0].get("id"));
	if(sid == nil)
		return "livecontexttest: no status id";
	(oneout, oerr) := fetch("GET",
		sys->sprint("https://mastodon.social/api/v1/statuses/%s", sid), nil, nil);
	if(oerr != nil)
		return "livecontexttest: "+oerr;
	(ctxout, cerr) := fetch("GET",
		sys->sprint("https://mastodon.social/api/v1/statuses/%s/context", sid), nil, nil);
	if(cerr != nil)
		return "livecontexttest: "+cerr;
	(lines, derr) := contextdecode(oneout, ctxout);
	if(derr != nil)
		return "livecontexttest: "+derr;
	# the subject line must be present and marked
	for(l := lines; l != nil; l = tl l)
		if(len hd l >= 2 && (hd l)[0:2] == "> ")
			return nil;
	return "livecontexttest: no subject line in decoded thread";
}

# --- test seam ---
# POST /api/v1/statuses with a bogus token: the server must answer
# with a real decoded error through our stack - proving the whole
# authenticated-POST path (headers, JSON body, error decode) without
# writing anything anywhere.

authposttest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "authposttest: "+e;
	(out, err) := fetch("POST", "https://mastodon.social/api/v1/statuses",
		("Authorization", "Bearer bogus-token-for-testing") ::
		("Content-Type", "application/json") :: nil,
		statusbody("never posted", nil));
	if(err != nil)
		return "authposttest: transport error instead of a server error: "+err;
	(nil, nil, derr) := postresult(out);
	if(derr == nil)
		return "authposttest: bogus-token post unexpectedly succeeded";
	if(len derr < 13 || derr[0:13] != "server error:")
		return "authposttest: want a decoded server error, got: "+derr;
	return nil;
}

# --- shared test plumbing ---

wantlines(name: string, lines: list of string, want: array of string): string
{
	n := len lines;
	got := array[n] of string;
	i := 0;
	for(l := lines; l != nil; l = tl l){
		got[i] = hd l;
		i++;
	}
	if(n != len want)
		return sys->sprint("%s: got %d lines, want %d: %s", name, n, len want, out2str(got));
	for(i = 0; i < n; i++)
		if(got[i] != want[i])
			return sys->sprint("%s: line %d = %q, want %q", name, i, got[i], want[i]);
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

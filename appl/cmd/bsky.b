implement Bsky;

# bsky(1) - Bluesky (AT Protocol) client: timeline, posting, replies,
# likes, reposts, follows, notifications, profiles and threads, over
# this tree's own TLS.
#
# Transport is https(2) - this tree's OWN TLS 1.2 stack (tls12(2),
# which verifies the server's certificate chain), not a host command.
# This command originally drove the host's curl(1) through #C because
# module/ssl3.m was SSLv3-era and could not reach a modern HTTPS host;
# that stopgap is gone, per CLAUDE.md's rule that no network client
# uses #C as a transport (the SSL modernization it demanded is done -
# doc/ssl-modernization-plan.md). Hostnames are resolved by https(2)
# over DNS-over-HTTPS (doh(2)) - the tree's own encrypted resolver -
# so this needs no /net/cs and no host resolver.
#
# Every write (post/reply/like/repost/follow) is one createRecord
# call: AT Protocol represents all of them as records in the user's
# own repo, so the JSON record builders below are the entire write
# surface, and they are pure functions - buildtest() pins their exact
# output offline.

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "json.m";
	json: JSON;
	JValue: import json;
include "daytime.m";
	daytime: Daytime;
include "keyring.m";
include "security.m";
include "factotum.m";
include "secstore.m";
include "dial.m";
include "tls12.m";
include "https.m";
	https: Https;

Bsky: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
	# test seams, same justification as danby-aerobraking(1)'s own
	# run()/viewtest(): offline seams decode hand-built JSON in each
	# endpoint's real shape; live seams hit real public/bogus-auth
	# endpoints so bskytest(1) exercises the actual https(2)/JSON
	# paths this command uses, without needing live credentials.
	pubtest: fn(): string;
	postpubtest: fn(): string;
	feedtest: fn(): string;
	notiftest: fn(): string;
	threadtest: fn(): string;
	profiletest: fn(): string;
	buildtest: fn(): string;
	resolvetest: fn(): string;
	livethreadtest: fn(): string;
	authposttest: fn(): string;

	factotumtest: fn(): string;
	secstoretest: fn(): string;

	# reuse surface for wm/fedi(1) (and anything else): fetch and
	# decode, returning lines instead of printing them. The public
	# pair needs no credentials (the read-only AppView);
	# hometimeline logs in with credfile per call, like the command.
	publicfeed: fn(actor: string, limit: int): (list of string, string);
	publicprofile: fn(actor: string): (list of string, string);
	hometimeline: fn(credfile: string, limit: int): (list of string, string);
};

stderr: ref Sys->FD;

PDS: con "https://bsky.social";		# the user's own PDS (auth lives here)
PUBLICAPI: con "https://public.api.bsky.app";	# read-only AppView, no auth

USAGE: con "usage: bsky credfile [timeline [-n nnn] [-c cursor] [-v] | post text | reply uri cid text | like uri cid | repost uri cid | follow handle-or-did | notifications [-n nnn] | profile [actor] | thread uri]";

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
	if(argv == nil)
		fail(USAGE);
	credfile := hd argv;
	argv = tl argv;
	cmd := "timeline";
	if(argv != nil){
		cmd = hd argv;
		argv = tl argv;
	}
	# reject an unknown command BEFORE logging in: a typo should not
	# cost a network round trip (or count against bsky.social's
	# login rate limit)
	case cmd {
	"timeline" or "post" or "reply" or "like" or "repost" or
	"follow" or "notifications" or "profile" or "thread" =>
		;
	* =>
		fail(USAGE);
	}

	(handle, password, cerr) := getcreds(credfile);
	if(cerr != nil)
		fail("bsky: "+cerr);

	(jwt, did, lerr) := login(handle, password);
	password = nil;	# done with it; don't keep it around any longer than needed
	if(lerr != nil)
		fail("bsky: login: "+lerr);

	case cmd {
	"timeline" =>	cmdtimeline(jwt, argv);
	"post" =>	cmdpost(jwt, did, argv);
	"reply" =>	cmdreply(jwt, did, argv);
	"like" =>	cmdsubject(jwt, did, "app.bsky.feed.like", "liked", argv);
	"repost" =>	cmdsubject(jwt, did, "app.bsky.feed.repost", "reposted", argv);
	"follow" =>	cmdfollow(jwt, did, argv);
	"notifications" =>	cmdnotifications(jwt, argv);
	"profile" =>	cmdprofile(jwt, handle, argv);
	"thread" =>	cmdthread(jwt, argv);
	* =>		fail(USAGE);
	}
}

# --- subcommands ---

cmdtimeline(jwt: string, argv: list of string)
{
	limit := 30;
	cursor := "";
	verbose := 0;
	for(; argv != nil; argv = tl argv){
		case hd argv {
		"-n" =>
			argv = tl argv;
			if(argv == nil)
				fail(USAGE);
			limit = int hd argv;
		"-c" =>
			argv = tl argv;
			if(argv == nil)
				fail(USAGE);
			cursor = hd argv;
		"-v" =>
			verbose = 1;
		* =>
			fail(USAGE);
		}
	}
	if(limit < 1 || limit > 100)
		fail("bsky: -n must be 1..100");
	url := sys->sprint("%s/xrpc/app.bsky.feed.getTimeline?limit=%d", PDS, limit);
	if(cursor != "")
		url += "&cursor="+urlquote(cursor);
	(out, err) := authget(jwt, url);
	if(err != nil)
		fail("bsky: timeline: "+err);
	(lines, nextcursor, derr) := decode(out, verbose);
	if(derr != nil)
		fail("bsky: timeline: "+derr);
	for(l := lines; l != nil; l = tl l)
		sys->print("%s\n", hd l);
	if(nextcursor != nil)
		sys->print("more: bsky ... timeline -c %q\n", nextcursor);
}

cmdpost(jwt, did: string, argv: list of string)
{
	text := joinargs(argv);
	if(text == "")
		fail(USAGE);
	rec := postrecord(text, nowutc(), nil, nil, nil, nil);
	(uri, nil, err) := createrecord(jwt, did, "app.bsky.feed.post", rec);
	if(err != nil)
		fail("bsky: post: "+err);
	sys->print("posted %s\n", uri);
}

cmdreply(jwt, did: string, argv: list of string)
{
	if(argv == nil || tl argv == nil || tl tl argv == nil)
		fail(USAGE);
	parenturi := hd argv;
	parentcid := hd tl argv;
	text := joinargs(tl tl argv);
	if(text == "")
		fail(USAGE);
	# the reply's root ref: the parent's own root if the parent is
	# itself a reply, else the parent itself (RFC'd in the lexicon:
	# root always names the thread's first post)
	(rooturi, rootcid, rerr) := rootof(jwt, parenturi, parentcid);
	if(rerr != nil)
		fail("bsky: reply: "+rerr);
	rec := postrecord(text, nowutc(), rooturi, rootcid, parenturi, parentcid);
	(uri, nil, err) := createrecord(jwt, did, "app.bsky.feed.post", rec);
	if(err != nil)
		fail("bsky: reply: "+err);
	sys->print("replied %s\n", uri);
}

cmdsubject(jwt, did, collection, verb: string, argv: list of string)
{
	if(argv == nil || tl argv == nil || tl tl argv != nil)
		fail(USAGE);
	uri := hd argv;
	cid := hd tl argv;
	rec := subjectrecord(collection, uri, cid, nowutc());
	(nil, nil, err) := createrecord(jwt, did, collection, rec);
	if(err != nil)
		fail("bsky: "+verb+": "+err);
	sys->print("%s %s\n", verb, uri);
}

cmdfollow(jwt, did: string, argv: list of string)
{
	if(argv == nil || tl argv != nil)
		fail(USAGE);
	who := hd argv;
	if(!prefix("did:", who)){
		(rdid, rerr) := resolvehandle(jwt, who);
		if(rerr != nil)
			fail("bsky: follow: "+rerr);
		who = rdid;
	}
	rec := followrecord(who, nowutc());
	(nil, nil, err) := createrecord(jwt, did, "app.bsky.graph.follow", rec);
	if(err != nil)
		fail("bsky: follow: "+err);
	sys->print("followed %s\n", who);
}

cmdnotifications(jwt: string, argv: list of string)
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
	if(limit < 1 || limit > 100)
		fail("bsky: -n must be 1..100");
	url := sys->sprint("%s/xrpc/app.bsky.notification.listNotifications?limit=%d", PDS, limit);
	(out, err) := authget(jwt, url);
	if(err != nil)
		fail("bsky: notifications: "+err);
	(lines, derr) := notifdecode(out);
	if(derr != nil)
		fail("bsky: notifications: "+derr);
	for(l := lines; l != nil; l = tl l)
		sys->print("%s\n", hd l);
}

cmdprofile(jwt, own: string, argv: list of string)
{
	actor := own;
	if(argv != nil){
		actor = hd argv;
		if(tl argv != nil)
			fail(USAGE);
	}
	url := sys->sprint("%s/xrpc/app.bsky.actor.getProfile?actor=%s", PDS, urlquote(actor));
	(out, err) := authget(jwt, url);
	if(err != nil)
		fail("bsky: profile: "+err);
	(lines, derr) := profiledecode(out);
	if(derr != nil)
		fail("bsky: profile: "+derr);
	for(l := lines; l != nil; l = tl l)
		sys->print("%s\n", hd l);
}

cmdthread(jwt: string, argv: list of string)
{
	if(argv == nil || tl argv != nil)
		fail(USAGE);
	url := sys->sprint("%s/xrpc/app.bsky.feed.getPostThread?uri=%s&depth=10&parentHeight=10",
		PDS, urlquote(hd argv));
	(out, err) := authget(jwt, url);
	if(err != nil)
		fail("bsky: thread: "+err);
	(lines, derr) := threaddecode(out);
	if(derr != nil)
		fail("bsky: thread: "+derr);
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
	if(daytime == nil)
		daytime = load Daytime Daytime->PATH;
	if(daytime == nil)
		return "cannot load Daytime";
	return nil;
}

fail(msg: string)
{
	sys->fprint(stderr, "%s\n", msg);
	raise "fail:bsky";
}

# --- credentials ---
# the credentials argument is one of:
#   a file path - two lines: handle, then an app password (from
#     Bluesky's own Settings > App Passwords - never the real
#     account password);
#   "-" - ask factotum(2,4) for a proto=pass service=bsky key
#     (user=HANDLE !password=APPPASSWORD), the Inferno-native shape:
#     keys live in the running factotum, typically loaded there from
#     the user's secstore file at login, and never touch a plaintext
#     file or this command's argv;
#   a keyspec fragment (anything containing '=') - appended to the
#     factotum query, so "user=alice.bsky.social" picks one of
#     several bsky keys.
# Never echoed either way - not even into the argv a "ps" could see.

getcreds(spec: string): (string, string, string)
{
	if(spec != "-" && !contains(spec, "="))
		return readcreds(spec);
	fact := load Factotum Factotum->PATH;
	if(fact == nil)
		return (nil, nil, sys->sprint("cannot load %s: %r", Factotum->PATH));
	fact->init();
	keyspec := "proto=pass service=bsky";
	if(spec != "-")
		keyspec += " "+spec;
	(u, p) := fact->getuserpasswd(keyspec);
	if(u == nil || p == nil)
		return (nil, nil, sys->sprint("factotum has no key matching %q: %r (is auth/factotum running? add one with: echo 'key %s user=HANDLE !password=APPPASSWORD' > /mnt/factotum/ctl)", keyspec, keyspec));
	return (u, p, nil);
}

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

# RFC 3986 percent-encoding for the characters that matter in a query
# value (at:// URIs carry ':' and '/'; cursors carry ':' and '+')

urlquote(s: string): string
{
	out := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'
		|| c == '-' || c == '.' || c == '_' || c == '~')
			out += sys->sprint("%c", c);
		else if(c < 16r80)
			out += sys->sprint("%%%02X", c);
		else{
			# non-ASCII: encode the UTF-8 bytes
			b := array of byte sys->sprint("%c", c);
			for(j := 0; j < len b; j++)
				out += sys->sprint("%%%02X", int b[j]);
		}
	}
	return out;
}

# UTC now in the RFC 3339 shape AT Protocol expects in createdAt

nowutc(): string
{
	tm := daytime->gmt(daytime->now());
	return sys->sprint("%04d-%02d-%02dT%02d:%02d:%02dZ",
		tm.year+1900, tm.mon+1, tm.mday, tm.hour, tm.min, tm.sec);
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

# --- record builders (pure; buildtest() pins their exact output) ---

postrecord(text, createdat, rooturi, rootcid, parenturi, parentcid: string): string
{
	rec := "{\"$type\":\"app.bsky.feed.post\",\"text\":"+jsonquote(text)+
		",\"createdAt\":"+jsonquote(createdat);
	if(parenturi != nil)
		rec += ",\"reply\":{\"root\":{\"uri\":"+jsonquote(rooturi)+
			",\"cid\":"+jsonquote(rootcid)+
			"},\"parent\":{\"uri\":"+jsonquote(parenturi)+
			",\"cid\":"+jsonquote(parentcid)+"}}";
	return rec+"}";
}

subjectrecord(rtype, uri, cid, createdat: string): string
{
	return "{\"$type\":"+jsonquote(rtype)+
		",\"subject\":{\"uri\":"+jsonquote(uri)+
		",\"cid\":"+jsonquote(cid)+
		"},\"createdAt\":"+jsonquote(createdat)+"}";
}

followrecord(did, createdat: string): string
{
	return "{\"$type\":\"app.bsky.graph.follow\",\"subject\":"+jsonquote(did)+
		",\"createdAt\":"+jsonquote(createdat)+"}";
}

# --- Bluesky (AT Protocol) calls ---

login(handle, password: string): (string, string, string)
{
	body := sys->sprint("{\"identifier\":%s,\"password\":%s}",
		jsonquote(handle), jsonquote(password));
	(out, err) := fetch("POST",
		PDS+"/xrpc/com.atproto.server.createSession",
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

authget(jwt, url: string): (string, string)
{
	return fetch("GET", url, ("Authorization", "Bearer "+jwt) :: nil, nil);
}

authpost(jwt, url, body: string): (string, string)
{
	return fetch("POST", url,
		("Authorization", "Bearer "+jwt) ::
		("Content-Type", "application/json") :: nil, body);
}

# one createRecord call - the whole write surface (see the header)

createrecord(jwt, did, collection, record: string): (string, string, string)
{
	body := "{\"repo\":"+jsonquote(did)+
		",\"collection\":"+jsonquote(collection)+
		",\"record\":"+record+"}";
	(out, err) := authpost(jwt, PDS+"/xrpc/com.atproto.repo.createRecord", body);
	if(err != nil)
		return (nil, nil, err);
	(v, jerr) := json->readjson(bufio->sopen(out));
	if(jerr != nil || v == nil || !v.isobject())
		return (nil, nil, "bad response: "+out);
	errf := v.get("error");
	if(errf != nil)
		return (nil, nil, sys->sprint("%s: %s", jstring(errf), jstring(v.get("message"))));
	uri := jstring(v.get("uri"));
	if(uri == nil)
		return (nil, nil, "no uri in response: "+out);
	return (uri, jstring(v.get("cid")), nil);
}

resolvehandle(jwt, handle: string): (string, string)
{
	url := sys->sprint("%s/xrpc/com.atproto.identity.resolveHandle?handle=%s",
		PDS, urlquote(handle));
	(out, err) := authget(jwt, url);
	if(err != nil)
		return (nil, err);
	(v, jerr) := json->readjson(bufio->sopen(out));
	if(jerr != nil || v == nil || !v.isobject())
		return (nil, "bad response: "+out);
	errf := v.get("error");
	if(errf != nil)
		return (nil, sys->sprint("%s: %s", jstring(errf), jstring(v.get("message"))));
	did := jstring(v.get("did"));
	if(did == nil)
		return (nil, "no did in response: "+out);
	return (did, nil);
}

# the reply-root ref for a new reply under parenturi: the parent's own
# record's root if the parent is itself a reply, else the parent

rootof(jwt, parenturi, parentcid: string): (string, string, string)
{
	url := sys->sprint("%s/xrpc/app.bsky.feed.getPosts?uris=%s", PDS, urlquote(parenturi));
	(out, err) := authget(jwt, url);
	if(err != nil)
		return (nil, nil, err);
	(v, jerr) := json->readjson(bufio->sopen(out));
	if(jerr != nil || v == nil || !v.isobject())
		return (nil, nil, "bad response: "+out);
	postsf := v.get("posts");
	if(postsf == nil || !postsf.isarray())
		return (nil, nil, "no posts array in response: "+out);
	a: array of ref JValue;
	pick r := postsf {
	Array => a = r.a;
	}
	if(len a == 0)
		return (nil, nil, "parent post not found: "+parenturi);
	record := a[0].get("record");
	if(record != nil){
		reply := record.get("reply");
		if(reply != nil){
			root := reply.get("root");
			if(root != nil){
				ruri := jstring(root.get("uri"));
				rcid := jstring(root.get("cid"));
				if(ruri != nil && rcid != nil)
					return (ruri, rcid, nil);
			}
		}
	}
	return (parenturi, parentcid, nil);
}

# --- timeline decoding ---
# split from cmdtimeline() so the actual feed-array walk - the code
# path every real invocation of this command runs - can be driven
# from a plain JSON string, the same shape fetch() itself returns,
# without a live account.

decode(out: string, verbose: int): (list of string, string, string)
{
	(v, jerr) := json->readjson(bufio->sopen(out));
	if(jerr != nil || v == nil || !v.isobject())
		return (nil, nil, "bad response: "+out);
	errf := v.get("error");
	if(errf != nil)
		return (nil, nil, sys->sprint("%s: %s", jstring(errf), jstring(v.get("message"))));
	feedf := v.get("feed");
	if(feedf == nil || !feedf.isarray())
		return (nil, nil, "no feed array in response: "+out);
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
		if(verbose){
			uri := jstring(post.get("uri"));
			cid := jstring(post.get("cid"));
			lines = sys->sprint("  %s %s", uri, cid) :: lines;
		}
	}
	# feed arrives newest-first; the cons above reversed it, so reverse
	# once more to hand back the API's own order.
	rev: list of string;
	for(l := lines; l != nil; l = tl l)
		rev = hd l :: rev;
	return (rev, jstring(v.get("cursor")), nil);
}

# --- notifications decoding ---

notifdecode(out: string): (list of string, string)
{
	(v, jerr) := json->readjson(bufio->sopen(out));
	if(jerr != nil || v == nil || !v.isobject())
		return (nil, "bad response: "+out);
	errf := v.get("error");
	if(errf != nil)
		return (nil, sys->sprint("%s: %s", jstring(errf), jstring(v.get("message"))));
	nf := v.get("notifications");
	if(nf == nil || !nf.isarray())
		return (nil, "no notifications array in response: "+out);
	a: array of ref JValue;
	pick r := nf {
	Array => a = r.a;
	}
	lines: list of string;
	for(i := 0; i < len a; i++){
		n := a[i];
		reason := jstring(n.get("reason"));
		if(reason == nil)
			reason = "?";
		handle := "?";
		author := n.get("author");
		if(author != nil){
			h := jstring(author.get("handle"));
			if(h != nil)
				handle = h;
		}
		text := "";
		record := n.get("record");
		if(record != nil){
			t := jstring(record.get("text"));
			if(t != nil)
				text = ": "+oneline(t);
		}
		lines = sys->sprint("%s @%s%s", reason, handle, text) :: lines;
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
		return (nil, sys->sprint("%s: %s", jstring(errf), jstring(v.get("message"))));
	handle := jstring(v.get("handle"));
	if(handle == nil)
		return (nil, "no handle in response: "+out);
	lines: list of string;
	lines = sys->sprint("@%s (%s)", handle, jstring(v.get("did"))) :: lines;
	dn := jstring(v.get("displayName"));
	if(dn != nil)
		lines = dn :: lines;
	desc := jstring(v.get("description"));
	if(desc != nil)
		lines = oneline(desc) :: lines;
	lines = sys->sprint("%d posts, %d followers, %d following",
		jint(v.get("postsCount")), jint(v.get("followersCount")),
		jint(v.get("followsCount"))) :: lines;
	rev: list of string;
	for(l := lines; l != nil; l = tl l)
		rev = hd l :: rev;
	return (rev, nil);
}

# --- thread decoding ---
# getPostThread's thread node: {post, parent?, replies?}; ancestors
# are printed root-first above the post, replies nested below with
# indentation. A blocked/not-found node has no post - shown as such
# rather than silently dropped.

threaddecode(out: string): (list of string, string)
{
	(v, jerr) := json->readjson(bufio->sopen(out));
	if(jerr != nil || v == nil || !v.isobject())
		return (nil, "bad response: "+out);
	errf := v.get("error");
	if(errf != nil)
		return (nil, sys->sprint("%s: %s", jstring(errf), jstring(v.get("message"))));
	tf := v.get("thread");
	if(tf == nil)
		return (nil, "no thread in response: "+out);
	# ancestors, root first
	anc: list of ref JValue;
	for(p := tf.get("parent"); p != nil; p = p.get("parent"))
		anc = p :: anc;
	lines: list of string;
	depth := 0;
	for(; anc != nil; anc = tl anc){
		lines = nodeline(hd anc, depth) :: lines;
		depth++;
	}
	lines = walkreplies(tf, depth, lines);
	rev: list of string;
	for(l := lines; l != nil; l = tl l)
		rev = hd l :: rev;
	return (rev, nil);
}

walkreplies(node: ref JValue, depth: int, lines: list of string): list of string
{
	lines = nodeline(node, depth) :: lines;
	rf := node.get("replies");
	if(rf == nil || !rf.isarray())
		return lines;
	a: array of ref JValue;
	pick r := rf {
	Array => a = r.a;
	}
	for(i := 0; i < len a; i++)
		lines = walkreplies(a[i], depth+1, lines);
	return lines;
}

nodeline(node: ref JValue, depth: int): string
{
	ind := "";
	for(i := 0; i < depth; i++)
		ind += "  ";
	post := node.get("post");
	if(post == nil)
		return ind+"[unavailable]";
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
	return sys->sprint("%s@%s: %s", ind, handle, oneline(text));
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

prefix(p, s: string): int
{
	return len s >= len p && s[0:len p] == p;
}

# --- test seam: decode(), no network needed ---
# the feed-array walk in decode() is the code path every real
# invocation of bsky(1) runs. A JSON body in the real
# app.bsky.feed.getTimeline response shape exercises: a missing post
# entirely (skipped, not crashed), missing author/record (the "?" and
# "" fallbacks), the double-reverse meant to preserve the API's own
# newest-first order, the -v uri/cid lines, and cursor extraction.

feedtest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "feedtest: "+e;
	body := "{\"cursor\":\"2026-01-01T00:00:00Z\",\"feed\":[" +
		"{\"post\":{\"uri\":\"at://u1\",\"cid\":\"c1\",\"author\":{\"handle\":\"alice.bsky.social\"}," +
		 "\"record\":{\"text\":\"hello world\"}}}," +
		"{\"post\":{\"author\":{\"handle\":\"bob.bsky.social\"}," +
		 "\"record\":{\"text\":\"line one\\nline two\"}}}," +
		"{\"post\":{\"record\":{\"text\":\"no author field\"}}}," +
		"{\"post\":{\"author\":{\"handle\":\"carol.bsky.social\"}}}," +
		"{\"nopost\":true}" +
		"]}";
	(lines, cursor, err) := decode(body, 0);
	if(err != nil)
		return "feedtest: "+err;
	if(cursor != "2026-01-01T00:00:00Z")
		return sys->sprint("feedtest: cursor %q, want the fixture's own", cursor);
	want := array[] of {
		"@alice.bsky.social: hello world",
		"@bob.bsky.social: line one / line two",
		"@?: no author field",
		"@carol.bsky.social: ",
	};
	if((e = wantlines("feedtest", lines, want)) != nil)
		return e;
	# -v adds the uri/cid line right after a post that has them
	(vlines, nil, verr) := decode(body, 1);
	if(verr != nil)
		return "feedtest: verbose: "+verr;
	if(vlines == nil || tl vlines == nil)
		return "feedtest: verbose: too few lines";
	if(hd tl vlines != "  at://u1 c1")
		return sys->sprint("feedtest: verbose line = %q, want \"  at://u1 c1\"", hd tl vlines);
	return nil;
}

# --- test seam: notifdecode(), no network needed ---
# listNotifications needs auth, so unlike the other endpoints there
# is no unauthenticated live leg possible; the decode walk is pinned
# offline in the endpoint's real response shape instead (reason
# codes, author fallback, record-text presence and absence).

notiftest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "notiftest: "+e;
	body := "{\"notifications\":[" +
		"{\"reason\":\"like\",\"author\":{\"handle\":\"alice.bsky.social\"}}," +
		"{\"reason\":\"reply\",\"author\":{\"handle\":\"bob.bsky.social\"}," +
		 "\"record\":{\"text\":\"nice one\\nreally\"}}," +
		"{\"reason\":\"follow\"}" +
		"]}";
	(lines, err) := notifdecode(body);
	if(err != nil)
		return "notiftest: "+err;
	want := array[] of {
		"like @alice.bsky.social",
		"reply @bob.bsky.social: nice one / really",
		"follow @?",
	};
	return wantlines("notiftest", lines, want);
}

# --- test seam: threaddecode(), no network needed ---
# a hand-built nested thread in getPostThread's real shape: two
# ancestors above the subject post, two replies below (one nested),
# and an unavailable node - livethreadtest() then runs the same
# decoder over a real thread from the real network.

threadtest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "threadtest: "+e;
	body := "{\"thread\":{" +
		"\"post\":{\"author\":{\"handle\":\"c.example\"},\"record\":{\"text\":\"subject\"}}," +
		"\"parent\":{\"post\":{\"author\":{\"handle\":\"b.example\"},\"record\":{\"text\":\"middle\"}}," +
		 "\"parent\":{\"post\":{\"author\":{\"handle\":\"a.example\"},\"record\":{\"text\":\"root\"}}}}," +
		"\"replies\":[" +
		 "{\"post\":{\"author\":{\"handle\":\"d.example\"},\"record\":{\"text\":\"reply one\"}}," +
		  "\"replies\":[{\"post\":{\"author\":{\"handle\":\"e.example\"},\"record\":{\"text\":\"deeper\"}}}]}," +
		 "{\"notFound\":true}" +
		"]}}";
	(lines, err) := threaddecode(body);
	if(err != nil)
		return "threadtest: "+err;
	want := array[] of {
		"@a.example: root",
		"  @b.example: middle",
		"    @c.example: subject",
		"      @d.example: reply one",
		"        @e.example: deeper",
		"      [unavailable]",
	};
	return wantlines("threadtest", lines, want);
}

# --- test seam: profiledecode(), no network needed ---

profiletest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "profiletest: "+e;
	body := "{\"did\":\"did:plc:xyz\",\"handle\":\"alice.bsky.social\"," +
		"\"displayName\":\"Alice\",\"description\":\"first line\\nsecond\"," +
		"\"postsCount\":12,\"followersCount\":34,\"followsCount\":56}";
	(lines, err) := profiledecode(body);
	if(err != nil)
		return "profiletest: "+err;
	want := array[] of {
		"@alice.bsky.social (did:plc:xyz)",
		"Alice",
		"first line / second",
		"12 posts, 34 followers, 56 following",
	};
	return wantlines("profiletest", lines, want);
}

# --- test seam: the record builders, no network needed ---
# these strings are the entire write surface (see header); pin them
# byte for byte, including JSON escaping of user text and the reply
# refs appearing exactly when a parent is given.

buildtest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "buildtest: "+e;
	at := "2026-09-02T12:00:00Z";
	got := postrecord("hi \"there\"\nx", at, nil, nil, nil, nil);
	want := "{\"$type\":\"app.bsky.feed.post\",\"text\":\"hi \\\"there\\\"\\nx\",\"createdAt\":\"2026-09-02T12:00:00Z\"}";
	if(got != want)
		return sys->sprint("buildtest: post: got %s want %s", got, want);
	got = postrecord("re", at, "at://root", "cr", "at://parent", "cp");
	want = "{\"$type\":\"app.bsky.feed.post\",\"text\":\"re\",\"createdAt\":\"2026-09-02T12:00:00Z\"," +
		"\"reply\":{\"root\":{\"uri\":\"at://root\",\"cid\":\"cr\"},\"parent\":{\"uri\":\"at://parent\",\"cid\":\"cp\"}}}";
	if(got != want)
		return sys->sprint("buildtest: reply: got %s want %s", got, want);
	got = subjectrecord("app.bsky.feed.like", "at://u", "c", at);
	want = "{\"$type\":\"app.bsky.feed.like\",\"subject\":{\"uri\":\"at://u\",\"cid\":\"c\"},\"createdAt\":\"2026-09-02T12:00:00Z\"}";
	if(got != want)
		return sys->sprint("buildtest: like: got %s want %s", got, want);
	got = followrecord("did:plc:abc", at);
	want = "{\"$type\":\"app.bsky.graph.follow\",\"subject\":\"did:plc:abc\",\"createdAt\":\"2026-09-02T12:00:00Z\"}";
	if(got != want)
		return sys->sprint("buildtest: follow: got %s want %s", got, want);
	# urlquote: the characters at:// URIs and cursors actually carry
	if(urlquote("at://did:plc:x/a.b/3k?y+z") != "at%3A%2F%2Fdid%3Aplc%3Ax%2Fa.b%2F3k%3Fy%2Bz")
		return "buildtest: urlquote: "+urlquote("at://did:plc:x/a.b/3k?y+z");
	return nil;
}

# --- test seam ---
# app.bsky.actor.getProfile on the public AppView - real, public,
# unauthenticated - drives the exact same fetch()/json path the
# authenticated calls use, end to end, without a credentials file.

pubtest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "pubtest: "+e;
	(out, err) := fetch("GET",
		PUBLICAPI+"/xrpc/app.bsky.actor.getProfile?actor=bsky.app",
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

# --- test seam ---
# com.atproto.identity.resolveHandle on the public AppView - the same
# resolution path cmdfollow() uses for a handle argument, live.

resolvetest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "resolvetest: "+e;
	(out, err) := fetch("GET",
		PUBLICAPI+"/xrpc/com.atproto.identity.resolveHandle?handle=bsky.app",
		nil, nil);
	if(err != nil)
		return "resolvetest: "+err;
	(v, jerr) := json->readjson(bufio->sopen(out));
	if(jerr != nil || v == nil || !v.isobject())
		return "resolvetest: bad response: "+out;
	did := jstring(v.get("did"));
	if(!prefix("did:plc:", did))
		return "resolvetest: no did:plc: in response: "+out;
	return nil;
}

# --- test seam ---
# a real thread from the real network: take bsky.app's newest post
# from the public author feed, fetch its thread, and require
# threaddecode() to produce lines including that post's own text -
# the live counterpart of threadtest()'s hand-built nesting.

livethreadtest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "livethreadtest: "+e;
	(out, err) := fetch("GET",
		PUBLICAPI+"/xrpc/app.bsky.feed.getAuthorFeed?actor=bsky.app&limit=1",
		nil, nil);
	if(err != nil)
		return "livethreadtest: "+err;
	(nil, nil, derr) := decode(out, 0);
	if(derr != nil)
		return "livethreadtest: author feed: "+derr;
	(v, jerr) := json->readjson(bufio->sopen(out));
	if(jerr != nil || v == nil)
		return "livethreadtest: bad response: "+out;
	feedf := v.get("feed");
	a: array of ref JValue;
	pick r := feedf {
	Array => a = r.a;
	* => return "livethreadtest: no feed array";
	}
	if(len a == 0)
		return "livethreadtest: empty author feed";
	post := a[0].get("post");
	uri := jstring(post.get("uri"));
	text := jstring(post.get("record").get("text"));
	if(uri == nil)
		return "livethreadtest: no post uri";
	(tout, terr) := fetch("GET",
		PUBLICAPI+"/xrpc/app.bsky.feed.getPostThread?uri="+urlquote(uri)+"&depth=3",
		nil, nil);
	if(terr != nil)
		return "livethreadtest: "+terr;
	(lines, therr) := threaddecode(tout);
	if(therr != nil)
		return "livethreadtest: "+therr;
	wantfrag := oneline(text);
	for(l := lines; l != nil; l = tl l)
		if(contains(hd l, wantfrag))
			return nil;
	return sys->sprint("livethreadtest: no thread line carries the post's own text %q", wantfrag);
}

# --- test seam ---
# login() is the only caller of fetch()'s POST-with-request-body
# branch, and of jsonquote() - neither is exercised by pubtest()
# above, which only ever GETs. A deliberately bogus login can't
# reach a real account, but bsky.social can only answer with a
# real, well-formed error (checked live against the real server:
# 'AuthenticationRequired: Invalid identifier or password') if the
# JSON body this sends actually arrived intact - a body that got
# mangled or truncated in transit would instead fail to parse as
# the request Bluesky expects. Accepts either of the error codes
# the real server is known to answer with: repeated runs in one
# session trip bsky.social's own rate limiter (RateLimitExceeded) -
# a different real, well-formed server error, not a breakage.

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

# --- test seam ---
# createrecord() with a bogus token: the server must answer with a
# real decoded auth error, proving the whole authenticated-POST path
# (headers, body framing, JSON error decode) works end to end
# without ever writing anything to a real account.

authposttest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "authposttest: "+e;
	rec := postrecord("never posted", nowutc(), nil, nil, nil, nil);
	(nil, nil, err) := createrecord("bogus.jwt.token", "did:plc:bogus",
		"app.bsky.feed.post", rec);
	if(err == nil)
		return "authposttest: bogus-token createRecord unexpectedly succeeded";
	# any decoded error field will do - the point is that the
	# server's own JSON error came back through our stack, not a
	# transport failure or an undecodable body
	if(prefix("https:", err) || prefix("tls:", err) || prefix("bad response", err))
		return "authposttest: want a decoded server error, got: "+err;
	return nil;
}

# --- reuse surface (module/decl comment) ---

publicfeed(actor: string, limit: int): (list of string, string)
{
	e := ensureloaded();
	if(e != nil)
		return (nil, e);
	if(limit < 1 || limit > 100)
		limit = 30;
	(out, err) := fetch("GET",
		sys->sprint("%s/xrpc/app.bsky.feed.getAuthorFeed?actor=%s&limit=%d",
			PUBLICAPI, urlquote(actor), limit), nil, nil);
	if(err != nil)
		return (nil, err);
	(lines, nil, derr) := decode(out, 0);
	return (lines, derr);
}

publicprofile(actor: string): (list of string, string)
{
	e := ensureloaded();
	if(e != nil)
		return (nil, e);
	(out, err) := fetch("GET",
		sys->sprint("%s/xrpc/app.bsky.actor.getProfile?actor=%s",
			PUBLICAPI, urlquote(actor)), nil, nil);
	if(err != nil)
		return (nil, err);
	return profiledecode(out);
}

hometimeline(credfile: string, limit: int): (list of string, string)
{
	e := ensureloaded();
	if(e != nil)
		return (nil, e);
	if(limit < 1 || limit > 100)
		limit = 30;
	(handle, password, cerr) := getcreds(credfile);
	if(cerr != nil)
		return (nil, cerr);
	(jwt, nil, lerr) := login(handle, password);
	password = nil;
	if(lerr != nil)
		return (nil, "login: "+lerr);
	(out, err) := authget(jwt,
		sys->sprint("%s/xrpc/app.bsky.feed.getTimeline?limit=%d", PDS, limit));
	if(err != nil)
		return (nil, err);
	(lines, nil, derr) := decode(out, 0);
	return (lines, derr);
}

# --- test seam: getcreds() through a REAL factotum, no network ---
# starts this tree's own auth/factotum (unless one is already
# mounted), feeds it a key through /mnt/factotum/ctl exactly the way
# a user (or a secstore-fed login) would, and requires getcreds() to
# come back with it - both via the bare "-" spec and via a narrowing
# keyspec fragment - and to FAIL for a keyspec no key matches.

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

# Start this tree's own auth/factotum if one is not already serving.
# Its file2chan server procs outlive this call (that is what a daemon
# is), so a test process that starts one cannot cleanly let emu exit
# on its own - bskytest(1) ends the whole session with quitall(1)
# after the verdict, the same way wmtest(1) does for the windows it
# spawns.
startfactotum(): string
{
	if(sys->open("/mnt/factotum/ctl", Sys->ORDWR) != nil)
		return nil;	# one is already serving
	c := load Command "/dis/auth/factotum.dis";
	if(c == nil)
		return sys->sprint("cannot load /dis/auth/factotum.dis: %r");
	c->init(nil, "factotum" :: nil);
	if(sys->open("/mnt/factotum/ctl", Sys->ORDWR) == nil)
		return sys->sprint("factotum started but /mnt/factotum/ctl not there: %r");
	return nil;
}

ctlwrite(line: string): string
{
	fd := sys->open("/mnt/factotum/ctl", Sys->ORDWR);
	if(fd == nil)
		return sys->sprint("open /mnt/factotum/ctl: %r");
	b := array of byte line;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("write /mnt/factotum/ctl: %r");
	return nil;
}

factotumtest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "factotumtest: "+e;
	if((e = startfactotum()) != nil)
		return "factotumtest: "+e;
	if((e = ctlwrite("key proto=pass service=bsky user=factotum.test.handle !password=factotum-test-pw")) != nil)
		return "factotumtest: "+e;

	(u, p, gerr) := getcreds("-");
	if(gerr != nil)
		return "factotumtest: getcreds -: "+gerr;
	if(u != "factotum.test.handle" || p != "factotum-test-pw")
		return sys->sprint("factotumtest: got %q/%q, want the test key", u, p);

	(u, p, gerr) = getcreds("user=factotum.test.handle");
	if(gerr != nil)
		return "factotumtest: narrowed keyspec: "+gerr;
	if(u != "factotum.test.handle")
		return sys->sprint("factotumtest: narrowed keyspec got %q", u);

	(nil, nil, gerr) = getcreds("user=nobody.matches.this");
	if(gerr == nil)
		return "factotumtest: a keyspec matching no key SUCCEEDED";

	if((e = ctlwrite("delkey proto=pass service=bsky")) != nil)
		return "factotumtest: cleanup: "+e;
	(nil, nil, gerr) = getcreds("-");
	if(gerr == nil)
		return "factotumtest: key still matched after delkey";
	return nil;
}

# --- test seam: the secstore -> factotum -> getcreds() pipeline ---
# the way Inferno actually stores these keys durably: the user's
# secstore file is an AES-encrypted list of factotum ctl lines,
# fetched and fed to factotum at login. There is no secstore server
# here to dial, but the FILE crypto is local - so this round-trips a
# real factotum line through secstore(2)'s own mkfilekey/encrypt/
# decrypt/lines, feeds the decrypted lines to the running factotum,
# and requires getcreds() to produce the key. A wrong passphrase
# must fail to decrypt (secstore's own integrity check), which is
# this seam's negative control.

secstoretest(): string
{
	e := ensureloaded();
	if(e != nil)
		return "secstoretest: "+e;
	ss := load Secstore Secstore->PATH;
	if(ss == nil)
		return sys->sprint("secstoretest: cannot load %s: %r", Secstore->PATH);
	ss->init();
	if((e = startfactotum()) != nil)
		return "secstoretest: "+e;

	blob := array of byte "key proto=pass service=bsky user=secstore.test.handle !password=from-secstore\n";
	filekey := ss->mkfilekey("correct horse battery");
	enc := ss->encrypt(blob, filekey);
	if(enc == nil)
		return "secstoretest: encrypt failed";

	# wrong passphrase must NOT decrypt (negative control)
	wrongkey := ss->mkfilekey("wrong passphrase");
	encopy := array[len enc] of byte;
	encopy[0:] = enc;
	if(ss->decrypt(encopy, wrongkey) != nil)
		return "secstoretest: decrypted with the WRONG passphrase";

	dec := ss->decrypt(enc, filekey);
	if(dec == nil)
		return sys->sprint("secstoretest: decrypt failed: %r");
	for(ll := ss->lines(dec); ll != nil; ll = tl ll)
		if((e = ctlwrite(string hd ll)) != nil)
			return "secstoretest: feeding factotum: "+e;

	(u, p, gerr) := getcreds("user=secstore.test.handle");
	if(gerr != nil)
		return "secstoretest: getcreds: "+gerr;
	if(u != "secstore.test.handle" || p != "from-secstore")
		return sys->sprint("secstoretest: got %q/%q, want the secstore-fed key", u, p);
	if((e = ctlwrite("delkey proto=pass service=bsky")) != nil)
		return "secstoretest: cleanup: "+e;
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
		return sys->sprint("%s: got %d lines, want %d", name, n, len want);
	for(i = 0; i < n; i++)
		if(got[i] != want[i])
			return sys->sprint("%s: line %d = %q, want %q", name, i, got[i], want[i]);
	return nil;
}

contains(s, sub: string): int
{
	n := len sub;
	for(i := 0; i+n <= len s; i++)
		if(s[i:i+n] == sub)
			return 1;
	return 0;
}

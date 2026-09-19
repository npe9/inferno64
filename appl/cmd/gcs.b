implement Gcs;

#
# Google Cloud Storage, over the bearer token the instance is issued.
#
# The credential is the one cloudfs(4) already serves: a read of
# /cloud/token returns the service account's OAuth token, and every
# call here is that token in an Authorization header over TLS.  No key
# is stored, nothing is signed, and nothing has to be configured on the
# machine -- which is the whole reason to prefer this route to the
# S3-compatible one on a Compute Engine instance.
#
# awsv4(2) is in the tree for the other route: storage.googleapis.com
# also speaks S3's XML API with SigV4 and interoperability HMAC keys,
# which is what a machine outside Google would use, and what would let
# the same commands reach S3 itself.  Not wired up here.
#
# The XML API is used rather than the JSON one because get and put are
# then a plain GET and PUT of the object's bytes, with no envelope to
# build or parse, and because it is the half that generalises to S3.
#
include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "httpclient.m";
	http: Httpclient;
	Hdr, Resp: import http;

Gcs: module
{
	init: fn(nil: ref Draw->Context, argv: list of string);
};

HOST: con "storage.googleapis.com";
TOKENFILE: con "/cloud/token";

addr := "";		# -A: dial here instead of resolving HOST
tokenfile := TOKENFILE;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	http = load Httpclient Httpclient->PATH;
	if(http == nil)
		fail(sys->sprint("cannot load %s: %r", Httpclient->PATH));
	if((e := http->init()) != nil)
		fail(e);

	arg->init(argv);
	arg->setusage("gcs [-A addr] [-t tokenfile] ls bucket [prefix] | get bucket object | put bucket object file");
	while((o := arg->opt()) != 0)
		case o {
		'A' =>	addr = arg->earg();
		't' =>	tokenfile = arg->earg();
		* =>	arg->usage();
		}
	argv = arg->argv();
	if(argv == nil)
		arg->usage();
	cmd := hd argv;
	argv = tl argv;

	case cmd {
	"ls" =>
		if(argv == nil)
			arg->usage();
		bucket := hd argv;
		prefix := "";
		if(tl argv != nil)
			prefix = hd tl argv;
		ls(bucket, prefix);
	"get" =>
		if(argv == nil || tl argv == nil)
			arg->usage();
		get(hd argv, hd tl argv);
	"put" =>
		if(argv == nil || tl argv == nil || tl tl argv == nil)
			arg->usage();
		put(hd argv, hd tl argv, hd tl tl argv);
	* =>
		arg->usage();
	}
}

#
# The token file is the metadata service's JSON reply, not a bare
# token: {"access_token":"...","expires_in":3599,"token_type":"Bearer"}.
# Scanned rather than parsed, because one string is all that is wanted
# and a JSON parser is not in the kernel root.
#
token(): string
{
	fd := sys->open(tokenfile, Sys->OREAD);
	if(fd == nil)
		fail(sys->sprint("%s: %r", tokenfile));
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		fail(sys->sprint("%s: short read: %r", tokenfile));
	s := string buf[0:n];
	key := "\"access_token\"";
	i := index(s, key);
	if(i < 0){
		# a file holding just the token is accepted too
		while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == ' '))
			s = s[0:len s - 1];
		if(len s > 0 && s[0] != '{')
			return s;
		fail(tokenfile + ": no access_token");
	}
	s = s[i + len key:];
	j := index(s, "\"");
	if(j < 0)
		fail(tokenfile + ": malformed access_token");
	s = s[j+1:];
	j = index(s, "\"");
	if(j < 0)
		fail(tokenfile + ": unterminated access_token");
	return s[0:j];
}

index(s, sub: string): int
{
	if(len sub == 0)
		return 0;
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return i;
	return -1;
}

hdrs(): list of Hdr
{
	return Hdr("Authorization", "Bearer " + token()) :: nil;
}

call(method, url: string, body: array of byte): ref Resp
{
	(r, e) := http->requestat(method, url, addr, hdrs(), body);
	if(e != nil)
		fail(e);
	if(r.code < 200 || r.code > 299){
		if(len r.body > 0)
			sys->fprint(sys->fildes(2), "%s\n", string r.body);
		fail(sys->sprint("http %d %s", r.code, r.reason));
	}
	return r;
}

#
# The bucket listing is XML.  Only the object names are wanted, and
# they are the contents of the <Key> elements, so the reply is scanned
# for those rather than parsed: nothing else in this command needs a
# tree, and an XML parser is not in the kernel root either.
#
ls(bucket, prefix: string)
{
	base := "https://" + HOST + "/" + bucket + "?list-type=2";
	if(prefix != "")
		base += "&prefix=" + prefix;
	# Continuation.  A listing reply carries at most a thousand keys and
	# says so with <IsTruncated>true</IsTruncated>; the rest are fetched
	# by asking again with the token it hands back.  Without this the
	# command printed the first page and stopped, silently, which is
	# the worst way for a listing to be wrong -- the output looks like
	# a complete answer and there is nothing to notice.
	token := "";
	for(;;){
		url := base;
		if(token != "")
			url += "&continuation-token=" + urlencode(token);
		r := call("GET", url, nil);
		s := string r.body;
		body := s;
		for(;;){
			i := index(s, "<Key>");
			if(i < 0)
				break;
			s = s[i+5:];
			j := index(s, "</Key>");
			if(j < 0)
				break;
			sys->print("%s\n", s[0:j]);
			s = s[j+6:];
		}
		if(element(body, "IsTruncated") != "true")
			return;
		token = element(body, "NextContinuationToken");
		if(token == ""){
			# Truncated but no token to continue with: say so rather
			# than return a short answer as though it were whole.
			sys->fprint(sys->fildes(2),
				"gcs: listing truncated and no continuation token\n");
			raise "fail:truncated";
		}
	}
}

# The text of the first <name>...</name>, or "".
element(s, name: string): string
{
	i := index(s, "<" + name + ">");
	if(i < 0)
		return "";
	s = s[i + len name + 2:];
	j := index(s, "</" + name + ">");
	if(j < 0)
		return "";
	return s[0:j];
}

# A continuation token is opaque and base64-ish: it can hold "+", "/"
# and "=", all of which change meaning in a query string.
urlencode(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z'
		|| c >= '0' && c <= '9' || c == '-' || c == '_'
		|| c == '.' || c == '~')
			r[len r] = c;
		else
			r += sys->sprint("%%%.2X", c);
	}
	return r;
}

get(bucket, object: string)
{
	r := call("GET", "https://" + HOST + "/" + bucket + "/" + object, nil);
	if(len r.body > 0)
		sys->write(sys->fildes(1), r.body, len r.body);
}

put(bucket, object, file: string)
{
	fd := sys->open(file, Sys->OREAD);
	if(fd == nil)
		fail(sys->sprint("%s: %r", file));
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		fail(sys->sprint("%s: stat: %r", file));
	n := int d.length;
	body := array[n] of byte;
	got := 0;
	while(got < n){
		m := sys->read(fd, body[got:], n - got);
		if(m <= 0)
			break;
		got += m;
	}
	if(got != n)
		fail(sys->sprint("%s: short read", file));
	call("PUT", "https://" + HOST + "/" + bucket + "/" + object, body);
	sys->print("%s %d bytes\n", object, n);
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "gcs: %s\n", s);
	raise "fail:" + s;
}

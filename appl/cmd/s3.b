implement S3;

# s3(1) - a minimal Amazon S3 client, entirely in Limbo: SigV4-signed
# requests (awsv4(2)) over this tree's own TLS (https(2)). Proof that
# AWS interactions need no host tooling once the SSL modernization
# (doc/ssl-modernization-plan.md) shipped.
#
#   s3 credfile ls bucket [prefix]     - list objects (ListObjectsV2)
#   s3 credfile get bucket key         - fetch an object to stdout
#   s3 credfile put bucket key < file  - upload stdin as an object
#
# credfile is one of the forms getcreds() below documents: a file, "-"
# (factotum), or a keyspec fragment - the same convention bsky(1)/
# masto(1) use, so S3 keys can live in factotum/secstore too. The
# region defaults to us-east-1 (-r overrides) and the endpoint to the
# regional s3.<region>.amazonaws.com (-e overrides, e.g. for an
# S3-compatible host).
#
# Scope is deliberately small - list, get, put of a single object, no
# multipart, no ACLs, no bucket ops - the point is a working, signed,
# TLS-native S3 path, not a full SDK. See BUGS.

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "keyring.m";
include "security.m";
include "factotum.m";
include "awsv4.m";
	awsv4: AWSV4;
	Creds, Request: import awsv4;
include "https.m";
	https: Https;

S3: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
	# test seams (s3test(1)): offline SigV4 is covered by awsv4test(1);
	# here the live seam sends a real bogus-credential signed request
	# to real S3 and requires AWS's own signed error back - proving the
	# whole sign->TLS->S3->parse path without a real account.
	badauthtest: fn(): string;
	listparsetest: fn(): string;
};

stderr: ref Sys->FD;
region := "us-east-1";
endpoint := "";

USAGE: con "usage: s3 [-r region] [-e endpoint] credfile {ls bucket [prefix] | get bucket key | put bucket key}";

init(nil: ref Draw->Context, argv: list of string)
{
	if(loadall() != nil){
		if(sys != nil)
			sys->fprint(stderr, "s3: %s\n", loadall());
		raise "fail:load";
	}
	stderr = sys->fildes(2);

	argv = tl argv;
	while(argv != nil && len hd argv >= 1 && (hd argv)[0] == '-'){
		opt := hd argv;
		argv = tl argv;
		case opt {
		"-r" =>
			if(argv == nil) fail(USAGE);
			region = hd argv; argv = tl argv;
		"-e" =>
			if(argv == nil) fail(USAGE);
			endpoint = hd argv; argv = tl argv;
		* =>
			fail(USAGE);
		}
	}
	if(argv == nil || tl argv == nil)
		fail(USAGE);
	credfile := hd argv;
	argv = tl argv;
	cmd := hd argv;
	argv = tl argv;

	(access, secret, cerr) := getcreds(credfile);
	if(cerr != nil)
		fail("s3: "+cerr);
	c := ref Creds(access, secret, nil, region, "s3");

	case cmd {
	"ls" =>
		if(argv == nil)
			fail(USAGE);
		bucket := hd argv;
		prefix := "";
		if(tl argv != nil){
			prefix = hd tl argv;
			if(tl tl argv != nil)
				fail(USAGE);
		}
		cmdls(c, bucket, prefix);
	"get" =>
		if(argv == nil || tl argv == nil || tl tl argv != nil)
			fail(USAGE);
		cmdget(c, hd argv, hd tl argv);
	"put" =>
		if(argv == nil || tl argv == nil || tl tl argv != nil)
			fail(USAGE);
		cmdput(c, hd argv, hd tl argv);
	* =>
		fail(USAGE);
	}
}

# path-style regional endpoint - works for every bucket name,
# including ones with dots that would break virtual-host TLS (the
# bucket goes in the URL path, not the hostname)
s3host(): string
{
	if(endpoint != "")
		return endpoint;
	return "s3."+region+".amazonaws.com";
}

# path-style URL path: /bucket/key
bucketpath(bucket, key: string): string
{
	p := "/"+bucket;
	if(key != "")
		p += "/"+key;
	return p;
}

cmdls(c: ref Creds, bucket, prefix: string)
{
	q := "list-type=2";
	if(prefix != "")
		q += "&prefix="+prefix;
	(status, body, err) := dorequest(c, "GET", "/"+bucket, q, nil);
	if(err != nil)
		fail("s3: ls: "+err);
	if(status != 200)
		fail(sys->sprint("s3: ls: HTTP %d: %s", status, awserr(body)));
	keys := parsekeys(string body);
	for(; keys != nil; keys = tl keys)
		sys->print("%s\n", hd keys);
}

cmdget(c: ref Creds, bucket, key: string)
{
	(status, body, err) := dorequest(c, "GET", bucketpath(bucket, key), "", nil);
	if(err != nil)
		fail("s3: get: "+err);
	if(status != 200)
		fail(sys->sprint("s3: get: HTTP %d: %s", status, awserr(body)));
	sys->write(sys->fildes(1), body, len body);
}

cmdput(c: ref Creds, bucket, key: string)
{
	body := readall(sys->fildes(0));
	(status, resp, err) := dorequest(c, "PUT", bucketpath(bucket, key), "", body);
	if(err != nil)
		fail("s3: put: "+err);
	if(status != 200)
		fail(sys->sprint("s3: put: HTTP %d: %s", status, awserr(resp)));
	sys->print("put %s/%s (%d bytes)\n", bucket, key, len body);
}

# sign and send one request; returns (status, body, err)
dorequest(c: ref Creds, method, path, query: string, payload: array of byte): (int, array of byte, string)
{
	h := s3host();
	req := ref Request(method, h, path, query, nil, payload);
	amz := awsv4->amzdatenow();
	if(amz == nil)
		return (0, nil, "cannot read the clock for x-amz-date");
	hdrs := awsv4->sign(c, req, amz);
	url := "https://"+h+path;
	if(query != "")
		url += "?"+query;
	(status, nil, rbody, herr) := https->request(method, url, hdrs, payload);
	if(herr != nil)
		return (0, nil, herr);
	return (status, rbody, nil);
}

# --- tiny XML field pulls (S3's ListObjectsV2 / Error bodies) ---
# not a real XML parser - S3's responses are flat and well-formed, and
# these pull one tag repeatedly; documented as such in BUGS.

parsekeys(xml: string): list of string
{
	keys: list of string;
	i := 0;
	for(;;){
		(v, ni) := tagat(xml, i, "<Key>", "</Key>");
		if(ni < 0)
			break;
		keys = v :: keys;
		i = ni;
	}
	rev: list of string;
	for(; keys != nil; keys = tl keys)
		rev = hd keys :: rev;
	return rev;
}

awserr(body: array of byte): string
{
	xml := string body;
	(code, nil) := tagat(xml, 0, "<Code>", "</Code>");
	(msg, nil) := tagat(xml, 0, "<Message>", "</Message>");
	if(code == "")
		return xml;	# not an AWS error doc; show it raw
	if(msg != "")
		return code+": "+msg;
	return code;
}

# find open..close after position i; returns (contents, index past
# close), or ("", -1) if not found
tagat(s: string, i: int, open, close: string): (string, int)
{
	st := indexfrom(s, open, i);
	if(st < 0)
		return ("", -1);
	st += len open;
	en := indexfrom(s, close, st);
	if(en < 0)
		return ("", -1);
	return (s[st:en], en+len close);
}

indexfrom(s, sub: string, from: int): int
{
	n := len sub;
	for(i := from; i+n <= len s; i++)
		if(s[i:i+n] == sub)
			return i;
	return -1;
}

# --- credentials (same shape as bsky(1)/masto(1)) ---
# a file path (two lines: access key id, then secret access key);
# "-" (factotum proto=pass service=aws, user=ACCESSKEYID
# !password=SECRET); or a keyspec fragment appended to that query.

getcreds(spec: string): (string, string, string)
{
	if(spec != "-" && !contains(spec, "="))
		return readcreds(spec);
	fact := load Factotum Factotum->PATH;
	if(fact == nil)
		return (nil, nil, sys->sprint("cannot load %s: %r", Factotum->PATH));
	fact->init();
	keyspec := "proto=pass service=aws";
	if(spec != "-")
		keyspec += " "+spec;
	(u, p) := fact->getuserpasswd(keyspec);
	if(u == nil || p == nil)
		return (nil, nil, sys->sprint("factotum has no key matching %q: %r (add one: echo 'key %s user=ACCESSKEYID !password=SECRET' > /mnt/factotum/ctl)", keyspec, keyspec));
	return (u, p, nil);
}

readcreds(path: string): (string, string, string)
{
	b := bufio->open(path, Bufio->OREAD);
	if(b == nil)
		return (nil, nil, sys->sprint("cannot open %q: %r", path));
	access := chomp(b.gets('\n'));
	secret := chomp(b.gets('\n'));
	b.close();
	if(access == nil || secret == nil)
		return (nil, nil, "credentials file must have access key id and secret on two lines");
	return (access, secret, nil);
}

# --- plumbing ---

loadall(): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	if(bufio == nil)
		bufio = load Bufio Bufio->PATH;
	if(bufio == nil)
		return "cannot load Bufio";
	if(awsv4 == nil){
		awsv4 = load AWSV4 AWSV4->PATH;
		if(awsv4 == nil)
			return sys->sprint("cannot load %s: %r", AWSV4->PATH);
		if((e := awsv4->init()) != nil)
			return e;
	}
	if(https == nil){
		https = load Https Https->PATH;
		if(https == nil)
			return sys->sprint("cannot load %s: %r", Https->PATH);
		if((e := https->init()) != nil)
			return e;
	}
	return nil;
}

readall(fd: ref Sys->FD): array of byte
{
	buf := array[0] of byte;
	chunk := array[8192] of byte;
	for(;;){
		n := sys->read(fd, chunk, len chunk);
		if(n <= 0)
			break;
		nb := array[len buf + n] of byte;
		nb[0:] = buf;
		nb[len buf:] = chunk[0:n];
		buf = nb;
	}
	return buf;
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
	sys->fprint(stderr, "%s\n", msg);
	raise "fail:s3";
}

# --- test seams ---
# badauthtest: a real SigV4-signed request with bogus credentials to
# real S3 must draw AWS's own signed error (InvalidAccessKeyId or
# SignatureDoesNotMatch) - proving the sign->TLS->S3->parse path end
# to end, the same way bsky(1)/masto(1)'s bogus-auth seams do, without
# a real account. (A valid-credential success would need real keys.)

badauthtest(): string
{
	e := loadall();
	if(e != nil)
		return "badauthtest: "+e;
	c := ref Creds("AKIAIOSFODNN7EXAMPLE",
		"bogussecretkeybogussecretkeybogus123456789", nil,
		"us-east-1", "s3");
	(status, body, err) := dorequest(c, "GET", "/", "list-type=2", nil);
	if(err != nil)
		return "badauthtest: transport/sign error instead of an AWS error: "+err;
	if(status != 403 && status != 400)
		return sys->sprint("badauthtest: HTTP %d, expected 403/400 for a bogus key: %s",
			status, string body);
	msg := awserr(body);
	if(!contains(msg, "InvalidAccessKeyId") && !contains(msg, "SignatureDoesNotMatch"))
		return "badauthtest: want AWS's own auth error, got: "+msg;
	return nil;
}

# listparsetest: parsekeys() over a hand-built ListObjectsV2 body in
# S3's real shape, offline.

listparsetest(): string
{
	e := loadall();
	if(e != nil)
		return "listparsetest: "+e;
	xml := "<?xml version=\"1.0\"?><ListBucketResult>" +
		"<Contents><Key>a/one.txt</Key><Size>10</Size></Contents>" +
		"<Contents><Key>a/two.txt</Key><Size>20</Size></Contents>" +
		"<Contents><Key>b/three.txt</Key><Size>30</Size></Contents>" +
		"</ListBucketResult>";
	keys := parsekeys(xml);
	want := array[] of {"a/one.txt", "a/two.txt", "b/three.txt"};
	n := len keys;
	got := array[n] of string;
	i := 0;
	for(; keys != nil; keys = tl keys){
		got[i] = hd keys;
		i++;
	}
	if(n != len want)
		return sys->sprint("listparsetest: got %d keys, want %d", n, len want);
	for(i = 0; i < n; i++)
		if(got[i] != want[i])
			return sys->sprint("listparsetest: key %d = %q, want %q", i, got[i], want[i]);
	# and an Error doc pulls Code+Message
	ae := awserr(array of byte "<Error><Code>NoSuchKey</Code><Message>nope</Message></Error>");
	if(ae != "NoSuchKey: nope")
		return "listparsetest: awserr = "+ae;
	return nil;
}

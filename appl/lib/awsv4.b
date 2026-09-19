implement AWSV4;

# awsv4.b - AWS Signature Version 4 request signing. See module/awsv4.m
# for the contract. Implemented straight from AWS's documented
# algorithm (Signature Version 4 signing process), which is:
#
#   canonical request =
#       method \n uri \n canonical-query \n canonical-headers \n
#       signed-headers \n hex(sha256(payload))
#   string to sign =
#       "AWS4-HMAC-SHA256" \n amzdate \n scope \n hex(sha256(canonical-request))
#   signing key =
#       HMAC(HMAC(HMAC(HMAC("AWS4"+secret, date), region), service), "aws4_request")
#   signature = hex(HMAC(signing-key, string-to-sign))
#
# Verified against AWS's own aws-sig-v4-test-suite "get-vanilla" vector
# and cross-checked against botocore (see awsv4test(1)); the two agree
# byte for byte on the published signature.

include "sys.m";
	sys: Sys;
include "keyring.m";
	kr: Keyring;
include "daytime.m";
	daytime: Daytime;
include "awsv4.m";

DLEN: con Keyring->SHA256dlen;

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "awsv4: load sys module failed";
	kr = load Keyring Keyring->PATH;
	if(kr == nil)
		return "awsv4: load keyring module failed";
	return nil;
}

sign(c: ref Creds, req: ref Request, amzdate: string): list of (string, string)
{
	datestamp := amzdate[0:8];
	phash := payloadhash(req.payload);

	all := signedset(c, req, phash, amzdate);
	(canonheaders, signedheaders) := canonheaders(all);
	canonreq := req.method + "\n" +
		req.path + "\n" +
		canonquery(req.query) + "\n" +
		canonheaders + "\n" +
		signedheaders + "\n" +
		phash;

	scope := datestamp + "/" + c.region + "/" + c.service + "/aws4_request";
	sts := "AWS4-HMAC-SHA256\n" + amzdate + "\n" + scope + "\n" +
		sha256hex(array of byte canonreq);
	key := signingkey(c.secret, datestamp, c.region, c.service);
	sig := hmachex(key, array of byte sts);

	auth := "AWS4-HMAC-SHA256 Credential=" + c.access + "/" + scope +
		", SignedHeaders=" + signedheaders +
		", Signature=" + sig;

	# the header set to actually send. Host is deliberately NOT here:
	# it is part of the signature (signedset above), but https(2) adds
	# its own Host from the URL, and sending a second one makes AWS
	# reject the request as having duplicate headers. The Host we
	# signed must equal the one https sends - it does, both being the
	# request's host - so the signature still verifies.
	out := ("X-Amz-Date", amzdate) ::
		("Authorization", auth) :: nil;
	# x-amz-content-sha256 is S3's own required header; send it exactly
	# when it was signed, so the wire matches the signature
	if(c.service == "s3")
		out = ("X-Amz-Content-Sha256", phash) :: out;
	if(c.token != nil)
		out = ("X-Amz-Security-Token", c.token) :: out;
	for(hl := req.headers; hl != nil; hl = tl hl)
		out = hd hl :: out;
	return out;
}

signature(c: ref Creds, req: ref Request, amzdate: string): (string, string)
{
	datestamp := amzdate[0:8];
	phash := payloadhash(req.payload);
	all := signedset(c, req, phash, amzdate);
	(canonheaders, signedheaders) := canonheaders(all);
	canonreq := req.method + "\n" + req.path + "\n" + canonquery(req.query) +
		"\n" + canonheaders + "\n" + signedheaders + "\n" + phash;
	scope := datestamp + "/" + c.region + "/" + c.service + "/aws4_request";
	sts := "AWS4-HMAC-SHA256\n" + amzdate + "\n" + scope + "\n" +
		sha256hex(array of byte canonreq);
	key := signingkey(c.secret, datestamp, c.region, c.service);
	return (hmachex(key, array of byte sts), sts);
}

# some AWS services (S3) accept UNSIGNED-PAYLOAD, but the safe default
# that every service accepts is the real body hash
payloadhash(payload: array of byte): string
{
	return sha256hex(payload);
}

# the (lowercased-name, trimmed-value) headers that go into the
# signature: host and x-amz-date always; x-amz-content-sha256 only for
# S3 (its own required header - other services sign only host+date, as
# AWS's own get-vanilla example does); the session token when present;
# and whatever the caller added.
signedset(c: ref Creds, req: ref Request, phash, amzdate: string): list of (string, string)
{
	all := ("host", lower(req.host)) ::
		("x-amz-date", amzdate) :: nil;
	if(c.service == "s3")
		all = ("x-amz-content-sha256", phash) :: all;
	if(c.token != nil)
		all = ("x-amz-security-token", c.token) :: all;
	for(hl := req.headers; hl != nil; hl = tl hl){
		(n, v) := hd hl;
		all = (lower(n), trim(v)) :: all;
	}
	return all;
}

# HMAC(HMAC(HMAC(HMAC("AWS4"+secret, date), region), service), "aws4_request")
signingkey(secret, datestamp, region, service: string): array of byte
{
	k := array of byte ("AWS4" + secret);
	k = hmac(k, array of byte datestamp);
	k = hmac(k, array of byte region);
	k = hmac(k, array of byte service);
	k = hmac(k, array of byte "aws4_request");
	return k;
}

hmac(key, data: array of byte): array of byte
{
	d := array[DLEN] of byte;
	kr->hmac_sha256(data, len data, key, d, nil);
	return d;
}

hmachex(key, data: array of byte): string
{
	return hex(hmac(key, data));
}

sha256hex(b: array of byte): string
{
	d := array[DLEN] of byte;
	kr->sha256(b, len b, d, nil);
	return hex(d);
}

# canonical query string: split on '&', percent-encode each name and
# value per RFC 3986, sort by encoded name (then value), rejoin
canonquery(q: string): string
{
	if(q == "")
		return "";
	parts := split(q, '&');
	n := len parts;	# capture before the loop consumes the list
	enc := array[n] of string;
	for(i := 0; i < n; i++){
		p := hd parts;
		parts = tl parts;
		eq := index(p, '=');
		if(eq < 0)
			enc[i] = uriencode(p, 0) + "=";
		else
			enc[i] = uriencode(p[0:eq], 0) + "=" + uriencode(p[eq+1:], 0);
	}
	# stable sort (small n) by the whole "name=value" - name sorts
	# first because '=' (0x3d) is below every unreserved char except
	# '-' '.', and AWS's own rule is sort-by-name-then-value, which
	# this matches for the encoded forms
	for(i = 1; i < len enc; i++){
		key := enc[i];
		j := i-1;
		while(j >= 0 && enc[j] > key){
			enc[j+1] = enc[j];
			j--;
		}
		enc[j+1] = key;
	}
	out := "";
	for(i = 0; i < len enc; i++){
		if(i != 0)
			out += "&";
		out += enc[i];
	}
	return out;
}

# canonical headers block + signed-headers list. Input is a list of
# (lowercased-name, trimmed-value); output sorts by name, joins as
# "name:value\n"..., and "name;name;..." for the signed list. Multiple
# values for one name are not merged (no AWS API this targets sends
# them); each entry is emitted once.
canonheaders(hs: list of (string, string)): (string, string)
{
	n := 0;
	for(l := hs; l != nil; l = tl l)
		n++;
	names := array[n] of string;
	vals := array[n] of string;
	i := 0;
	for(l = hs; l != nil; l = tl l){
		(nm, v) := hd l;
		names[i] = nm;
		vals[i] = v;
		i++;
	}
	# insertion sort by name
	for(i = 1; i < n; i++){
		kn := names[i]; kv := vals[i];
		j := i-1;
		while(j >= 0 && names[j] > kn){
			names[j+1] = names[j];
			vals[j+1] = vals[j];
			j--;
		}
		names[j+1] = kn;
		vals[j+1] = kv;
	}
	block := "";
	signed := "";
	for(i = 0; i < n; i++){
		block += names[i] + ":" + vals[i] + "\n";
		if(i != 0)
			signed += ";";
		signed += names[i];
	}
	return (block, signed);
}

# RFC 3986 percent-encoding. If encodeslash is 0, '/' is left as-is
# (for URI paths S3 wants slash-preserved); AWS encodes everything
# except A-Za-z0-9-._~
uriencode(s: string, encodeslash: int): string
{
	b := array of byte s;
	out := "";
	for(i := 0; i < len b; i++){
		c := int b[i];
		if(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' ||
		   c >= '0' && c <= '9' ||
		   c == '-' || c == '.' || c == '_' || c == '~')
			out[len out] = c;
		else if(c == '/' && !encodeslash)
			out[len out] = c;
		else
			out += sys->sprint("%%%02X", c);
	}
	return out;
}

hex(a: array of byte): string
{
	out := "";
	for(i := 0; i < len a; i++)
		out += sys->sprint("%02x", int a[i]);
	return out;
}

lower(s: string): string
{
	out := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c >= 'A' && c <= 'Z')
			c = c - 'A' + 'a';
		out[len out] = c;
	}
	return out;
}

# trim leading/trailing spaces and collapse internal runs (AWS's
# canonical-header value rule)
trim(s: string): string
{
	# strip ends
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t'))
		j--;
	s = s[i:j];
	# collapse internal whitespace runs to a single space
	out := "";
	sp := 0;
	for(k := 0; k < len s; k++){
		c := s[k];
		if(c == ' ' || c == '\t'){
			sp = 1;
			continue;
		}
		if(sp && out != "")
			out[len out] = ' ';
		sp = 0;
		out[len out] = c;
	}
	return out;
}

split(s: string, sep: int): list of string
{
	r: list of string;
	start := 0;
	for(i := 0; i < len s; i++)
		if(s[i] == sep){
			r = s[start:i] :: r;
			start = i+1;
		}
	r = s[start:] :: r;
	# reverse
	out: list of string;
	for(; r != nil; r = tl r)
		out = hd r :: out;
	return out;
}

index(s: string, c: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return i;
	return -1;
}

# ISO8601 basic UTC "YYYYMMDDThhmmssZ" from the clock. Uses daytime(2)
# via a lazy load so callers that always pass an explicit amzdate (the
# testable path) do not pull it in.
amzdatenow(): string
{
	if(daytime == nil)
		daytime = load Daytime Daytime->PATH;
	if(daytime == nil)
		return nil;
	tm := daytime->gmt(daytime->now());
	return sys->sprint("%04d%02d%02dT%02d%02d%02dZ",
		tm.year+1900, tm.mon+1, tm.mday, tm.hour, tm.min, tm.sec);
}

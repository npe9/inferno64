implement Https;

# https.b - HTTP/1.1 over tls12(2). See module/https.m for the
# contract and doc/ssl-modernization-plan.md for why this exists
# (step 9: no network client drives a host command as its transport).
#
# One request per connection (Connection: close), read strictly by
# the response's own framing: Content-Length when given, chunked
# transfer-coding when declared, read-to-close otherwise. Redirects
# are the caller's problem, deliberately.

include "sys.m";
	sys: Sys;
include "dial.m";
	dial: Dial;
include "srv.m";
	srv: Srv;
include "string.m";
	str: String;
include "keyring.m";
include "security.m";
include "tls12.m";
	tls12: TLS12;
	Session: import tls12;
include "doh.m";
include "https.m";

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "https: load sys module failed";
	dial = load Dial Dial->PATH;
	if(dial == nil)
		return "https: load dial module failed";
	str = load String String->PATH;
	if(str == nil)
		return "https: load string module failed";
	tls12 = load TLS12 TLS12->PATH;
	if(tls12 == nil)
		return "https: load tls12 module failed";
	if((err := tls12->init()) != nil)
		return "https: "+err;
	# $Srv is hosted-only; its absence just disables the resolver
	# fallback, it is not an error here
	srv = load Srv Srv->PATH;
	if(srv != nil)
		srv->init();
	return nil;
}

request(method, url: string, hdrs: list of (string, string), body: array of byte):
	(int, list of (string, string), array of byte, string)
{
	return requestto(method, url, "", hdrs, body);
}

requestto(method, url, dialaddr: string, hdrs: list of (string, string), body: array of byte):
	(int, list of (string, string), array of byte, string)
{
	(host, port, pathq, uerr) := parseurl(url);
	if(uerr != nil)
		return (0, nil, nil, uerr);

	fd: ref Sys->FD;
	derr: string;
	if(dialaddr != ""){
		# dial the pinned address, but keep host for SNI/cert/Host
		a := dialaddr;
		if(!hasport(a))
			a += "!"+port;
		c := dial->dial("tcp!"+a, nil);
		if(c == nil)
			derr = sys->sprint("https: dial %s: %r", dialaddr);
		else
			fd = c.dfd;
	}else
		(fd, derr) = connect(host, port);
	if(derr != nil)
		return (0, nil, nil, derr);

	(s, terr) := tls12->client(fd, host, nil);
	if(terr != nil)
		return (0, nil, nil, terr);

	# request head + body
	req := method+" "+pathq+" HTTP/1.1\r\n" +
		"Host: "+host+"\r\n" +
		"User-Agent: inferno-https\r\n" +
		"Accept: */*\r\n" +
		"Connection: close\r\n";
	for(hl := hdrs; hl != nil; hl = tl hl){
		(hn, hv) := hd hl;
		req += hn+": "+hv+"\r\n";
	}
	if(body != nil)
		req += sys->sprint("Content-Length: %d\r\n", len body);
	req += "\r\n";
	reqb := array of byte req;
	if(s.write(reqb, len reqb) != len reqb)
		return (0, nil, nil, "https: request write: "+s.err);
	if(body != nil && s.write(body, len body) != len body)
		return (0, nil, nil, "https: request body write: "+s.err);

	# response head
	(head, rest, herr) := readhead(s);
	if(herr != nil)
		return (0, nil, nil, herr);
	(status, rhdrs, perr) := parsehead(head);
	if(perr != nil)
		return (0, nil, nil, perr);

	# response body, by its own framing
	rbody: array of byte;
	berr: string;
	clen := hdrint(rhdrs, "content-length");
	if(streq(hdrget(rhdrs, "transfer-encoding"), "chunked"))
		(rbody, berr) = readchunked(s, rest);
	else if(clen >= 0)
		(rbody, berr) = readexact(s, rest, clen);
	else
		rbody = readtoclose(s, rest);
	if(berr != nil)
		return (0, nil, nil, berr);

	s.close();
	return (status, rhdrs, rbody, nil);
}

# ---- connection ----

# does a dial address already carry a "!port" suffix?
hasport(a: string): int
{
	for(i := 0; i < len a; i++)
		if(a[i] == '!')
			return 1;
	return 0;
}

# DoH resolver, loaded lazily the first time a name needs resolving.
# It is NOT loaded in init() to avoid a load-time cycle (doh(2) loads
# https(2)); and doh(2)'s own resolver request goes through
# requestto() with the resolver's literal IP, which dials directly and
# never re-enters connect(), so there is no recursion.
doh: DOH;
dohtried: int;
# a tiny per-process resolution cache (host -> addresses), so repeated
# requests to the same host cost one DoH lookup, not one per request
rcache: list of (string, list of string);

connect(host, port: string): (ref Sys->FD, string)
{
	# a literal IPv4 address needs no resolution
	if(isipv4(host))
		return dialone(host, port);

	# a cached resolution
	for(cl := rcache; cl != nil; cl = tl cl){
		(h, as) := hd cl;
		if(h == host)
			return dialany(as, port, host);
	}

	# resolve the name ourselves, over our own TLS (doh(2)) - this is
	# what lets the whole stack resolve hostnames with no /net/cs and
	# no host resolver
	if(!dohtried){
		dohtried = 1;
		doh = load DOH DOH->PATH;
		if(doh != nil && doh->init() != nil)
			doh = nil;
	}
	if(doh != nil){
		(addrs, rerr) := doh->resolve(nil, host);
		if(addrs != nil){
			rcache = (host, addrs) :: rcache;
			return dialany(addrs, port, host);
		}
		# rerr non-nil (e.g. NXDOMAIN or a transient DoH failure):
		# fall through to the legacy resolvers below
		rerr = rerr;
	}

	# fallbacks: a mounted connection server (ndb/cs), then the hosted
	# emu's own $Srv resolver

	c := dial->dial("tcp!"+host+"!"+port, nil);
	if(c != nil)
		return (c.dfd, nil);
	if(srv != nil){
		addrs := srv->iph2a(host);
		for(; addrs != nil; addrs = tl addrs){
			c = dial->dial("tcp!"+hd addrs+"!"+port, nil);
			if(c != nil)
				return (c.dfd, nil);
		}
	}
	return (nil, sys->sprint("https: cannot resolve %s", host));
}

dialone(addr, port: string): (ref Sys->FD, string)
{
	c := dial->dial("tcp!"+addr+"!"+port, nil);
	if(c == nil)
		return (nil, sys->sprint("https: dial %s: %r", addr));
	return (c.dfd, nil);
}

# try each resolved address, returning the first that connects
dialany(addrs: list of string, port, host: string): (ref Sys->FD, string)
{
	for(al := addrs; al != nil; al = tl al){
		(fd, nil) := dialone(hd al, port);
		if(fd != nil)
			return (fd, nil);
	}
	return (nil, sys->sprint("https: %s resolved but no address connected", host));
}

# a dotted-decimal IPv4 literal (so it needs no name resolution)
isipv4(s: string): int
{
	dots := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c == '.')
			dots++;
		else if(c < '0' || c > '9')
			return 0;
	}
	return dots == 3;
}

parseurl(url: string): (string, string, string, string)
{
	if(len url < 8 || str->tolower(url[0:8]) != "https://")
		return (nil, nil, nil, "https: not an https:// url: "+url);
	rest := url[8:];
	hostport := rest;
	pathq := "/";
	for(i := 0; i < len rest; i++)
		if(rest[i] == '/'){
			hostport = rest[0:i];
			pathq = rest[i:];
			break;
		}
	host := hostport;
	port := "443";
	for(i = 0; i < len hostport; i++)
		if(hostport[i] == ':'){
			host = hostport[0:i];
			port = hostport[i+1:];
			break;
		}
	if(host == "")
		return (nil, nil, nil, "https: no host in url: "+url);
	return (host, port, pathq, nil);
}

# ---- response head ----

# read until the blank line; returns (head string, leftover body bytes)
readhead(s: ref Session): (string, array of byte, string)
{
	buf := array[0] of byte;
	chunk := array[4096] of byte;
	for(;;){
		n := s.read(chunk, len chunk);
		if(n < 0)
			return (nil, nil, "https: reading response: "+s.err);
		if(n == 0)
			return (nil, nil, "https: connection closed before response headers");
		nb := array[len buf + n] of byte;
		nb[0:] = buf;
		nb[len buf:] = chunk[0:n];
		buf = nb;
		for(i := 0; i+3 < len buf; i++)
			if(buf[i] == byte '\r' && buf[i+1] == byte '\n'
			&& buf[i+2] == byte '\r' && buf[i+3] == byte '\n')
				return (string buf[0:i], buf[i+4:], nil);
		if(len buf > 64*1024)
			return (nil, nil, "https: response headers too large");
	}
}

parsehead(head: string): (int, list of (string, string), string)
{
	(nil, lines) := sys->tokenize(head, "\r\n");	# CRLF-split; empties drop
	if(lines == nil)
		return (0, nil, "https: empty response head");
	statusline := hd lines;
	(nf, flds) := sys->tokenize(statusline, " ");
	if(nf < 2 || len hd flds < 5 || (hd flds)[0:5] != "HTTP/")
		return (0, nil, "https: bad status line: "+statusline);
	status := int hd tl flds;
	if(status < 100 || status > 599)
		return (0, nil, "https: bad status: "+statusline);
	rhdrs: list of (string, string);
	for(lines = tl lines; lines != nil; lines = tl lines){
		line := hd lines;
		for(i := 0; i < len line; i++)
			if(line[i] == ':'){
				name := str->tolower(line[0:i]);
				val := line[i+1:];
				while(len val > 0 && (val[0] == ' ' || val[0] == '\t'))
					val = val[1:];
				rhdrs = (name, val) :: rhdrs;
				break;
			}
	}
	# back to arrival order
	rev: list of (string, string);
	for(; rhdrs != nil; rhdrs = tl rhdrs)
		rev = hd rhdrs :: rev;
	return (status, rev, nil);
}

hdrget(hdrs: list of (string, string), name: string): string
{
	for(; hdrs != nil; hdrs = tl hdrs){
		(hn, hv) := hd hdrs;
		if(hn == name)
			return hv;
	}
	return nil;
}

hdrint(hdrs: list of (string, string), name: string): int
{
	v := hdrget(hdrs, name);
	if(v == nil)
		return -1;
	n := 0;
	any := 0;
	for(i := 0; i < len v; i++){
		if(v[i] < '0' || v[i] > '9')
			return -1;
		n = n*10 + (v[i]-'0');
		any = 1;
	}
	if(!any)
		return -1;
	return n;
}

streq(a, b: string): int
{
	return a != nil && str->tolower(a) == b;
}

# ---- response body framings ----

readexact(s: ref Session, have: array of byte, want: int): (array of byte, string)
{
	buf := array[want] of byte;
	got := len have;
	if(got > want)
		got = want;
	buf[0:] = have[0:got];
	while(got < want){
		n := s.read(buf[got:], want-got);
		if(n < 0)
			return (nil, "https: reading response body: "+s.err);
		if(n == 0)
			return (nil, sys->sprint("https: response body truncated at %d/%d bytes", got, want));
		got += n;
	}
	return (buf, nil);
}

readtoclose(s: ref Session, have: array of byte): array of byte
{
	buf := have;
	chunk := array[8192] of byte;
	for(;;){
		n := s.read(chunk, len chunk);
		if(n <= 0)
			return buf;	# clean close or error: all we will get
		nb := array[len buf + n] of byte;
		nb[0:] = buf;
		nb[len buf:] = chunk[0:n];
		buf = nb;
	}
}

# chunked transfer-coding (RFC 9112 7.1): size line in hex (chunk
# extensions ignored), data, CRLF, ...; 0-size chunk ends the body
# (trailer fields, if any, are read and dropped)
readchunked(s: ref Session, have: array of byte): (array of byte, string)
{
	r := ref Reader(s, have);
	body := array[0] of byte;
	for(;;){
		(line, lerr) := r.line();
		if(lerr != nil)
			return (nil, lerr);
		size := 0;
		any := 0;
	sizeloop:
		for(i := 0; i < len line; i++){
			c := line[i];
			case c {
			'0' to '9' =>
				size = size*16 + (c-'0');
			'a' to 'f' =>
				size = size*16 + (c-'a'+10);
			'A' to 'F' =>
				size = size*16 + (c-'A'+10);
			* =>
				break sizeloop;	# ';' starts a chunk extension
			}
			any = 1;
		}
		if(!any)
			return (nil, "https: bad chunk size line: "+line);
		if(size == 0)
			break;
		(data, derr) := r.exact(size);
		if(derr != nil)
			return (nil, derr);
		(nil, cerr) := r.line();	# the CRLF after the chunk data
		if(cerr != nil)
			return (nil, cerr);
		nb := array[len body + size] of byte;
		nb[0:] = body;
		nb[len body:] = data;
		body = nb;
	}
	# trailer: lines until an empty one (or close)
	for(;;){
		(line, lerr) := r.line();
		if(lerr != nil || line == "")
			break;
	}
	return (body, nil);
}

# test seam: run the chunked decoder over a plain buffer (module/https.m)
chunkedtest(raw: array of byte): (array of byte, string)
{
	return readchunked(nil, raw);
}

# small buffered reader over a Session for the chunked decoder

Reader: adt
{
	s: ref Session;
	buf: array of byte;

	fill: fn(r: self ref Reader): string;
	line: fn(r: self ref Reader): (string, string);
	exact: fn(r: self ref Reader, n: int): (array of byte, string);
};

Reader.fill(r: self ref Reader): string
{
	if(r.s == nil)	# chunkedtest(): the buffer is all there is
		return "https: connection closed mid-body";
	chunk := array[8192] of byte;
	n := r.s.read(chunk, len chunk);
	if(n < 0)
		return "https: reading response body: "+r.s.err;
	if(n == 0)
		return "https: connection closed mid-body";
	nb := array[len r.buf + n] of byte;
	nb[0:] = r.buf;
	nb[len r.buf:] = chunk[0:n];
	r.buf = nb;
	return nil;
}

Reader.line(r: self ref Reader): (string, string)
{
	for(;;){
		for(i := 0; i+1 < len r.buf; i++)
			if(r.buf[i] == byte '\r' && r.buf[i+1] == byte '\n'){
				line := string r.buf[0:i];
				r.buf = r.buf[i+2:];
				return (line, nil);
			}
		if((err := r.fill()) != nil)
			return (nil, err);
	}
}

Reader.exact(r: self ref Reader, n: int): (array of byte, string)
{
	while(len r.buf < n)
		if((err := r.fill()) != nil)
			return (nil, err);
	data := r.buf[0:n];
	r.buf = r.buf[n:];
	return (data, nil);
}

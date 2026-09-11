implement Httpclient;

#
# A small HTTP/1.1 client, enough to talk to a cloud provider.
#
# The tree had no callable HTTP client.  appl/lib/url.b parses a URL and
# stops there; webgrab(1) is a command, not a library, and sends no
# request headers a caller can choose; appl/svc/webget is a Styx service
# built for charon and speaks over a channel.  A provider needs exactly
# what none of those offer: a GET with a header the caller supplies.
# Google's metadata service will not answer without "Metadata-Flavor:
# Google", and every authenticated call to a storage API is an
# "Authorization:" header.
#
# https:// goes through tls12(2), loaded on first use so that a caller
# who only ever speaks to a metadata service does not pay for the
# crypto.  The server's certificate chain is verified against
# /lib/tls/ca-bundle.pem and must name the host: tls12->client does
# that itself and fails the handshake otherwise.
#
# Reading is done here rather than through bufio(2), because the same
# code has to serve a plain file descriptor and a TLS session, and a
# Session is not an fd.  Rd below is that one buffered reader.
#
include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
include "security.m";
include "tls12.m";
	tls: TLS12;
	Session: import tls;
include "string.m";
	str: String;
include "dial.m";
	dial: Dial;
include "url.m";
	url: Url;
	ParsedUrl: import url;
include "httpclient.m";

init(): string
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	if(str == nil)
		return "cannot load " + String->PATH;
	dial = load Dial Dial->PATH;
	if(dial == nil)
		return "cannot load " + Dial->PATH;
	url = load Url Url->PATH;
	if(url == nil)
		return "cannot load " + Url->PATH;
	url->init();
	return nil;
}

Resp.hdr(r: self ref Resp, name: string): string
{
	lname := lower(name);
	for(l := r.hdrs; l != nil; l = tl l){
		h := hd l;
		if(lower(h.name) == lname)
			return h.val;
	}
	return nil;
}

lower(s: string): string
{
	t := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c >= 'A' && c <= 'Z')
			c += 'a' - 'A';
		t[len t] = c;
	}
	return t;
}

#
# A buffered reader over either a file descriptor or a TLS session.
#
Rd: adt {
	fd:	ref Sys->FD;
	s:	ref Session;
	buf:	array of byte;
	n:	int;			# bytes held
	p:	int;			# read point
	eof:	int;
};

fill(r: ref Rd): int
{
	if(r.eof)
		return 0;
	if(r.p >= r.n){
		r.p = 0;
		if(r.s != nil)
			r.n = r.s.read(r.buf, len r.buf);
		else
			r.n = sys->read(r.fd, r.buf, len r.buf);
		if(r.n <= 0){
			r.n = 0;
			r.eof = 1;
			return 0;
		}
	}
	return r.n - r.p;
}

rdline(r: ref Rd): string
{
	line := "";
	for(;;){
		if(fill(r) <= 0)
			return line;
		c := int r.buf[r.p++];
		line[len line] = c;
		if(c == '\n')
			return line;
	}
}

rdn(r: ref Rd, n: int): (array of byte, string)
{
	if(n <= 0)
		return (array[0] of byte, nil);
	a := array[n] of byte;
	got := 0;
	while(got < n){
		if(fill(r) <= 0)
			break;
		m := r.n - r.p;
		if(m > n - got)
			m = n - got;
		a[got:] = r.buf[r.p:r.p+m];
		r.p += m;
		got += m;
	}
	if(got != n)
		return (a[0:got], "short body");
	return (a, nil);
}

rdall(r: ref Rd): (array of byte, string)
{
	a := array[8192] of byte;
	got := 0;
	for(;;){
		if(fill(r) <= 0)
			break;
		m := r.n - r.p;
		if(got + m > len a){
			na := array[(got + m) * 2] of byte;
			na[0:] = a[0:got];
			a = na;
		}
		a[got:] = r.buf[r.p:r.p+m];
		r.p += m;
		got += m;
	}
	return (a[0:got], nil);
}

get(u: string, hdrs: list of Hdr): (ref Resp, string)
{
	return request("GET", u, hdrs, nil);
}

post(u: string, hdrs: list of Hdr, body: array of byte): (ref Resp, string)
{
	return request("POST", u, hdrs, body);
}

request(method: string, u: string, hdrs: list of Hdr,
	body: array of byte): (ref Resp, string)
{
	return requestat(method, u, nil, hdrs, body);
}

requestat(method: string, u: string, addr: string, hdrs: list of Hdr,
	body: array of byte): (ref Resp, string)
{
	if(sys == nil)
		return (nil, "httpclient: init() not called");
	pu := url->makeurl(u);
	if(pu == nil)
		return (nil, "cannot parse url: " + u);
	usetls := 0;
	case pu.scheme {
	Url->HTTP =>	;
	Url->HTTPS =>	usetls = 1;
	* =>		return (nil, "httpclient: not an http or https url: " + u);
	}
	host := pu.host;
	if(host == nil)
		return (nil, "no host in url: " + u);
	port := pu.port;
	if(port == nil){
		if(usetls)
			port = "443";
		else
			port = "80";
	}
	if(usetls && tls == nil){
		tls = load TLS12 TLS12->PATH;
		if(tls == nil)
			return (nil, sys->sprint("cannot load %s: %r", TLS12->PATH));
		if((e := tls->init()) != nil)
			return (nil, "tls12: " + e);
	}

	path := pu.pstart + pu.path;
	if(path == nil || path == "")
		path = "/";
	if(pu.query != nil)
		path += "?" + pu.query;

	if(addr == nil)
		addr = "tcp!" + host + "!" + port;
	c := dial->dial(addr, nil);
	if(c == nil)
		return (nil, sys->sprint("dial %s: %r", addr));

	sess: ref Session;
	if(usetls){
		err: string;
		# the chain is verified against TLS12->CAPATH and must name
		# host; a failure of either aborts here rather than later
		(sess, err) = tls->client(c.dfd, host, nil);
		if(sess == nil)
			return (nil, "tls: " + err);
	}

	# Connection: close, deliberately.  It costs a connection per
	# request and removes every question about where one response
	# ends and the next begins, which is the only property that
	# matters for a metadata fetch.
	req := method + " " + path + " HTTP/1.1\r\n";
	req += "Host: " + host + "\r\n";
	req += "Connection: close\r\n";
	req += "User-Agent: Inferno-httpclient/1\r\n";
	for(l := hdrs; l != nil; l = tl l){
		h := hd l;
		req += h.name + ": " + h.val + "\r\n";
	}
	if(body != nil)
		req += "Content-Length: " + string len body + "\r\n";
	req += "\r\n";

	rb := array of byte req;
	if(wr(c.dfd, sess, rb) < 0)
		return (nil, sys->sprint("write request: %r"));
	if(body != nil && wr(c.dfd, sess, body) < 0)
		return (nil, sys->sprint("write body: %r"));

	b := ref Rd(c.dfd, sess, array[4096] of byte, 0, 0, 0);

	line := rdline(b);
	if(line == "")
		return (nil, "no response");
	line = trimcr(line);
	(nf, fld) := sys->tokenize(line, " ");
	if(nf < 2)
		return (nil, "malformed status line: " + line);
	r := ref Resp;
	r.code = int hd tl fld;
	if(nf >= 3)
		r.reason = hd tl tl fld;

	# headers, with continuation lines folded as RFC 9110 still allows
	last := "";
	for(;;){
		line = rdline(b);
		if(line == "")
			return (nil, "eof in headers");
		line = trimcr(line);
		if(line == "")
			break;
		if(line[0] == ' ' || line[0] == '\t'){
			if(r.hdrs != nil){
				h := hd r.hdrs;
				h.val += " " + strip(line);
				r.hdrs = h :: tl r.hdrs;
			}
			continue;
		}
		(nm, rest) := str->splitl(line, ":");
		if(rest == nil || len rest < 1)
			continue;
		last = nm;
		r.hdrs = Hdr(nm, strip(rest[1:])) :: r.hdrs;
	}
	r.hdrs = rev(r.hdrs);

	te := lower(r.hdr("Transfer-Encoding"));
	cl := r.hdr("Content-Length");
	if(te != nil && str->prefix("chunked", te))
		(r.body, nil) = readchunked(b);
	else if(cl != nil)
		(r.body, nil) = rdn(b, int cl);
	else
		(r.body, nil) = rdall(b);
	if(sess != nil)
		sess.close();
	return (r, nil);
}

trimcr(s: string): string
{
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == '\r'))
		s = s[0:len s - 1];
	return s;
}

strip(s: string): string
{
	while(len s > 0 && (s[0] == ' ' || s[0] == '\t'))
		s = s[1:];
	while(len s > 0 && (s[len s - 1] == ' ' || s[len s - 1] == '\t'))
		s = s[0:len s - 1];
	return s;
}

rev(l: list of Hdr): list of Hdr
{
	r: list of Hdr;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}



wr(fd: ref Sys->FD, s: ref Session, a: array of byte): int
{
	if(s != nil)
		return s.write(a, len a);
	if(sys->write(fd, a, len a) != len a)
		return -1;
	return len a;
}

readchunked(b: ref Rd): (array of byte, string)
{
	out := array[0] of byte;
	for(;;){
		line := rdline(b);
		if(line == "")
			return (out, "eof in chunk header");
		line = trimcr(line);
		# a chunk size may carry ";extension"
		(sz, nil) := str->splitl(line, ";");
		n := hex(sz);
		if(n < 0)
			return (out, "bad chunk size: " + line);
		if(n == 0)
			break;
		(chunk, err) := rdn(b, n);
		if(err != nil)
			return (out, err);
		no := array[len out + len chunk] of byte;
		no[0:] = out;
		no[len out:] = chunk;
		out = no;
		rdline(b);		# the CRLF after the chunk
	}
	return (out, nil);
}

hex(s: string): int
{
	s = strip(s);
	if(s == nil || len s == 0)
		return -1;
	v := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		d := -1;
		if(c >= '0' && c <= '9')
			d = c - '0';
		else if(c >= 'a' && c <= 'f')
			d = c - 'a' + 10;
		else if(c >= 'A' && c <= 'F')
			d = c - 'A' + 10;
		if(d < 0)
			return -1;
		v = v * 16 + d;
	}
	return v;
}

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
# Plain HTTP only.  That is not a shortcoming for the first use: a
# metadata service answers on a link-local address that never leaves the
# hypervisor.  For anything off the machine this wants tls12(2) and
# https(2), which exist on the inferno-rio branch.
#
include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
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
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil)
		return "cannot load " + Bufio->PATH;
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
	if(sys == nil)
		return (nil, "httpclient: init() not called");
	pu := url->makeurl(u);
	if(pu == nil)
		return (nil, "cannot parse url: " + u);
	if(pu.scheme != Url->HTTP)
		return (nil, "httpclient: only http:// is supported (no tls here)");
	host := pu.host;
	if(host == nil)
		return (nil, "no host in url: " + u);
	port := pu.port;
	if(port == nil)
		port = "80";

	path := pu.pstart + pu.path;
	if(path == nil || path == "")
		path = "/";
	if(pu.query != nil)
		path += "?" + pu.query;

	c := dial->dial("tcp!" + host + "!" + port, nil);
	if(c == nil)
		return (nil, sys->sprint("dial %s!%s: %r", host, port));

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
	if(sys->write(c.dfd, rb, len rb) != len rb)
		return (nil, sys->sprint("write request: %r"));
	if(body != nil && sys->write(c.dfd, body, len body) != len body)
		return (nil, sys->sprint("write body: %r"));

	b := bufio->fopen(c.dfd, Bufio->OREAD);
	if(b == nil)
		return (nil, sys->sprint("fopen: %r"));

	line := b.gets('\n');
	if(line == nil)
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
		line = b.gets('\n');
		if(line == nil)
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
		(r.body, nil) = readn(b, int cl);
	else
		(r.body, nil) = readall(b);
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

readn(b: ref Iobuf, n: int): (array of byte, string)
{
	if(n <= 0)
		return (array[0] of byte, nil);
	a := array[n] of byte;
	got := 0;
	while(got < n){
		m := b.read(a[got:], n - got);
		if(m <= 0)
			break;
		got += m;
	}
	if(got != n)
		return (a[0:got], "short body");
	return (a, nil);
}

readall(b: ref Iobuf): (array of byte, string)
{
	a := array[8192] of byte;
	got := 0;
	for(;;){
		if(got == len a){
			na := array[len a * 2] of byte;
			na[0:] = a[0:got];
			a = na;
		}
		m := b.read(a[got:], len a - got);
		if(m <= 0)
			break;
		got += m;
	}
	return (a[0:got], nil);
}

readchunked(b: ref Iobuf): (array of byte, string)
{
	out := array[0] of byte;
	for(;;){
		line := b.gets('\n');
		if(line == nil)
			return (out, "eof in chunk header");
		line = trimcr(line);
		# a chunk size may carry ";extension"
		(sz, nil) := str->splitl(line, ";");
		n := hex(sz);
		if(n < 0)
			return (out, "bad chunk size: " + line);
		if(n == 0)
			break;
		(chunk, err) := readn(b, n);
		if(err != nil)
			return (out, err);
		no := array[len out + len chunk] of byte;
		no[0:] = out;
		no[len out:] = chunk;
		out = no;
		b.gets('\n');		# the CRLF after the chunk
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

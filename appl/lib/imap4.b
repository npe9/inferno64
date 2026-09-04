implement Imap4;

include "sys.m";
	sys: Sys;
include "dial.m";
	dial: Dial;
	Connection: import dial;
include "keyring.m";
include "tls12.m";
	tls12: TLS12;
	Session: import tls12;
include "encoding.m";
	base64: Encoding;
include "imap4.m";

init(): string
{
	sys = load Sys Sys->PATH;
	dial = load Dial Dial->PATH;
	if(dial == nil)
		return "load dial";
	tls12 = load TLS12 TLS12->PATH;
	if(tls12 == nil)
		return "load tls12";
	base64 = load Encoding Encoding->BASE64PATH;
	if(base64 == nil)
		return "load base64";
	return tls12->init();
}

connect(host: string, port: int, dialip: string): (ref Client, string)
{
	da := host;
	if(dialip != "")
		da = dialip;
	addr := "tcp!" + da + "!" + string port;
	c := dial->dial(addr, nil);
	if(c == nil)
		return (nil, sys->sprint("dial %s: %r", addr));
	(s, err) := tls12->client(c.dfd, host, nil);
	if(err != nil)
		return (nil, "tls: " + err);
	cl := ref Client(c.dfd, s, array[0] of byte, 0, host);
	(line, gerr) := getline(cl);
	if(gerr != nil)
		return (nil, "greeting: " + gerr);
	if(!prefix("* OK", line) && !prefix("* PREAUTH", line))
		return (nil, "unexpected greeting: " + line);
	return (cl, nil);
}

# ---- transport: buffered line/literal reads over the TLS session ----

fillmore(c: ref Client): string
{
	tmp := array[4096] of byte;
	n := c.sess.read(tmp, len tmp);
	if(n < 0)
		return "read: " + c.sess.err;
	if(n == 0)
		return "connection closed";
	nb := array[len c.rbuf + n] of byte;
	nb[0:] = c.rbuf;
	nb[len c.rbuf:] = tmp[0:n];
	c.rbuf = nb;
	return nil;
}

getline(c: ref Client): (string, string)
{
	for(;;){
		for(i := 0; i + 1 < len c.rbuf; i++)
			if(c.rbuf[i] == byte '\r' && c.rbuf[i + 1] == byte '\n'){
				line := string c.rbuf[0:i];
				c.rbuf = c.rbuf[i + 2:];
				return (line, nil);
			}
		if((e := fillmore(c)) != nil)
			return ("", e);
	}
}

getbytes(c: ref Client, n: int): (array of byte, string)
{
	while(len c.rbuf < n)
		if((e := fillmore(c)) != nil)
			return (nil, e);
	out := c.rbuf[0:n];
	c.rbuf = c.rbuf[n:];
	return (out, nil);
}

send(c: ref Client, s: string): string
{
	b := array of byte s;
	if(c.sess.write(b, len b) != len b)
		return "write: " + c.sess.err;
	return nil;
}

# ---- command / response ----

Client.docmd(c: self ref Client, command: string): (list of string, string, string)
{
	c.tagn++;
	tag := sys->sprint("a%04d", c.tagn);
	if((e := send(c, tag + " " + command + "\r\n")) != nil)
		return (nil, "", e);
	untag: list of string;
	for(;;){
		(line, le) := getline(c);
		if(le != nil)
			return (nil, "", le);
		(hasl, n) := litcount(line);
		if(hasl){
			(lit, be) := getbytes(c, n);
			if(be != nil)
				return (nil, "", be);
			(rest, re) := getline(c);
			if(re != nil)
				return (nil, "", re);
			line += string lit + rest;
		}
		if(prefix(tag + " ", line))
			return (untag, line, nil);
		untag = line :: untag;
	}
}

Client.capa(c: self ref Client): (string, string)
{
	(untag, comp, e) := c.docmd("CAPABILITY");
	if(e != nil)
		return ("", e);
	if(!isok(comp))
		return ("", comp);
	for(l := untag; l != nil; l = tl l)
		if(prefix("* CAPABILITY", hd l))
			return (hd l, nil);
	return ("", nil);
}

Client.login(c: self ref Client, user, pass: string): string
{
	(nil, comp, e) := c.docmd("LOGIN " + quote(user) + " " + quote(pass));
	if(e != nil)
		return e;
	if(!isok(comp))
		return "login rejected: " + comp;
	return nil;
}

Client.authxoauth2(c: self ref Client, user, token: string): string
{
	# SASL XOAUTH2 initial-response string (Gmail advertises SASL-IR):
	# base64("user=<user>^Aauth=Bearer <token>^A^A").
	sasl := "user=" + user + "\u0001auth=Bearer " + token + "\u0001\u0001";
	(nil, comp, e) := c.docmd("AUTHENTICATE XOAUTH2 " + base64->enc(array of byte sasl));
	if(e != nil)
		return e;
	if(!isok(comp))
		return "xoauth2 rejected: " + comp;
	return nil;
}

Client.mailboxes(c: self ref Client, reff, pat: string): (list of string, string)
{
	(untag, comp, e) := c.docmd("LIST " + quote(reff) + " " + quote(pat));
	if(e != nil)
		return (nil, e);
	if(!isok(comp))
		return (nil, comp);
	res: list of string;
	for(l := untag; l != nil; l = tl l)
		if(prefix("* LIST", hd l))
			res = hd l :: res;
	return (res, nil);
}

Client.select(c: self ref Client, mbox: string): (int, string)
{
	return selectcmd(c, "SELECT", mbox);
}

Client.examine(c: self ref Client, mbox: string): (int, string)
{
	return selectcmd(c, "EXAMINE", mbox);
}

selectcmd(c: ref Client, verb, mbox: string): (int, string)
{
	(untag, comp, e) := c.docmd(verb + " " + quote(mbox));
	if(e != nil)
		return (0, e);
	if(!isok(comp))
		return (0, comp);
	n := 0;
	for(l := untag; l != nil; l = tl l){
		(cnt, f) := sys->tokenize(hd l, " ");
		if(cnt == 3 && hd f == "*" && hd tl tl f == "EXISTS")
			n = int hd tl f;
	}
	return (n, nil);
}

Client.status(c: self ref Client, mbox, items: string): (string, string)
{
	(untag, comp, e) := c.docmd("STATUS " + quote(mbox) + " (" + items + ")");
	if(e != nil)
		return ("", e);
	if(!isok(comp))
		return ("", comp);
	for(l := untag; l != nil; l = tl l)
		if(prefix("* STATUS", hd l))
			return (hd l, nil);
	return ("", nil);
}

Client.search(c: self ref Client, criteria: string): (list of int, string)
{
	(untag, comp, e) := c.docmd("SEARCH " + criteria);
	if(e != nil)
		return (nil, e);
	if(!isok(comp))
		return (nil, comp);
	rnums: list of int;
	for(l := untag; l != nil; l = tl l)
		if(prefix("* SEARCH", hd l)){
			(nil, f) := sys->tokenize((hd l)[len "* SEARCH":], " ");
			for(; f != nil; f = tl f)
				rnums = int hd f :: rnums;
		}
	nums: list of int;
	for(; rnums != nil; rnums = tl rnums)
		nums = hd rnums :: nums;
	return (nums, nil);
}

Client.store(c: self ref Client, msg: int, item: string): string
{
	return simplecmd(c, sys->sprint("STORE %d %s", msg, item));
}

Client.copy(c: self ref Client, msg: int, mbox: string): string
{
	return simplecmd(c, sys->sprint("COPY %d %s", msg, quote(mbox)));
}

Client.expunge(c: self ref Client): string
{
	return simplecmd(c, "EXPUNGE");
}

Client.create(c: self ref Client, mbox: string): string
{
	return simplecmd(c, "CREATE " + quote(mbox));
}

Client.delete(c: self ref Client, mbox: string): string
{
	return simplecmd(c, "DELETE " + quote(mbox));
}

Client.rename(c: self ref Client, old, newmb: string): string
{
	return simplecmd(c, "RENAME " + quote(old) + " " + quote(newmb));
}

simplecmd(c: ref Client, command: string): string
{
	(nil, comp, e) := c.docmd(command);
	if(e != nil)
		return e;
	if(!isok(comp))
		return comp;
	return nil;
}

# FETCH captures the item's literal bytes exactly (binary-safe).
Client.fetch(c: self ref Client, msg: int, item: string): (array of byte, string)
{
	c.tagn++;
	tag := sys->sprint("a%04d", c.tagn);
	if((e := send(c, sys->sprint("%s FETCH %d (%s)\r\n", tag, msg, item))) != nil)
		return (nil, e);
	body: array of byte;
	for(;;){
		(line, le) := getline(c);
		if(le != nil)
			return (nil, le);
		(hasl, n) := litcount(line);
		if(hasl){
			(lit, be) := getbytes(c, n);
			if(be != nil)
				return (nil, be);
			body = lit;
			(nil, re) := getline(c);	# the ")" tail after the literal
			if(re != nil)
				return (nil, re);
			continue;
		}
		if(prefix(tag + " ", line)){
			if(isok(line))
				return (body, nil);
			return (nil, "fetch failed: " + line);
		}
	}
}

Client.logout(c: self ref Client): string
{
	c.docmd("LOGOUT");
	if(c.sess != nil)
		c.sess.close();
	return nil;
}

# ---- small helpers ----

# if line ends with a "{n}" literal announcement, return (1, n).
litcount(line: string): (int, int)
{
	if(len line < 3 || line[len line - 1] != '}')
		return (0, 0);
	i := len line - 2;
	while(i >= 0 && line[i] >= '0' && line[i] <= '9')
		i--;
	if(i < 0 || line[i] != '{' || i == len line - 2)
		return (0, 0);
	return (1, int line[i + 1:len line - 1]);
}

isok(completion: string): int
{
	# completion is "<tag> OK ..."; treat anything with " OK" as success.
	(nil, f) := sys->tokenize(completion, " ");
	return f != nil && tl f != nil && hd tl f == "OK";
}

# IMAP quoted string with backslash-escaping of " and \.
quote(s: string): string
{
	r := "\"";
	for(i := 0; i < len s; i++){
		if(s[i] == '"' || s[i] == '\\')
			r[len r] = '\\';
		r[len r] = s[i];
	}
	r[len r] = '"';
	return r;
}

prefix(p, s: string): int
{
	return len s >= len p && s[0:len p] == p;
}

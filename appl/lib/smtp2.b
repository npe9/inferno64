implement Smtp2;

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
include "smtp2.m";

init(): string
{
	sys = load Sys Sys->PATH;
	dial = load Dial Dial->PATH;
	if(dial == nil)
		return "load dial";
	base64 = load Encoding Encoding->BASE64PATH;
	if(base64 == nil)
		return "load base64";
	tls12 = load TLS12 TLS12->PATH;
	if(tls12 == nil)
		return "load tls12";
	return tls12->init();
}

connect(host: string, port: int, dialip: string): (ref Sender, string)
{
	da := host;
	if(dialip != "")
		da = dialip;
	addr := "tcp!" + da + "!" + string port;
	c := dial->dial(addr, nil);
	if(c == nil)
		return (nil, sys->sprint("dial %s: %r", addr));
	(sess, err) := tls12->client(c.dfd, host, nil);
	if(err != nil)
		return (nil, "tls: " + err);
	s := ref Sender(c.dfd, sess, array[0] of byte, "");
	(code, text, re) := readreply(s);
	if(re != nil)
		return (nil, "greeting: " + re);
	if(code != 220)
		return (nil, "unexpected greeting: " + text);
	s.greeting = text;
	return (s, nil);
}

Sender.ehlo(s: self ref Sender, me: string): (string, string)
{
	if((e := send(s, "EHLO " + me + "\r\n")) != nil)
		return ("", e);
	(code, text, re) := readreply(s);
	if(re != nil)
		return ("", re);
	if(code != 250)
		return ("", "EHLO refused: " + text);
	return (text, nil);
}

Sender.auth(s: self ref Sender, user, pass: string): string
{
	# AUTH PLAIN: base64 of \0 user \0 pass
	plain := array[1 + len user + 1 + len pass] of byte;
	plain[0] = byte 0;
	plain[1:] = array of byte user;
	plain[1 + len user] = byte 0;
	plain[1 + len user + 1:] = array of byte pass;
	if((e := send(s, "AUTH PLAIN " + base64->enc(plain) + "\r\n")) != nil)
		return e;
	(code, text, re) := readreply(s);
	if(re != nil)
		return re;
	if(code != 235)
		return "auth failed: " + text;
	return nil;
}

Sender.mail(s: self ref Sender, from: string, rcpts: list of string, msg: array of byte): string
{
	if((e := cmd(s, "MAIL FROM:<" + from + ">", 250)) != nil)
		return e;
	for(l := rcpts; l != nil; l = tl l)
		if((e = cmd(s, "RCPT TO:<" + hd l + ">", 250)) != nil)
			return e;
	if((e = cmd(s, "DATA", 354)) != nil)
		return e;
	# body, dot-stuffed and CRLF-terminated, then the lone "." line.
	if((e = send(s, dotstuff(msg) + "\r\n.\r\n")) != nil)
		return e;
	(code, text, re) := readreply(s);
	if(re != nil)
		return re;
	if(code != 250)
		return "message rejected: " + text;
	return nil;
}

Sender.quit(s: self ref Sender): string
{
	send(s, "QUIT\r\n");
	readreply(s);
	if(s.sess != nil)
		s.sess.close();
	return nil;
}

# ---- helpers ----

cmd(s: ref Sender, line: string, want: int): string
{
	if((e := send(s, line + "\r\n")) != nil)
		return e;
	(code, text, re) := readreply(s);
	if(re != nil)
		return re;
	if(code != want)
		return sys->sprint("%s: %s", line, text);
	return nil;
}

# read a (possibly multi-line) SMTP reply: continuation lines are
# "NNN-text", the final line is "NNN text".
readreply(s: ref Sender): (int, string, string)
{
	text := "";
	for(;;){
		(line, e) := getline(s);
		if(e != nil)
			return (0, "", e);
		if(text != "")
			text += "\n";
		text += line;
		if(len line < 4)
			return (0, text, "short reply line: " + line);
		if(line[3] == ' ')
			return (int line[0:3], text, nil);
		# else line[3]=='-', a continuation
	}
}

send(s: ref Sender, str: string): string
{
	b := array of byte str;
	if(s.sess.write(b, len b) != len b)
		return "write: " + s.sess.err;
	return nil;
}

fillmore(s: ref Sender): string
{
	tmp := array[4096] of byte;
	n := s.sess.read(tmp, len tmp);
	if(n < 0)
		return "read: " + s.sess.err;
	if(n == 0)
		return "connection closed";
	nb := array[len s.rbuf + n] of byte;
	nb[0:] = s.rbuf;
	nb[len s.rbuf:] = tmp[0:n];
	s.rbuf = nb;
	return nil;
}

getline(s: ref Sender): (string, string)
{
	for(;;){
		for(i := 0; i + 1 < len s.rbuf; i++)
			if(s.rbuf[i] == byte '\r' && s.rbuf[i + 1] == byte '\n'){
				line := string s.rbuf[0:i];
				s.rbuf = s.rbuf[i + 2:];
				return (line, nil);
			}
		if((e := fillmore(s)) != nil)
			return ("", e);
	}
}

# normalise to CRLF line endings and escape a leading '.' on any line.
dotstuff(msg: array of byte): string
{
	out := "";
	atbol := 1;
	for(i := 0; i < len msg; i++){
		c := int msg[i];
		if(c == '\r')
			continue;		# drop; we re-add CRLF at \n
		if(c == '\n'){
			out += "\r\n";
			atbol = 1;
			continue;
		}
		if(atbol && c == '.')
			out[len out] = '.';	# stuff an extra dot
		out[len out] = c;
		atbol = 0;
	}
	return out;
}

implement Command;

# upas/send - submit a message through an SMTP server over TLS (smtp2(2)).
# Reaches Gmail at smtp.gmail.com:465 (implicit TLS). With no user it just
# probes the transport (TLS handshake, greeting, EHLO capabilities) - no
# mail is sent. With -u/-P and -f/-t it authenticates (an app password
# over TLS) and sends the message read from a file or standard input.
#
#	upas/send [-s server] [-a dialip] [-p port] [-u user] [-P passfile]
#	          [-f from] [-t rcpt] ... [msgfile]

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
include "tls12.m";
include "smtp2.m";
	smtp2: Smtp2;
	Sender: import smtp2;
include "encoding.m";
	base64: Encoding;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

stderr: ref Sys->FD;
BOUNDARY: con "upas-boundary-Ma1lPart";

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	smtp2 = load Smtp2 Smtp2->PATH;
	if(smtp2 == nil)
		fail(sys->sprint("load smtp2: %r"));
	base64 = load Encoding Encoding->BASE64PATH;
	if(base64 == nil)
		fail("load base64");

	server := "smtp.gmail.com";
	dialip := "";
	port := 465;
	user := "";
	passfile := "";
	from := "";
	rcpts: list of string;
	subject := "";
	attach: list of string;
	dryrun := 0;
	msgfile := "";

	argv = tl argv;
	while(argv != nil && len hd argv > 0 && (hd argv)[0] == '-'){
		opt := hd argv;
		argv = tl argv;
		case opt {
		"-s" =>	server = arg(argv); argv = tl argv;
		"-a" =>	dialip = arg(argv); argv = tl argv;
		"-p" =>	port = int arg(argv); argv = tl argv;
		"-u" =>	user = arg(argv); argv = tl argv;
		"-P" =>	passfile = arg(argv); argv = tl argv;
		"-f" =>	from = arg(argv); argv = tl argv;
		"-t" =>	rcpts = arg(argv) :: rcpts; argv = tl argv;
		"-j" =>	subject = arg(argv); argv = tl argv;		# subject
		"-A" =>	attach = arg(argv) :: attach; argv = tl argv;	# attach a file
		"-N" =>	dryrun = 1;					# compose only, no send
		* =>	usage();
		}
	}
	if(argv != nil)
		msgfile = hd argv;

	# compose a MIME message (headers + body + attachments) when a
	# subject or attachment is given, else use msgfile/stdin verbatim.
	composing := subject != "" || attach != nil;

	if(dryrun){				# compose only: write the message, no network
		msg := buildmessage(composing, from, rcpts, subject, msgfile, attach);
		sys->write(sys->fildes(1), msg, len msg);
		return;
	}

	# smtp2 needs its own load before connect
	if((e := smtp2->init()) != nil)
		fail("smtp2 init: " + e);
	(s, ce) := smtp2->connect(server, port, dialip);
	if(ce != nil)
		fail(sys->sprint("connect %s:%d: %s", server, port, ce));
	sys->print("connected to %s:%d over TLS\n", server, port);

	(caps, ee) := s.ehlo("inferno");
	if(ee != nil)
		fail(ee);
	sys->print("%s\n", caps);

	if(user != ""){
		if(from == "" || rcpts == nil)
			fail("need -f from and at least one -t rcpt to send");
		pass := readpass(passfile);
		if(pass == "")
			fail("no password (use -P passfile)");
		if((ae := s.auth(user, pass)) != nil)
			fail(ae);
		sys->print("authenticated as %s\n", user);
		msg := buildmessage(composing, from, rcpts, subject, msgfile, attach);
		if((me := s.mail(from, rev(rcpts), msg)) != nil)
			fail(me);
		sys->print("message accepted for delivery\n");
	}
	s.quit();
}

buildmessage(composing: int, from: string, rcpts: list of string, subject, msgfile: string, attach: list of string): array of byte
{
	if(composing)
		return composemsg(from, rev(rcpts), subject, readmsg(msgfile), rev(attach));
	return readmsg(msgfile);
}

# build an RFC 822 / MIME message: headers, a text/plain body, and any
# attachments base64-encoded into a multipart/mixed message.
composemsg(from: string, rcpts: list of string, subject: string, body: array of byte, attach: list of string): array of byte
{
	hdr := "From: " + from + "\n" +
		"To: " + joinrcpts(rcpts) + "\n";
	if(subject != "")
		hdr += "Subject: " + subject + "\n";
	hdr += "MIME-Version: 1.0\n";
	if(attach == nil){
		hdr += "Content-Type: text/plain; charset=\"UTF-8\"\n\n";
		return cat(array of byte hdr, body);
	}
	hdr += "Content-Type: multipart/mixed; boundary=\"" + BOUNDARY + "\"\n\n";
	out := array of byte hdr;
	out = cat(out, array of byte ("--" + BOUNDARY +
		"\nContent-Type: text/plain; charset=\"UTF-8\"\n\n"));
	out = cat(out, body);
	out = cat(out, array of byte "\n");
	for(; attach != nil; attach = tl attach){
		fname := basename(hd attach);
		data := readfile(hd attach);
		if(data == nil)
			fail(sys->sprint("cannot read attachment %s", hd attach));
		out = cat(out, array of byte ("--" + BOUNDARY +
			"\nContent-Type: " + ctype(fname) + "; name=\"" + fname + "\"" +
			"\nContent-Transfer-Encoding: base64" +
			"\nContent-Disposition: attachment; filename=\"" + fname + "\"\n\n"));
		out = cat(out, array of byte (wrap76(base64->enc(data)) + "\n"));
	}
	out = cat(out, array of byte ("--" + BOUNDARY + "--\n"));
	return out;
}

cat(a, b: array of byte): array of byte
{
	r := array[len a + len b] of byte;
	r[0:] = a;
	r[len a:] = b;
	return r;
}

joinrcpts(l: list of string): string
{
	s := "";
	for(; l != nil; l = tl l){
		if(s != "")
			s += ", ";
		s += hd l;
	}
	return s;
}

# wrap a base64 string at 76 columns, as MIME requires.
wrap76(s: string): string
{
	r := "";
	for(i := 0; i < len s; i += 76){
		e := i + 76;
		if(e > len s)
			e = len s;
		if(r != "")
			r += "\n";
		r += s[i:e];
	}
	return r;
}

basename(p: string): string
{
	for(i := len p - 1; i >= 0; i--)
		if(p[i] == '/')
			return p[i + 1:];
	return p;
}

ctype(fname: string): string
{
	if(hassuffix(fname, ".txt")) return "text/plain";
	if(hassuffix(fname, ".html") || hassuffix(fname, ".htm")) return "text/html";
	if(hassuffix(fname, ".pdf")) return "application/pdf";
	if(hassuffix(fname, ".png")) return "image/png";
	if(hassuffix(fname, ".jpg") || hassuffix(fname, ".jpeg")) return "image/jpeg";
	if(hassuffix(fname, ".gif")) return "image/gif";
	return "application/octet-stream";
}

hassuffix(s, suf: string): int
{
	return len s >= len suf && s[len s - len suf:] == suf;
}

readfile(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	out := array[0] of byte;
	buf := array[8192] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		no := array[len out + n] of byte;
		no[0:] = out;
		no[len out:] = buf[0:n];
		out = no;
	}
	return out;
}

arg(a: list of string): string
{
	if(a == nil)
		usage();
	return hd a;
}

rev(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

readmsg(msgfile: string): array of byte
{
	fd := sys->fildes(0);
	if(msgfile != ""){
		fd = sys->open(msgfile, Sys->OREAD);
		if(fd == nil)
			fail(sys->sprint("open %s: %r", msgfile));
	}
	out := array[0] of byte;
	buf := array[8192] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		no := array[len out + n] of byte;
		no[0:] = out;
		no[len out:] = buf[0:n];
		out = no;
	}
	return out;
}

readpass(passfile: string): string
{
	if(passfile == "")
		return "";
	fd := sys->open(passfile, Sys->OREAD);
	if(fd == nil)
		fail(sys->sprint("open %s: %r", passfile));
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	s := string buf[0:n];
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == '\r'))
		s = s[0:len s - 1];
	return s;
}

usage()
{
	sys->fprint(stderr, "usage: upas/send [-s server] [-a dialip] [-p port] [-u user] [-P passfile] [-f from] [-t rcpt]... [-j subject] [-A attach]... [-N] [msgfile]\n");
	raise "fail:usage";
}

fail(m: string)
{
	sys->fprint(stderr, "upas/send: %s\n", m);
	raise "fail:" + m;
}

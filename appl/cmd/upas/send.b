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

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

stderr: ref Sys->FD;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	smtp2 = load Smtp2 Smtp2->PATH;
	if(smtp2 == nil)
		fail(sys->sprint("load smtp2: %r"));
	if((e := smtp2->init()) != nil)
		fail("smtp2 init: " + e);

	server := "smtp.gmail.com";
	dialip := "";
	port := 465;
	user := "";
	passfile := "";
	from := "";
	rcpts: list of string;
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
		* =>	usage();
		}
	}
	if(argv != nil)
		msgfile = hd argv;

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
		msg := readmsg(msgfile);
		if((me := s.mail(from, rev(rcpts), msg)) != nil)
			fail(me);
		sys->print("message accepted for delivery\n");
	}
	s.quit();
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
	sys->fprint(stderr, "usage: upas/send [-s server] [-a dialip] [-p port] [-u user] [-P passfile] [-f from] [-t rcpt]... [msgfile]\n");
	raise "fail:usage";
}

fail(m: string)
{
	sys->fprint(stderr, "upas/send: %s\n", m);
	raise "fail:" + m;
}

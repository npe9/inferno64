implement Command;

# upas/fetch - fetch mail from an IMAP server over TLS (imap4(2)). Reaches
# Gmail at imap.gmail.com:993. With no user it just probes the transport
# (TLS handshake, greeting, CAPABILITY) - useful to confirm reachability
# without credentials. With -u/-P it logs in (an app password over TLS),
# selects INBOX, and prints headers of the most recent messages.
#
#	upas/fetch [-s server] [-p port] [-u user] [-P passfile] [-n n] [-b]
#
# -b fetches full message bodies instead of just headers.

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
include "tls12.m";
include "imap4.m";
	imap4: Imap4;
	Client: import imap4;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

stderr: ref Sys->FD;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	imap4 = load Imap4 Imap4->PATH;
	if(imap4 == nil)
		fail(sys->sprint("load imap4: %r"));
	if((e := imap4->init()) != nil)
		fail("imap4 init: " + e);

	server := "imap.gmail.com";
	dialip := "";
	port := 993;
	user := "";
	passfile := "";
	nwant := 5;
	full := 0;
	mboxout := "";

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
		"-n" =>	nwant = int arg(argv); argv = tl argv;
		"-b" =>	full = 1;
		"-o" =>	mboxout = arg(argv); argv = tl argv; full = 1;	# save as mbox for upas/fs
		* =>	usage();
		}
	}
	mfd: ref Sys->FD;
	if(mboxout != ""){
		mfd = sys->create(mboxout, Sys->OWRITE, 8r644);
		if(mfd == nil)
			fail(sys->sprint("create %s: %r", mboxout));
	}

	(c, ce) := imap4->connect(server, port, dialip);
	if(ce != nil)
		fail(sys->sprint("connect %s:%d: %s", server, port, ce));
	sys->print("connected to %s:%d over TLS\n", server, port);

	(cap, cae) := c.capa();
	if(cae != nil)
		fail("capability: " + cae);
	sys->print("%s\n", cap);

	if(user != ""){
		pass := readpass(passfile);
		if(pass == "")
			fail("no password (use -P passfile)");
		if((le := c.login(user, pass)) != nil)
			fail(le);
		sys->print("logged in as %s\n", user);

		(cnt, se) := c.select("INBOX");
		if(se != nil)
			fail(se);
		sys->print("INBOX: %d message(s)\n", cnt);

		start := cnt - nwant + 1;
		if(start < 1)
			start = 1;
		item := "BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)]";
		if(full)
			item = "BODY.PEEK[]";
		for(m := start; m <= cnt; m++){
			(data, fe) := c.fetch(m, item);
			if(fe != nil)
				fail(fe);
			if(mfd != nil)
				writembox(mfd, m, data);
			else
				sys->print("===== message %d =====\n%s\n", m, string data);
		}
		if(mfd != nil)
			sys->print("wrote %d message(s) to %s\n", cnt - start + 1, mboxout);
	}
	c.logout();
}

arg(a: list of string): string
{
	if(a == nil)
		usage();
	return hd a;
}

# append one message to an mbox: a "From " envelope line, the raw message,
# then a blank line so upas/fs(4) can split it back out.
writembox(fd: ref Sys->FD, m: int, data: array of byte)
{
	env := array of byte sys->sprint("From upas@localhost message %d\n", m);
	sys->write(fd, env, len env);
	sys->write(fd, data, len data);
	nl := array of byte "\n";
	sys->write(fd, nl, len nl);
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
	sys->fprint(stderr, "usage: upas/fetch [-s server] [-a dialip] [-p port] [-u user] [-P passfile] [-n n] [-b] [-o mbox]\n");
	raise "fail:usage";
}

fail(m: string)
{
	sys->fprint(stderr, "upas/fetch: %s\n", m);
	raise "fail:" + m;
}

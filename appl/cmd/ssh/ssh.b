implement Command;

# ssh(1) - run a command on a remote host over SSH-2, using this tree's
# own ssh(2) client (curve25519 / rsa-sha2-256 / chacha20-poly1305).
# Non-interactive: it opens a session, execs the command, streams the
# output and exits with the remote status. See ssh(2) for the protocol.

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "keyring.m";
include "security.m";
include "encoding.m";
include "asn1.m";
include "pkcs.m";
include "doh.m";
	doh: DOH;
include "ssh.m";
	ssh: Ssh;
	Conn, Authkey: import ssh;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

stderr: ref Sys->FD;

usage()
{
	sys->fprint(stderr, "usage: ssh [-i keyfile] [-p port] [-t sha256=thumb | -n] [user@]host command ...\n");
	raise "fail:usage";
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	keyfile := "";
	port := "22";
	wantthumb := "";
	acceptnew := 0;

	arg := load Arg Arg->PATH;
	arg->init(argv);
	arg->setusage("ssh [-i keyfile] [-p port] [-t sha256=thumb | -n] [user@]host command ...");
	while((c := arg->opt()) != 0)
		case c {
		'i' =>	keyfile = arg->earg();
		'p' =>	port = arg->earg();
		't' =>	wantthumb = arg->earg();
		'n' =>	acceptnew = 1;
		* =>	usage();
		}
	argv = arg->argv();
	if(argv == nil)
		usage();

	dest := hd argv;
	argv = tl argv;
	if(argv == nil){
		sys->fprint(stderr, "ssh: interactive shell is not supported; give a command to run\n");
		raise "fail:nocmd";
	}
	cmd := join(argv);

	user := "";
	(hasat, ul) := splitat(dest);
	if(hasat){
		user = hd ul;
		dest = hd tl ul;
	}
	if(user == "")
		user = username();

	ssh = load Ssh Ssh->PATH;
	if(ssh == nil)
		fatal(sys->sprint("load ssh: %r"));
	ssh->init();

	# a key is required (publickey auth only, for now)
	if(keyfile == ""){
		sys->fprint(stderr, "ssh: no key given; use -i keyfile (PEM RSA private key)\n");
		raise "fail:nokey";
	}
	pem := readfile(keyfile);
	if(pem == nil)
		fatal("cannot read key file " + keyfile);
	(key, kerr) := ssh->rsakey_pem(pem);
	if(kerr != nil)
		fatal("parse key: " + kerr);

	ip := resolve(dest);
	addr := "tcp!" + ip + "!" + port;

	# connect() verifies the host-key signature over the exchange hash
	# and, when wantthumb is given, that the thumbprint matches (fail
	# closed). When no thumbprint is pinned and -n was not given, we
	# refuse but print the thumbprint so the user can re-run with -t:
	# trust-on-first-use made explicit, never silent.
	(c1, e1) := ssh->connect(addr, dest, wantthumb);
	if(e1 != nil)
		fatal(e1);
	if(wantthumb == "" && !acceptnew){
		sys->fprint(stderr, "ssh: host key for %s is %s\n", dest, c1.thumb);
		sys->fprint(stderr, "ssh: re-run with -t %s to accept it, or -n to accept unverified\n", c1.thumb);
		c1.close();
		raise "fail:hostkey";
	}
	if(acceptnew && wantthumb == "")
		sys->fprint(stderr, "ssh: warning: accepting unverified host key %s for %s\n", c1.thumb, dest);

	if((lerr := ssh->login(c1, user, key, "")) != nil)
		fatal("login: " + lerr);

	(res, rerr) := ssh->run(c1, cmd);
	if(rerr != nil)
		fatal("run: " + rerr);
	if(len res.stdout > 0)
		sys->write(sys->fildes(1), res.stdout, len res.stdout);
	if(len res.stderr > 0)
		sys->write(stderr, res.stderr, len res.stderr);
	c1.close();

	if(res.status != 0)
		raise sys->sprint("fail:exit %d", res.status);
}

# resolve dest to an IPv4 literal, via DoH unless it already is one
resolve(dest: string): string
{
	if(isipv4(dest))
		return dest;
	doh = load DOH DOH->PATH;
	if(doh == nil)
		fatal(sys->sprint("load doh: %r"));
	if((e := doh->init()) != nil)
		fatal("doh init: " + e);
	(ips, derr) := doh->resolve(nil, dest);
	if(derr != nil)
		fatal("resolve " + dest + ": " + derr);
	if(ips == nil)
		fatal("resolve " + dest + ": no addresses");
	return hd ips;
}

isipv4(s: string): int
{
	dots := 0;
	for(i := 0; i < len s; i++){
		if(s[i] == '.')
			dots++;
		else if(!(s[i] >= '0' && s[i] <= '9'))
			return 0;
	}
	return dots == 3;
}

username(): string
{
	# read /dev/user (the current user's name)
	fd := sys->open("/dev/user", Sys->OREAD);
	if(fd == nil)
		return "none";
	buf := array[128] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "none";
	return string buf[0:n];
}

# split "user@host" -> (1, user :: host :: nil); else (0, nil)
splitat(s: string): (int, list of string)
{
	for(i := 0; i < len s; i++)
		if(s[i] == '@')
			return (1, s[0:i] :: s[i+1:] :: nil);
	return (0, nil);
}

join(l: list of string): string
{
	s := "";
	for(; l != nil; l = tl l){
		if(s != "")
			s += " ";
		s += hd l;
	}
	return s;
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	buf := array[8192] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		s += string buf[0:n];
	}
	return s;
}

fatal(m: string)
{
	sys->fprint(stderr, "ssh: %s\n", m);
	raise "fail:error";
}

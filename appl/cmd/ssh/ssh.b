implement Command;

# ssh(1) - run a command on a remote host over SSH-2, using this tree's
# own ssh(2) client (curve25519 / rsa-sha2-256 / chacha20-poly1305).
# Non-interactive: it opens a session, execs the command, streams the
# output and exits with the remote status. See ssh(2) for the protocol.

include "sys.m";
	sys: Sys;
include "draw.m";
include "string.m";
	str: String;
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
	str = load String String->PATH;
	if(str == nil)
		fatal(sys->sprint("load string: %r"));
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
	cmd := "";
	if(argv != nil)
		cmd = join(argv);

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

	# publickey auth. By default the private key stays in factotum(4)
	# and signing goes through it (the Plan 9 model); -i names a PEM RSA
	# key file instead, which the client then reads and signs with
	# directly.
	key: ref Authkey;
	kerr: string;
	if(keyfile != ""){
		pem := readfile(keyfile);
		if(pem == nil)
			fatal("cannot read key file " + keyfile);
		(key, kerr) = ssh->rsakey_pem(pem);
		if(kerr != nil)
			fatal(kerr);
	} else {
		# By default the key comes from factotum. If factotum holds no
		# usable key, that is not fatal: fall back to password auth (many
		# hosts, e.g. sdf.org, want a password anyway).
		(key, kerr) = ssh->rsakey_factotum("service=ssh");
		if(kerr != nil){
			sys->fprint(stderr, "ssh: no key from factotum (%s); using password auth\n", kerr);
			key = nil;
		}
	}

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

	# With no key, prompt for a password so login can authenticate; with a
	# key, login tries publickey first and falls back to this password if
	# the server does not accept the key.
	password := "";
	if(key == nil)
		password = readpassword(sys->sprint("%s@%s's password: ", user, dest));
	if((lerr := ssh->login(c1, user, key, password)) != nil)
		fatal("login: " + lerr);

	if(cmd != ""){
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
		exit;
	}

	# no command: an interactive shell. Following the Plan 9 model
	# (telnet(1)/vt(1)), we do no terminal emulation ourselves - we set
	# the local console to raw mode and shuttle bytes; vt(1) is what
	# interprets escapes and draws. Whether to ask the remote for a
	# pseudo-terminal follows Plan 9's heuristic: a pty iff $TERM is set.
	term := getenv("TERM");
	usepty := term != "";
	cols := envint("COLS", 80);
	rows := envint("LINES", 24);
	if(usepty)
		raw(1);
	(status, serr) := ssh->shell(c1, usepty, term, cols, rows,
		sys->fildes(0), sys->fildes(1), stderr);
	if(usepty)
		raw(0);
	c1.close();
	if(serr != nil)
		fatal(serr);
	if(status != 0)
		raise sys->sprint("fail:exit %d", status);
}

# set or clear the local console's raw mode via /dev/consctl
ccfd: ref Sys->FD;
raw(on: int)
{
	if(ccfd == nil)
		ccfd = sys->open("/dev/consctl", Sys->OWRITE);
	if(ccfd == nil)
		return;			# no console (e.g. piped): nothing to do
	if(on)
		sys->fprint(ccfd, "rawon");
	else
		sys->fprint(ccfd, "rawoff");
}

# read an environment variable from /env (nil/"" if absent)
getenv(name: string): string
{
	fd := sys->open("/env/" + name, Sys->OREAD);
	if(fd == nil)
		return "";
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	# env strings may carry a trailing NUL
	if(buf[n-1] == byte 0)
		n--;
	return string buf[0:n];
}

envint(name: string, def: int): int
{
	s := getenv(name);
	if(s == "")
		return def;
	(v, nil) := str->toint(s, 10);
	if(v <= 0)
		return def;
	return v;
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

# read a line from the console without echoing it, for a password.
readpassword(prompt: string): string
{
	sys->fprint(sys->fildes(2), "%s", prompt);
	ctl := sys->open("/dev/consctl", Sys->OWRITE);
	if(ctl != nil)
		sys->fprint(ctl, "rawon");
	cons := sys->open("/dev/cons", Sys->OREAD);
	if(cons == nil)
		cons = sys->fildes(0);
	pw := "";
	buf := array[1] of byte;
	while(sys->read(cons, buf, 1) == 1){
		c := int buf[0];
		if(c == '\n' || c == '\r')
			break;
		if(c == 8 || c == 16r7f){		# backspace / delete
			if(len pw > 0)
				pw = pw[0:len pw - 1];
			continue;
		}
		pw[len pw] = c;
	}
	if(ctl != nil)
		sys->fprint(ctl, "rawoff");
	ctl = nil;
	sys->fprint(sys->fildes(2), "\n");
	return pw;
}

fatal(m: string)
{
	sys->fprint(stderr, "ssh: %s\n", m);
	raise "fail:error";
}

implement Secstored;

# secstored - a secstore(1) server. Holds each user's PAK verifier and
# their encrypted files, and serves them over a PAK-authenticated,
# encrypted channel (secstore(2)). The tree shipped only the client; this
# is the missing server, so you can run your own secstore (and so
# factotum -S has something to talk to).
#
#	auth/secstored -d storedir [-a announce] [-n servername]
#	auth/secstored -d storedir -c user           # create an account
#
# Files live under storedir/<user>/; the verifier is storedir/<user>/.pak.

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "keyring.m";
	kr: Keyring;
include "security.m";
	ssl: SSL;
include "dial.m";
	dial: Dial;
include "secstore.m";
	secstore: Secstore;

Secstored: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Maxmsg: con 4096;
Maxfile: con 128*1024;

storedir := "";
servername := "secstore";
stderr: ref Sys->FD;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	kr = load Keyring Keyring->PATH;
	ssl = load SSL SSL->PATH;
	dial = load Dial Dial->PATH;
	secstore = load Secstore Secstore->PATH;
	if(secstore == nil || ssl == nil || dial == nil || kr == nil)
		fail("cannot load a required module");
	secstore->init();

	addr := "tcp!*!secstore";
	createuser := "";
	arg := load Arg Arg->PATH;
	arg->init(argv);
	arg->setusage("auth/secstored -d storedir [-a announce] [-n name] | -c user");
	while((o := arg->opt()) != 0)
		case o {
		'd' =>	storedir = arg->earg();
		'a' =>	addr = arg->earg();
		'n' =>	servername = arg->earg();
		'c' =>	createuser = arg->earg();
		* =>	arg->usage();
		}
	if(storedir == "")
		arg->usage();

	if(createuser != ""){
		createaccount(createuser);
		return;
	}
	serve(addr);
}

createaccount(user: string)
{
	if(!valuser(user))
		fail("bad user name");
	p1 := readpassword("new secstore password for " + user + ": ");
	p2 := readpassword("confirm: ");
	if(p1 != p2)
		fail("passwords do not match");
	if(len p1 < 1)
		fail("empty password");
	hexH := secstore->mkverifier(user, p1);
	ensuredir(storedir);
	ensuredir(storedir + "/" + user);
	if((e := writefile(storedir + "/" + user + "/.pak", array of byte hexH)) != nil)
		fail(e);
	sys->print("created secstore account %s under %s\n", user, storedir);
}

serve(addr: string)
{
	ensuredir(storedir);
	ac := dial->announce(addr);
	if(ac == nil)
		fail(sys->sprint("announce %s: %r", addr));
	sys->print("secstored: serving %s at %s\n", storedir, addr);
	for(;;){
		lc := dial->listen(ac);
		if(lc == nil)
			continue;
		dfd := dial->accept(lc);
		if(dfd != nil)
			spawn handle(dfd);
	}
}

handle(dfd: ref Sys->FD)
{
	(cerr, conn) := ssl->connect(dfd);
	if(cerr != nil)
		return;
	# PAK request: "secstore\tPAK\nC=<user>\nm=<hexm>\n"
	buf := array[512] of byte;
	n := sys->read(conn.dfd, buf, len buf);
	if(n <= 0)
		return;
	(user, hexm) := parsereq(string buf[0:n]);
	if(user == "" || !valuser(user))
		return;
	hexH := trim(readstr(storedir + "/" + user + "/.pak"));

	if(hexm == "0"){			# cansecstore(): account-exists query
		if(hexH != "")
			sys->fprint(conn.dfd, "!account exists");
		else
			sys->fprint(conn.dfd, "!account does not exist");
		return;
	}
	if(hexH == ""){
		sys->fprint(conn.dfd, "!no such account");
		return;
	}
	if(secstore->pakserver(conn, user, hexm, hexH, servername) != nil)
		return;			# pakserver told the client already
	sys->fprint(conn.dfd, "OK\n");	# now over the encrypted channel
	servefiles(conn, user);
}

# parse "secstore\tPAK\nC=<user>\nm=<hexm>\n" into (user, hexm).
parsereq(s: string): (string, string)
{
	(nil, lines) := sys->tokenize(s, "\n");
	user := "";
	hexm := "";
	for(; lines != nil; lines = tl lines){
		l := hd lines;
		if(len l >= 2 && l[0:2] == "C=")
			user = l[2:];
		else if(len l >= 2 && l[0:2] == "m=")
			hexm = l[2:];
	}
	return (user, hexm);
}

servefiles(conn: ref Dial->Connection, user: string)
{
	dir := storedir + "/" + user;
	for(;;){
		buf := array[Maxmsg] of byte;
		n := sys->read(conn.dfd, buf, len buf);
		if(n <= 0)
			return;
		cmd := string buf[0:n];
		# strip a trailing newline
		while(len cmd > 0 && (cmd[len cmd - 1] == '\n' || cmd[len cmd - 1] == '\r'))
			cmd = cmd[0:len cmd - 1];
		(verb, arg) := split2(cmd);
		case verb {
		"GET" =>
			if(arg == "." || arg == "")
				sendlisting(conn, dir);
			else
				sendfile(conn, dir, arg);
		"PUT" =>
			recvfile(conn, dir, arg);
		"RM" =>
			if(safe(arg))
				sys->remove(dir + "/" + arg);
		"BYE" or "" =>
			return;
		* =>
			;	# ignore unknown
		}
	}
}

sendfile(conn: ref Dial->Connection, dir, name: string)
{
	if(!safe(name)){
		sys->fprint(conn.dfd, "-1\n");
		return;
	}
	data := readfilebytes(dir + "/" + name);
	if(data == nil){
		sys->fprint(conn.dfd, "-1\n");
		return;
	}
	sys->fprint(conn.dfd, "%d\n", len data);
	for(o := 0; o < len data;){
		m := len data - o;
		if(m > Maxmsg)
			m = Maxmsg;
		if(sys->write(conn.dfd, data[o:o + m], m) != m)
			return;
		o += m;
	}
}

recvfile(conn: ref Dial->Connection, dir, name: string)
{
	if(!safe(name))
		return;
	buf := array[64] of byte;
	n := sys->read(conn.dfd, buf, len buf);		# the length, as text
	if(n <= 0)
		return;
	nb := int string buf[0:n];
	if(nb < 0 || nb > Maxfile)
		return;
	data := array[nb] of byte;
	for(nr := 0; nr < nb;){
		m := sys->read(conn.dfd, data[nr:], nb - nr);
		if(m <= 0)
			return;
		nr += m;
	}
	writefile(dir + "/" + name, data);
}

sendlisting(conn: ref Dial->Connection, dir: string)
{
	fd := sys->open(dir, Sys->OREAD);
	listing := "";
	if(fd != nil){
		for(;;){
			(nd, ds) := sys->dirread(fd);
			if(nd <= 0)
				break;
			for(i := 0; i < nd; i++){
				nm := ds[i].name;
				if(nm == ".pak" || (len nm > 0 && nm[0] == '.'))
					continue;
				sh := array[Keyring->SHA1dlen] of byte;
				d := readfilebytes(dir + "/" + nm);
				if(d != nil)
					kr->sha1(d, len d, sh, nil);
				listing += sys->sprint("%s\t%d Jan  1 00:00:00 GMT 2026 %s\n",
					nm, int ds[i].length, hex(sh));
			}
		}
	}
	b := array of byte listing;
	sys->fprint(conn.dfd, "%d\n", len b);
	if(len b > 0)
		sys->write(conn.dfd, b, len b);
}

# ---- helpers ----

split2(s: string): (string, string)
{
	for(i := 0; i < len s; i++)
		if(s[i] == ' '){
			j := i;
			while(j < len s && s[j] == ' ')
				j++;
			return (s[0:i], s[j:]);
		}
	return (s, "");
}

safe(name: string): int
{
	if(name == "" || name == "." || name == "..")
		return 0;
	for(i := 0; i < len name; i++)
		if(name[i] == '/')
			return 0;
	return 1;
}

valuser(u: string): int
{
	if(u == "")
		return 0;
	for(i := 0; i < len u; i++)
		if(u[i] == '/' || u[i] == ' ' || u[i] == '\n')
			return 0;
	return 1;
}

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%.2x", int a[i]);
	return s;
}

trim(s: string): string
{
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == '\r' || s[len s - 1] == ' '))
		s = s[0:len s - 1];
	return s;
}

readstr(path: string): string
{
	d := readfilebytes(path);
	if(d == nil)
		return "";
	return string d;
}

readfilebytes(path: string): array of byte
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

writefile(path: string, data: array of byte): string
{
	fd := sys->create(path, Sys->OWRITE, 8r600);
	if(fd == nil)
		return sys->sprint("create %s: %r", path);
	if(sys->write(fd, data, len data) != len data)
		return sys->sprint("write %s: %r", path);
	return nil;
}

ensuredir(path: string)
{
	(ok, nil) := sys->stat(path);
	if(ok >= 0)
		return;
	fd := sys->create(path, Sys->OREAD, Sys->DMDIR | 8r700);
	if(fd == nil)
		fail(sys->sprint("create %s: %r", path));
}

readpassword(prompt: string): string
{
	sys->fprint(stderr, "%s", prompt);
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
		if(c == 8 || c == 16r7f){
			if(len pw > 0)
				pw = pw[0:len pw - 1];
			continue;
		}
		pw[len pw] = c;
	}
	if(ctl != nil)
		sys->fprint(ctl, "rawoff");
	ctl = nil;
	sys->fprint(stderr, "\n");
	return pw;
}

fail(m: string)
{
	sys->fprint(stderr, "secstored: %s\n", m);
	raise "fail:error";
}

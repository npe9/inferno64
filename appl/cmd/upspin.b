implement Command;

# upspin(1) - an Upspin-style content namespace. Content is split into
# content-addressed blocks in a Store; a name (user@domain/path) maps to a
# signed DirEntry listing those blocks; a reader verifies through a
# KeyServer (name -> owner -> key). See module/upspin.m and doc/upspin.md.
#
#	upspin [-b base] keygen  user skfile
#	upspin [-b base] keyadd  user pkfile
#	upspin [-b base] put     name file skfile
#	upspin [-b base] get     name [outfile]
#	upspin [-b base] ls      owner
#
# base holds store/, dir/ and keys/; default $UPSPINROOT or /mnt/upspin.

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;
include "daytime.m";
	daytime: Daytime;
include "upspin.m";
	up: Upspin;
	Store, Dir, KeyServer, DirEntry, Block: import up;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

stderr: ref Sys->FD;
base: string;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	kr = load Keyring Keyring->PATH;
	daytime = load Daytime Daytime->PATH;
	up = load Upspin Upspin->PATH;
	if(up == nil)
		fail(sys->sprint("load upspin: %r"));
	up->init();

	argv = tl argv;
	base = getenv("UPSPINROOT");
	if(base == "")
		base = "/mnt/upspin";
	if(argv != nil && hd argv == "-b"){
		argv = tl argv;
		if(argv == nil)
			usage();
		base = hd argv;
		argv = tl argv;
	}
	if(argv == nil)
		usage();
	cmd := hd argv;
	args := tl argv;
	case cmd {
	"keygen" =>	cmdkeygen(args);
	"keyadd" =>	cmdkeyadd(args);
	"put" =>	cmdput(args);
	"get" =>	cmdget(args);
	"ls" =>		cmdls(args);
	* =>		usage();
	}
}

storer(): ref Store	{ return up->store(base + "/store"); }
dirr():   ref Dir	{ return up->dir(base + "/dir"); }
keys():   ref KeyServer	{ return up->keyserver(base + "/keys"); }

cmdkeygen(args: list of string)
{
	if(args == nil || tl args == nil)
		usage();
	user := hd args;
	skfile := hd tl args;
	sk := kr->genSK("rsa", user, 1024);
	if(sk == nil)
		fail("genSK failed");
	e := writefile(skfile, array of byte kr->sktostr(sk));
	if(e != nil)
		fail(e);
	e = keys().register(user, kr->sktopk(sk));
	if(e != nil)
		fail(e);
	sys->print("generated key for %s: secret in %s, public registered in keyserver\n", user, skfile);
}

cmdkeyadd(args: list of string)
{
	if(args == nil || tl args == nil)
		usage();
	user := hd args;
	pk := kr->strtopk(string readfile(hd tl args));
	if(pk == nil)
		fail("cannot read public key " + hd tl args);
	e := keys().register(user, pk);
	if(e != nil)
		fail(e);
	sys->print("registered key for %s\n", user);
}

cmdput(args: list of string)
{
	if(args == nil || tl args == nil || tl tl args == nil)
		usage();
	name := hd args;
	file := hd tl args;
	skfile := hd tl tl args;
	if(up->owner(name) == name)
		fail("name has no path: " + name);
	sk := kr->strtosk(string readfile(skfile));
	if(sk == nil)
		fail("cannot read secret key " + skfile);
	data := readfile(file);
	if(data == nil && !exists(file))
		fail("cannot read " + file);
	if(data == nil)
		data = array[0] of byte;
	(blocks, berr) := up->putblocks(storer(), data);
	if(berr != nil)
		fail(berr);
	now := 0;
	if(daytime != nil)
		now = daytime->now();
	e := ref DirEntry(name, Upspin->PlainPack, big len data, now,
		up->owner(name), blocks, "");
	if((se := up->signentry(e, sk)) != nil)
		fail(se);
	if((de := dirr().put(e)) != nil)
		fail(de);
	nb := 0;
	for(l := blocks; l != nil; l = tl l)
		nb++;
	sys->print("put %s (%d bytes, %d block(s)), signed by %s\n", name, len data, nb, e.writer);
}

cmdget(args: list of string)
{
	if(args == nil)
		usage();
	name := hd args;
	(e, lerr) := dirr().lookup(name);
	if(lerr != nil)
		fail(lerr);
	if((ve := up->verifyentry(e, keys())) != nil)
		fail("verify: " + ve);
	(data, ge) := up->getblocks(storer(), e.blocks);
	if(ge != nil)
		fail(ge);
	out := sys->fildes(1);
	if(tl args != nil){
		out = sys->create(hd tl args, Sys->OWRITE, 8r644);
		if(out == nil)
			fail(sys->sprint("create %s: %r", hd tl args));
	}
	if(sys->write(out, data, len data) != len data)
		fail(sys->sprint("write: %r"));
	if(tl args != nil)
		sys->print("got %s (%d bytes) verified, wrote %s\n", name, len data, hd tl args);
}

cmdls(args: list of string)
{
	if(args == nil)
		usage();
	names := dirr().glob(hd args);
	for(; names != nil; names = tl names)
		sys->print("%s\n", hd names);
}

getenv(name: string): string
{
	data := readfile("/env/" + name);
	if(data == nil)
		return "";
	s := string data;
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == '\0'))
		s = s[0:len s - 1];
	return s;
}

exists(path: string): int
{
	(ok, nil) := sys->stat(path);
	return ok >= 0;
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

writefile(path: string, data: array of byte): string
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		return sys->sprint("create %s: %r", path);
	if(sys->write(fd, data, len data) != len data)
		return sys->sprint("write %s: %r", path);
	return nil;
}

usage()
{
	sys->fprint(stderr, "usage: upspin [-b base] keygen user skfile\n");
	sys->fprint(stderr, "       upspin [-b base] keyadd user pkfile\n");
	sys->fprint(stderr, "       upspin [-b base] put name file skfile\n");
	sys->fprint(stderr, "       upspin [-b base] get name [outfile]\n");
	sys->fprint(stderr, "       upspin [-b base] ls owner\n");
	raise "fail:usage";
}

fail(m: string)
{
	sys->fprint(stderr, "upspin: %s\n", m);
	raise "fail:" + m;
}

implement Radiostyx;

#
# Styx over the radio, and the message size nobody had watched.
#
# doc/pycubed-plan.ms argues that a satellite need not change to speak
# Styx over a radio-sized message, because os/inferno/port/exportfs.c
# adopts the transport's iounit when negotiating -- ":806", where an
# iounit above 64 and below the requested msize becomes the msize.  This
# runs it and prints the number.
#
# The ground half deliberately does not use mount(2).  devmnt.c:195
# refuses an msize below 256 and a radio payload is 251, which is the
# whole point of the argument: the floor is on the client and the client
# is a workstation.  appl/lib/styx.b has no floor, so this speaks Styx
# directly.
#
# Messages are read whole, with one read per packet, because the device
# is message-delimited and refuses a short read.  That is what Styx's
# own reader does not do -- see the BUGS in radiostyx(1).
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
include "security.m";
	ssl: SSL;
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;

Radiostyx: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Data:	con "/dev/radio0/data";
Payload:	con 251;

fd: ref Sys->FD;
tag: int;

rpc(t: ref Tmsg): ref Rmsg
{
	a := t.pack();
	if(sys->write(fd, a, len a) != len a){
		sys->print("radiostyx: write: %r\n");
		return nil;
	}
	b := array[Payload] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0){
		sys->print("radiostyx: read: %r\n");
		return nil;
	}
	(nil, r) := Rmsg.unpack(b[0:n]);
	if(r == nil){
		sys->print("radiostyx: unpack failed on %d bytes\n", n);
		return nil;
	}
	if(tagof r == tagof Rmsg.Error){
		e := r;
		pick x := e {
		Error =>
			sys->print("radiostyx: Rerror %s\n", x.ename);
		}
		return nil;
	}
	return r;
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	if(styx == nil){
		sys->print("radiostyx: load %s: %r\n", Styx->PATH);
		return;
	}
	styx->init();

	mode := "get";
	if(tl argv != nil)
		mode = hd tl argv;
	path := "dev/battery";
	if(tl argv != nil && tl tl argv != nil && hd tl tl argv != "ssl")
		path = hd tl tl argv;

	fd = sys->open(Data, Sys->ORDWR);
	if(fd == nil){
		sys->print("radiostyx: %s: %r\n", Data);
		return;
	}

	# With "ssl" as the last argument, put ssl(3) under the Styx.
	# That is the whole claim in doc/pycubed-plan.ms: Styx over an
	# encrypted, digested link over a radio, with no IP anywhere.
	# ssl(3) delimits its messages too, so exportfs reads them whole
	# exactly as it reads the radio whole.
	usessl := 0;
	for(l := argv; l != nil; l = tl l)
		if(hd l == "ssl")
			usessl = 1;
	if(usessl){
		ssl = load SSL SSL->PATH;
		if(ssl == nil){
			sys->print("radiostyx: load %s: %r\n", SSL->PATH);
			return;
		}
		(serr, c) := ssl->connect(fd);
		if(serr != nil){
			sys->print("radiostyx: ssl connect: %s\n", serr);
			return;
		}
		secret := array of byte "not-a-real-key-see-radiossl";
		serr = ssl->secret(c, secret, secret);
		if(serr != nil){
			sys->print("radiostyx: ssl secret: %s\n", serr);
			return;
		}
		if(sys->fprint(c.cfd, "alg sha") < 0){
			sys->print("radiostyx: alg sha: %r\n");
			return;
		}
		sys->print("RADIOSTYX-SSL %s\n", c.dir);
		fd = c.dfd;
	}

	if(mode == "serve"){
		sys->print("RADIOSTYX-SERVING\n");
		if(sys->export(fd, "/", Sys->EXPWAIT) < 0)
			sys->print("radiostyx: export: %r\n");
		sys->print("RADIOSTYX-SERVE-DONE\n");
		return;
	}

	# Ask for more than the radio can carry, so that the server's own
	# adoption of the transport iounit is what decides the answer.
	r := rpc(ref Tmsg.Version(Styx->NOTAG, 8192, "9P2000"));
	if(r == nil)
		return;
	msize := 0;
	pick x := r {
	Version =>
		msize = x.msize;
		sys->print("RADIOSTYX-MSIZE %d version %s\n", x.msize, x.version);
	* =>
		sys->print("radiostyx: wanted Rversion\n");
		return;
	}

	r = rpc(ref Tmsg.Attach(tag++, 0, Styx->NOFID, "inferno", ""));
	if(r == nil)
		return;

	names := sys->tokenize(path, "/").t1;
	nl: list of string;
	for(; names != nil; names = tl names)
		nl = hd names :: nl;
	wn := array[len nl] of string;
	for(i := len nl - 1; nl != nil; nl = tl nl)
		wn[i--] = hd nl;

	r = rpc(ref Tmsg.Walk(tag++, 0, 1, wn));
	if(r == nil)
		return;

	r = rpc(ref Tmsg.Open(tag++, 1, Sys->OREAD));
	if(r == nil)
		return;

	r = rpc(ref Tmsg.Read(tag++, 1, big 0, msize - 24));
	if(r == nil)
		return;
	pick x := r {
	Read =>
		sys->print("RADIOSTYX-READ %q\n", string x.data);
	* =>
		sys->print("radiostyx: wanted Rread\n");
	}
}

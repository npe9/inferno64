implement Styxbench;

#
# What a Styx round trip costs, against a bare TCP round trip on the
# same path.
#
# doc/inferno-cloud-modern.ms rests on a claim about cost: that putting
# distribution in the operating system is cheaper than assembling it
# above one.  A namespace mounted across a network is the form that
# claim takes, and its price is a Styx round trip where a direct call
# would be one TCP exchange.  If it costs several times as much, the
# abstraction is too expensive for the thing it replaces, and that is
# worth knowing and publishing.  Nobody has the number.
#
# Both halves are measured against the same server, over the same
# connection path, in the same run, so the comparison survives
# whatever the transport underneath is doing: what is reported is a
# ratio, not an absolute.
#
# The Styx half reads an already-open file, so each iteration is one
# Tread and its Rread -- no walk, no open, no clunk.  The raw half
# writes a request and reads the reply of the same size.  A read of
# /dev/zero on the far side costs the server nothing to satisfy, which
# is deliberate: this measures the protocol, not a disk.
#
include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "dial.m";
	dial: Dial;

Styxbench: module
{
	init: fn(nil: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	dial = load Dial Dial->PATH;
	if(dial == nil)
		fail(sys->sprint("cannot load %s: %r", Dial->PATH));

	n := 200;
	size := 64;
	rpcaddr: string;
	arg->init(argv);
	arg->setusage("styxbench [-n count] [-s size] [-r rpcaddr] rawaddr file");
	while((o := arg->opt()) != 0)
		case o {
		'n' =>	n = int arg->earg();
		's' =>	size = int arg->earg();
		'r' =>	rpcaddr = arg->earg();
		* =>	arg->usage();
		}
	argv = arg->argv();
	if(len argv != 2)
		arg->usage();
	rawaddr := hd argv;
	file := hd tl argv;

	buf := array[size] of byte;
	for(i := 0; i < size; i++)
		buf[i] = byte i;

	# raw: one write and one read per iteration
	c := dial->dial(rawaddr, nil);
	if(c == nil)
		fail(sys->sprint("dial %s: %r", rawaddr));
	reply := array[size] of byte;
	# one exchange first, so neither side's first-packet cost is counted
	sys->write(c.dfd, buf, size);
	readn(c.dfd, reply, size);
	t0 := sys->millisec();
	for(i = 0; i < n; i++){
		if(sys->write(c.dfd, buf, size) != size)
			fail(sys->sprint("raw write: %r"));
		if(readn(c.dfd, reply, size) != size)
			fail(sys->sprint("raw read: %r"));
	}
	rawms := sys->millisec() - t0;
	c = nil;

	fd := sys->open(file, Sys->OREAD);
	if(fd == nil)
		fail(sys->sprint("%s: %r", file));

	# sequential: what a caller naively sees, readahead and all
	sys->read(fd, reply, size);
	t0 = sys->millisec();
	for(i = 0; i < n; i++)
		if(sys->read(fd, reply, size) < 0)
			fail(sys->sprint("styx read: %r"));
	seqms := sys->millisec() - t0;

	#
	# Jumping: the same reads at offsets that stride far apart, so
	# that the mount driver's readahead cannot answer one from
	# another and each call is a Tread on the wire.
	#
	# The first version of this measured only the sequential loop and
	# reported that Styx cost 0.4 times a raw TCP exchange -- that is,
	# that the abstraction was cheaper than the thing it is built on,
	# which cannot be true and was the giveaway.  The gap between
	# these two numbers is the readahead, and it is worth reporting in
	# its own right: it is what the file abstraction buys back.
	#
	off := big 0;
	stride := big (1024*1024);
	sys->pread(fd, reply, size, off);
	t0 = sys->millisec();
	for(i = 0; i < n; i++){
		off += stride;
		if(sys->pread(fd, reply, size, off) < 0)
			fail(sys->sprint("styx pread: %r"));
	}
	jumpms := sys->millisec() - t0;

	#
	# A conventional RPC, against rpcserve(1): a length-prefixed
	# request that has to be formatted and parsed on both sides, and a
	# reply with a header that has to be parsed before the payload can
	# be found.  This is the arm doc/inferno-cloud-modern.ms item 8
	# names and the one that was missing -- raw TCP is the floor, with
	# no protocol at all, and it is not what anyone would deploy.
	#
	# On one connection, reused, exactly as the Styx and raw arms are.
	# Using httpclient(2) instead would have measured a new TCP
	# connection per request, because it sends "Connection: close",
	# and charged Styx nothing for the connection it already has.
	#
	rpcms := 0;
	if(rpcaddr != nil){
		rc := dial->dial(rpcaddr, nil);
		if(rc == nil)
			fail(sys->sprint("dial %s: %r", rpcaddr));
		rpcexch(rc.dfd, size);		# not counted, as above
		t0 = sys->millisec();
		for(i = 0; i < n; i++)
			rpcexch(rc.dfd, size);
		rpcms = sys->millisec() - t0;
		rc = nil;
	}

	sys->print("styxbench: %d iterations of %d bytes\n", n, size);
	sys->print("  raw tcp        %6d ms, %s us each\n", rawms, per(rawms, n));
	sys->print("  styx seq       %6d ms, %s us each\n", seqms, per(seqms, n));
	sys->print("  styx jumping   %6d ms, %s us each\n", jumpms, per(jumpms, n));
	if(rpcaddr != nil)
		sys->print("  rpc framed     %6d ms, %s us each\n", rpcms, per(rpcms, n));
	if(rawms > 0){
		sys->print("  seq     costs %s x raw\n", ratio(seqms, rawms));
		sys->print("  jumping costs %s x raw\n", ratio(jumpms, rawms));
		if(rpcaddr != nil)
			sys->print("  rpc     costs %s x raw\n", ratio(rpcms, rawms));
	}else
		sys->print("  raw too fast to time at this count; raise -n\n");
	if(rpcaddr != nil && rpcms > 0){
		sys->print("  jumping costs %s x rpc\n", ratio(jumpms, rpcms));
		sys->print("  seq     costs %s x rpc\n", ratio(seqms, rpcms));
	}
}

# One request and its reply: format, send, read the header, parse it,
# read the payload it announces.  The parsing is the point.
rpcexch(dfd: ref Sys->FD, size: int)
{
	req := array of byte sys->sprint("GET 0 %d\n", size);
	buf := array[4 + len req] of byte;
	p32(buf, len req);
	buf[4:] = req;
	if(sys->write(dfd, buf, len buf) != len buf)
		fail(sys->sprint("rpc write: %r"));

	hdr := array[4] of byte;
	if(readn(dfd, hdr, 4) != 4)
		fail("rpc: short reply length");
	n := g32(hdr);
	if(n <= 0 || n > 65536+64)
		fail(sys->sprint("rpc: bad reply length %d", n));
	rep := array[n] of byte;
	if(readn(dfd, rep, n) != n)
		fail("rpc: short reply");
	# Find the end of the header line and check the status, which is
	# what a client of such a protocol must do before it can use the
	# payload at all.
	for(i := 0; i < n; i++)
		if(rep[i] == byte '\n')
			break;
	if(i >= n)
		fail("rpc: reply has no header line");
	(nf, flds) := sys->tokenize(string rep[0:i], " ");
	if(nf < 2 || hd flds != "OK")
		fail("rpc: reply not OK: " + string rep[0:i]);
	if(int hd tl flds != n - (i+1))
		fail("rpc: reply length disagrees with its header");
}

g32(a: array of byte): int
{
	return (int a[0] << 24) | (int a[1] << 16) | (int a[2] << 8) | int a[3];
}

p32(a: array of byte, v: int)
{
	a[0] = byte (v >> 24);
	a[1] = byte (v >> 16);
	a[2] = byte (v >> 8);
	a[3] = byte v;
}

readn(fd: ref Sys->FD, a: array of byte, n: int): int
{
	got := 0;
	while(got < n){
		m := sys->read(fd, a[got:], n - got);
		if(m <= 0)
			return got;
		got += m;
	}
	return got;
}

# integer arithmetic only: no floating point is needed to say "2.7x"
per(ms: int, n: int): string
{
	if(n == 0)
		return "0";
	us := ms * 1000 / n;
	frac := (ms * 1000 * 10 / n) % 10;
	return sys->sprint("%d.%d", us, frac);
}

ratio(a: int, b: int): string
{
	if(b == 0)
		return "?";
	return sys->sprint("%d.%d", a / b, (a * 10 / b) % 10);
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "styxbench: %s\n", s);
	raise "fail:" + s;
}

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
	arg->init(argv);
	arg->setusage("styxbench [-n count] [-s size] rawaddr file");
	while((o := arg->opt()) != 0)
		case o {
		'n' =>	n = int arg->earg();
		's' =>	size = int arg->earg();
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

	sys->print("styxbench: %d iterations of %d bytes\n", n, size);
	sys->print("  raw tcp        %6d ms, %s us each\n", rawms, per(rawms, n));
	sys->print("  styx seq       %6d ms, %s us each\n", seqms, per(seqms, n));
	sys->print("  styx jumping   %6d ms, %s us each\n", jumpms, per(jumpms, n));
	if(rawms > 0){
		sys->print("  seq     costs %s x raw\n", ratio(seqms, rawms));
		sys->print("  jumping costs %s x raw\n", ratio(jumpms, rawms));
	}else
		sys->print("  raw too fast to time at this count; raise -n\n");
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

implement Rpcserve;

#
# rpcserve(1) -- a conventional RPC server, for comparison against Styx.
#
# doc/inferno-cloud-modern.ms item 8 asks for the Styx round trip
# against "a conventional RPC with its own framing and serialisation,
# which is the thing a real service would otherwise use".  styxbench(1)
# already has raw TCP, which is the floor -- a write and a read with no
# protocol at all -- and Styx.  This is the third point: a request that
# has to be framed, parsed and answered, the way an RPC is.
#
# Deliberately not HTTP.  httpclient(2) here sends "Connection: close",
# so every request would cost a new TCP connection while the Styx arm
# reads an already-open fid, and the comparison would flatter Styx by a
# whole connection setup.  This keeps one connection for the life of the
# measurement, exactly as the Styx and raw arms do, so what is left
# between them is protocol cost and nothing else.
#
# The protocol is small and representative rather than clever:
#
#	request:  4-byte big-endian length, then "GET <offset> <count>\n"
#	reply:    4-byte big-endian length, then "OK <n>\n" then n bytes
#
# A length prefix and a text header is what most hand-rolled RPCs and
# every JSON-over-TCP service amount to; the cost being measured is
# having to produce and parse them.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";

Rpcserve: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

stderr: ref Sys->FD;
verbose := 0;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	arg := load Arg Arg->PATH;
	if(arg == nil)
		fail(sys->sprint("cannot load %s: %r", Arg->PATH));

	arg->init(argv);
	arg->setusage("rpcserve [-v] [address]");
	while((c := arg->opt()) != 0)
		case c {
		'v' =>	verbose++;
		* =>	arg->usage();
		}
	argv = arg->argv();
	addr := "tcp!*!6667";
	if(argv != nil)
		addr = hd argv;
	arg = nil;

	(ok, conn) := sys->announce(addr);
	if(ok < 0)
		fail(sys->sprint("announce %s: %r", addr));
	if(verbose)
		sys->fprint(stderr, "rpcserve: listening on %s\n", addr);
	sys->print("rpcserve: listening\n");

	# One connection at a time, served to completion.  The measurement
	# it exists for uses one.
	for(;;){
		(lok, lconn) := sys->listen(conn);
		if(lok < 0)
			fail(sys->sprint("listen: %r"));
		dfd := sys->open(lconn.dir + "/data", Sys->ORDWR);
		if(dfd == nil){
			sys->fprint(stderr, "rpcserve: open data: %r\n");
			continue;
		}
		serve(dfd);
		dfd = nil;
	}
}

serve(dfd: ref Sys->FD)
{
	hdr := array[4] of byte;
	for(;;){
		if(readn(dfd, hdr, 4) != 4)
			return;			# peer went away; that is the end
		n := g32(hdr);
		if(n <= 0 || n > 65536)
			return;
		req := array[n] of byte;
		if(readn(dfd, req, n) != n)
			return;
		(count, err) := parse(string req);
		if(err != nil){
			reply(dfd, array of byte ("ERR " + err + "\n"), nil);
			continue;
		}
		# The payload is generated, not read from anywhere: this
		# measures the protocol, and going to a disk on one side only
		# would measure the disk.
		body := array[count] of byte;
		for(i := 0; i < count; i++)
			body[i] = byte i;
		reply(dfd, array of byte sys->sprint("OK %d\n", count), body);
	}
}

# "GET <offset> <count>" -- offset is accepted and ignored, because the
# body is generated; it is in the protocol so that a request has more
# than one field to parse, which is the point.
parse(s: string): (int, string)
{
	(nf, flds) := sys->tokenize(s, " \t\n");
	if(nf < 3)
		return (0, "short request");
	if(hd flds != "GET")
		return (0, "unknown method " + hd flds);
	flds = tl tl flds;
	count := int hd flds;
	if(count < 0 || count > 65536)
		return (0, "bad count");
	return (count, nil);
}

reply(dfd: ref Sys->FD, head: array of byte, body: array of byte)
{
	n := len head + len body;
	buf := array[4 + n] of byte;
	p32(buf, n);
	buf[4:] = head;
	if(body != nil)
		buf[4 + len head:] = body;
	sys->write(dfd, buf, len buf);
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
			break;
		got += m;
	}
	return got;
}

fail(s: string)
{
	sys->fprint(stderr, "rpcserve: %s\n", s);
	raise "fail:" + s;
}

implement Lorachk;

#
# Check #L, the link layer taken out of the packet device.
#
# What is being checked is that the four things removed from
# os/inferno/radio/sx127x.c -- the RadioHead header, the address filter,
# acknowledgement and retry -- work in their new home and are visible
# from outside it.  Three of the checks need a second station and one of
# them needs that station to be talking to somebody else, which is why
# "elsewhere" exists: a packet not addressed here must be counted rather
# than delivered, and without a counter a working filter and a dead link
# look the same.
#
# The republished iounit is checked here too.  #L spends four bytes of
# whatever is underneath and must say so, or a Styx server above it
# negotiates a size the link cannot carry and the error appears at the
# far end of a radio.
#
#	lorachk setup addr	attach /dev/radio0/data, set this address
#	lorachk send to text	one packet, unacknowledged
#	lorachk ack to text	one packet, acknowledged and retried
#	lorachk elsewhere to	a packet for somebody else
#	lorachk recv		take one, announced
#	lorachk ackrecv		take one, announced, acknowledging
#	lorachk stats		what the interface counted
#

include "sys.m";
	sys: Sys;
include "draw.m";

Lorachk: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Radio:	con "/dev/radio0/data";
Lctl:	con "#L/ctl";
Lstats:	con "#L/stats";
Clone:	con "#L/clone";

nrun, nfail: int;

ck(what: string, ok: int, detail: string)
{
	nrun++;
	if(ok)
		sys->print("%s ok\n", what);
	else{
		nfail++;
		sys->print("%s FAIL %s\n", what, detail);
	}
}

# Open a conversation.  Reading clone gives the number; the fd that
# comes back is the conversation's ctl and closing it closes the
# conversation, so it is kept for as long as the data fd is used.
Conv: adt {
	n:	int;
	cfd:	ref Sys->FD;
	dfd:	ref Sys->FD;
};

clone(): ref Conv
{
	cfd := sys->open(Clone, Sys->ORDWR);
	if(cfd == nil){
		sys->print("lorachk: %s: %r\n", Clone);
		return nil;
	}
	b := array[32] of byte;
	n := sys->read(cfd, b, len b);
	if(n <= 0){
		sys->print("lorachk: read clone: %r\n");
		return nil;
	}
	num := int string b[0:n];
	dfd := sys->open(sys->sprint("#L/%d/data", num), Sys->ORDWR);
	if(dfd == nil){
		sys->print("lorachk: #L/%d/data: %r\n", num);
		return nil;
	}
	return ref Conv(num, cfd, dfd);
}

setup(addr: int)
{
	rfd := sys->open(Radio, Sys->ORDWR);
	if(rfd == nil){
		sys->print("lorachk: %s: %r\n", Radio);
		return;
	}
	lfd := sys->open(Lctl, Sys->ORDWR);
	if(lfd == nil){
		sys->print("lorachk: %s: %r\n", Lctl);
		return;
	}
	ck("addr-accepted", sys->fprint(lfd, "addr %d", addr) > 0,
		sys->sprint("%r"));
	ck("attach-accepted", sys->fprint(lfd, "fd %d", rfd.fd) > 0,
		sys->sprint("%r"));

	# The radio carries 255 and this layer spends four of them, so a
	# conversation must publish 251.  A layer that republished the
	# number underneath unchanged would be lying by four bytes, and
	# nothing below it would ever notice.
	c := clone();
	if(c == nil)
		return;
	iou := sys->iounit(c.dfd);
	ck("iounit-republished", iou == 251, sys->sprint("iounit %d", iou));

	# Nothing to send to yet, and that is an error rather than a
	# silent broadcast.
	b := array[4] of byte;
	ck("unconnected-write-refused", sys->write(c.dfd, b, len b) < 0,
		"the write was accepted");

	if(sys->fprint(c.cfd, "connect 9") < 0){
		ck("connect-accepted", 0, sys->sprint("%r"));
		return;
	}
	ck("connect-accepted", 1, "");

	over := array[252] of byte;
	n := sys->write(c.dfd, over, len over);
	e := sys->sprint("%r");
	ck("oversize-write-refused", n < 0, sys->sprint("wrote %d", n));
	ck("oversize-write-names-budget", strstr(e, "251") >= 0,
		sys->sprint("error was %q", e));
}

send(dest: int, text: string, acked, count, padto: int)
{
	c := clone();
	if(c == nil)
		return;
	if(sys->fprint(c.cfd, "connect %d", dest) < 0){
		sys->print("lorachk: connect %d: %r\n", dest);
		return;
	}
	if(acked){
		if(sys->fprint(c.cfd, "ack on") < 0){
			sys->print("lorachk: ack on: %r\n");
			return;
		}
		if(sys->fprint(c.cfd, "timeout 4000") < 0){
			sys->print("lorachk: timeout: %r\n");
			return;
		}
	}
	t0 := sys->millisec();
	for(i := 0; i < count; i++){
		# padto makes the packet long, which is how the duty
		# cycle is made to bite: the acknowledgement is one byte
		# whatever this is, so the two ends owe very different
		# amounts of silence.
		b := array of byte sys->sprint("%s-%d", text, i);
		if(padto > len b){
			pad := array[padto] of byte;
			pad[0:] = b;
			for(j := len b; j < padto; j++)
				pad[j] = byte 'z';
			b = pad;
		}
		n := sys->write(c.dfd, b, len b);
		if(acked)
			ck(sys->sprint("acked-write-%d", i), n == len b,
				sys->sprint("%d %r", n));
		else
			ck(sys->sprint("write-%d", i), n == len b,
				sys->sprint("%d %r", n));
	}
	sys->print("elapsed %d ms for %d writes\n",
		sys->millisec() - t0, count);
	sys->print("%s\n", status(c.n));
}

recv(acked, count: int)
{
	c := clone();
	if(c == nil)
		return;
	if(sys->fprint(c.cfd, "announce") < 0){
		sys->print("lorachk: announce: %r\n");
		return;
	}
	if(acked && sys->fprint(c.cfd, "ack on") < 0){
		sys->print("lorachk: ack on: %r\n");
		return;
	}

	# The same refusal the packet device makes: a buffer smaller than
	# the packet is an error and the packet stays.
	one := array[1] of byte;
	n := sys->read(c.dfd, one, len one);
	ck("short-read-refused", n < 0, sys->sprint("read %d", n));

	b := array[251] of byte;
	for(i := 0; i < count; i++){
		n = sys->read(c.dfd, b, len b);
		ck(sys->sprint("read-%d", i), n > 0, sys->sprint("%d %r", n));
		if(n > 0)
			sys->print("payload %q\n", string b[0:n]);
	}
	sys->print("%s\n", status(c.n));
}

status(n: int): string
{
	fd := sys->open(sys->sprint("#L/%d/status", n), Sys->OREAD);
	if(fd == nil)
		return sys->sprint("status: %r");
	b := array[512] of byte;
	m := sys->read(fd, b, len b);
	if(m <= 0)
		return sys->sprint("status: %r");
	return string b[0:m];
}

stats(): string
{
	fd := sys->open(Lstats, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("stats: %r");
	b := array[512] of byte;
	m := sys->read(fd, b, len b);
	if(m <= 0)
		return sys->sprint("stats: %r");
	return string b[0:m];
}

pad(l: list of string): int
{
	if(l == nil || tl l == nil)
		return 0;
	return int hd tl l;
}

count(l: list of string): int
{
	if(l == nil)
		return 1;
	return int hd l;
}

strstr(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return i;
	return -1;
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;

	argv = tl argv;
	if(argv == nil){
		sys->print("usage: lorachk setup|send|ack|elsewhere|recv|ackrecv|stats\n");
		return;
	}
	mode := hd argv;
	argv = tl argv;

	case mode {
	"setup" =>
		addr := 1;
		if(argv != nil)
			addr = int hd argv;
		setup(addr);
	"send" =>
		if(argv == nil || tl argv == nil)
			return;
		send(int hd argv, hd tl argv, 0, count(tl tl argv),
			pad(tl tl argv));
	"ack" =>
		if(argv == nil || tl argv == nil)
			return;
		send(int hd argv, hd tl argv, 1, count(tl tl argv),
			pad(tl tl argv));
	"elsewhere" =>
		if(argv == nil)
			return;
		send(int hd argv, "not-for-you", 0, 1, 0);
	"recv" =>
		recv(0, count(argv));
	"ackrecv" =>
		recv(1, count(argv));
	"rand" =>
		# Four bytes of /dev/random, printed.  Two boards running
		# one image should not agree, and whether they do decides
		# whether a randomised backoff can separate them at all.
		fd := sys->open("#c/random", Sys->OREAD);
		if(fd == nil){
			sys->print("lorachk: #c/random: %r\n");
			return;
		}
		rb := array[8] of byte;
		rn := sys->read(fd, rb, len rb);
		if(rn <= 0){
			sys->print("lorachk: read: %r\n");
			return;
		}
		sys->print("RAND");
		for(ri := 0; ri < rn; ri++)
			sys->print(" %.2x", int rb[ri]);
		sys->print("\n");
		return;
	"stats" =>
		sys->print("%s", stats());
		return;
	* =>
		sys->print("lorachk: %s?\n", mode);
		return;
	}

	sys->print("%d checks, %d failed\n", nrun, nfail);
	if(nfail == 0 && nrun > 0)
		sys->print("LORACHK-OK\n");
}

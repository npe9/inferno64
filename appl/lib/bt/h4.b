implement Bttransport;

#
# The H4 HCI transport: packets on a byte stream, each one preceded
# by a single byte saying what it is.  This is what a UART attached
# controller speaks -- the Raspberry Pi 3B's onboard Broadcom radio,
# and any H4 module -- and it is what the bench uses: the second
# serial port of a pc64 kernel, with a controller model on the other
# end of it.  See btfs(4).
#
# A byte stream has no packet boundaries, so nothing here may assume
# that one read() is one packet, or that a packet arrives whole: the
# packet's own header says how long it is, and this asks for exactly
# that many bytes and no more.  That is the only thing that keeps it
# in step with the wire.
#
# read() is called from one process only (the HCI reader), so the
# buffer needs no lock.  write() may be called from several, and is
# one write() call per packet: a uart write is atomic in the kernel's
# output queue, so a packet is not interleaved with another.
#
# The byte stream is usually a uart, and on real hardware it always
# is.  It may also be a network connection, which is how the bench
# reaches the controller model on the build host from a board whose
# only serial port is the console: the spec is then a dial(2) string
# such as "tcp!10.0.2.2!5555".  Nothing in the framing changes -- H4
# is H4 over whatever carries the bytes -- and that is said plainly
# in btfs(4) so a network bench is never mistaken for a radio.
#
# On 9front this file is one C file over the same /dev/eia*: the
# buffer, the header lengths and the framing are the same.
#

include "sys.m";
	sys: Sys;
include "dial.m";
	dial: Dial;
include "bt.m";
	bt: Bt;

Maxpkt:	con 4 + 65535;	# the longest thing H4 frames: an ACL packet

fd:	ref Sys->FD;
pkt:	array of byte;	# the packet being read
pktn:	int;		# how much of it is here
tmp:	array of byte;	# what one read() lands in
opened:	int;

init(b: Bt, spec: string): string
{
	sys = load Sys Sys->PATH;
	bt = b;

	(n, f) := sys->tokenize(spec, "!");
	if(n < 1)
		return "no controller named";

	# a dial string reaches a controller across the network; that is
	# the bench's way in on a board whose only uart is the console
	if(hd f == "tcp" || hd f == "net" || hd f == "il"){
		dial = load Dial Dial->PATH;
		if(dial == nil)
			return sys->sprint("cannot load %s: %r", Dial->PATH);
		c := dial->dial(spec, nil);
		if(c == nil)
			return sys->sprint("dial %s: %r", spec);
		fd = c.dfd;
		buffers();
		return nil;
	}

	path := hd f;
	speed := "";
	flow := "";
	if(n >= 2)
		speed = hd tl f;
	if(n >= 3)
		flow = hd tl tl f;
	if(path == nil)
		return "no controller named";

	# the line settings go through the uart's own ctl file, which
	# is the data file's name with "ctl" after it -- devuart(3)
	if(speed != nil || flow != nil){
		cfd := sys->open(path + "ctl", Sys->OWRITE);
		if(cfd == nil)
			return sys->sprint("open %sctl: %r", path);
		if(speed != nil && sys->fprint(cfd, "b%s", speed) < 0)
			return sys->sprint("set speed %s: %r", speed);
		if(sys->fprint(cfd, "l8") < 0)
			return sys->sprint("set 8 bits: %r");
		if(sys->fprint(cfd, "pn") < 0)
			return sys->sprint("set no parity: %r");
		if(sys->fprint(cfd, "s1") < 0)
			return sys->sprint("set one stop bit: %r");
		# a real H4 controller wants RTS/CTS: the Pi's radio
		# drops bytes without it.  The bench does not have the
		# lines, so it is asked for only when the spec asks.
		if(flow == "fc" && sys->fprint(cfd, "m1") < 0)
			return sys->sprint("set flow control: %r");
	}

	fd = sys->open(path, Sys->ORDWR);
	if(fd == nil)
		return sys->sprint("open %s: %r", path);
	buffers();
	return nil;
}

buffers()
{
	pkt = array[Maxpkt] of byte;
	tmp = array[Maxpkt] of byte;
	pktn = 0;
	opened = 1;
}

#
# read until pkt holds n bytes.  A stream hands over whatever it has,
# so this asks for exactly what is still missing and never for more:
# nothing is read ahead, so there is no buffer to compact and no
# slice of one to pass to the kernel.  Reading past the end of a
# packet would be the same mistake as reading half of one.
#
fill(n: int): string
{
	while(pktn < n){
		if(fd == nil)
			return "transport closed";
		r := sys->read(fd, tmp, n - pktn);
		if(r < 0)
			return sys->sprint("read: %r");
		if(r == 0)
			return "transport hung up";
		for(i := 0; i < r; i++)
			pkt[pktn++] = tmp[i];
	}
	return nil;
}

read(): (int, array of byte, string)
{
	pktn = 0;
	if((e := fill(1)) != nil)
		return (0, nil, e);
	ptype := int pkt[0];
	hdr := 0;
	case ptype {
	Bt->Hcievt =>	hdr = 2;	# code, parameter length
	Bt->Hciacl =>	hdr = 4;	# handle and flags, length
	Bt->Hcisco =>	hdr = 3;	# handle and flags, length
	* =>
		# nothing can resynchronise a byte stream that has lost
		# its place, so say so rather than quietly hunting for
		# a byte that looks right
		return (0, nil, sys->sprint("bad H4 packet indicator %#2.2ux", ptype));
	}

	# the indicator is not part of the packet; start again after it
	pktn = 0;
	if((e = fill(hdr)) != nil)
		return (0, nil, e);
	plen := 0;
	case ptype {
	Bt->Hcievt =>	plen = int pkt[1];
	Bt->Hciacl =>	plen = int pkt[2] | (int pkt[3] << 8);
	Bt->Hcisco =>	plen = int pkt[2];
	}
	if((e = fill(hdr + plen)) != nil)
		return (0, nil, e);
	a := array[hdr + plen] of byte;
	for(i := 0; i < hdr + plen; i++)
		a[i] = pkt[i];
	return (ptype, a, nil);
}

write(ptype: int, p: array of byte): string
{
	if(fd == nil)
		return "transport closed";
	a := array[1 + len p] of byte;
	a[0] = byte ptype;
	for(i := 0; i < len p; i++)
		a[1+i] = p[i];
	if(sys->write(fd, a, len a) != len a)
		return sys->sprint("write: %r");
	return nil;
}

close()
{
	fd = nil;
	pkt = nil;
	tmp = nil;
	pktn = 0;
	opened = 0;
}

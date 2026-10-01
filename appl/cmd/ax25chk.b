implement Ax25chk;

#
# Check #a, AX.25 over a packet device.
#
# The parts a shell cannot reach are the sizes and the refusals.  An
# AX.25 frame here is the address field, a control byte and a PID, with
# no HDLC flags, bit stuffing or FCS, because the LoRa PHY already
# delimits the packet and checks it.  So the information field is 239
# bytes with no digipeater path and 225 with two, and those two numbers
# have to come out of sys->iounit rather than out of this file: a layer
# that does not republish what it spends is the mistake
# doc/radio-interface.ms records against appl/lib/ssl.b.
#
#	ax25chk setup CALL-n	attach, set the callsign, check the sizes
#	ax25chk send CALL text [count]		connectionless
#	ax25chk sendvia CALL d1,d2 text		connectionless
#	ax25chk beacon text	a UI frame to QST, which is what a beacon is
#	ax25chk recv [count]	connectionless
#	ax25chk call CALL text [count]		connected: SABM, I, DISC
#	ax25chk listen [count]	connected: announce, listen, read
#	ax25chk stats
#

include "sys.m";
	sys: Sys;
include "draw.m";

Ax25chk: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Radio:	con "/dev/radio0/data";
Actl:	con "#a/ctl";
Astats:	con "#a/stats";
Clone:	con "#a/clone";

#
# THESE WERE CONSTANTS AND THEY WERE AN SX1276'S.
#
# 239 is 255 less 14 of address field and 2 of control and PID, and 225
# is 14 more off for two digipeaters -- and 255 is one particular
# carrier's payload.  doc/ax25-plan.ms says the sizes come out of
# sys->iounit rather than out of a constant in a test, and this file is
# where that claim was not true: on a CC1120 the carrier is 125, so the
# answers are 109 and 95, and both checks here would have failed against
# a device that was right.
#
# Measured on an stm32f407 with a ccRF click, by ax25up(1), which exists
# because this program will not run on that board:
#
#	ax25up: /dev/radio0/data iounit 125
#	ax25up: #a/0/data iounit 109
#	ax25up: #a/0/data iounit 95		(via WIDE1-1,WIDE2-1)
#
# So the budget is computed from the carrier the test itself attached.
# The arithmetic stays here, because that is what is being checked; what
# goes is the assumption about what it is applied to.
#
Hdrlen:	con 16;		# 14 of address field, 2 of control and PID
Digilen:	con 7;	# one more address for each digipeater
Maxbuf:	con 255;	# the largest carrier this can be pointed at

nodigi, twodigi: int;	# set from the carrier in setup()

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

Conv: adt {
	n:	int;
	cfd:	ref Sys->FD;
	dfd:	ref Sys->FD;
};

clone(): ref Conv
{
	cfd := sys->open(Clone, Sys->ORDWR);
	if(cfd == nil){
		sys->print("ax25chk: %s: %r\n", Clone);
		return nil;
	}
	b := array[32] of byte;
	n := sys->read(cfd, b, len b);
	if(n <= 0){
		sys->print("ax25chk: read clone: %r\n");
		return nil;
	}
	return ref Conv(int string b[0:n], cfd, nil);
}

opendata(c: ref Conv): int
{
	c.dfd = sys->open(sys->sprint("#a/%d/data", c.n), Sys->ORDWR);
	if(c.dfd == nil){
		sys->print("ax25chk: #a/%d/data: %r\n", c.n);
		return -1;
	}
	return 0;
}

setup(call: string)
{
	rfd := sys->open(Radio, Sys->ORDWR);
	if(rfd == nil){
		sys->print("ax25chk: %s: %r\n", Radio);
		return;
	}
	lfd := sys->open(Actl, Sys->ORDWR);
	if(lfd == nil){
		sys->print("ax25chk: %s: %r\n", Actl);
		return;
	}
	# The carrier's own budget, before anything is asserted about
	# what #a republishes from it.
	nodigi = sys->iounit(rfd) - Hdrlen;
	twodigi = nodigi - 2*Digilen;
	sys->print("carrier iounit %d, so %d with no path and %d with two " +
		"digipeaters\n", sys->iounit(rfd), nodigi, twodigi);

	ck("addr-accepted", sys->fprint(lfd, "addr %s", call) > 0,
		sys->sprint("%r"));
	ck("attach-accepted", sys->fprint(lfd, "fd %d", rfd.fd) > 0,
		sys->sprint("%r"));

	# A callsign is six characters and a digit; neither a seventh
	# character nor an SSID of 16 is one.
	ck("long-callsign-refused", sys->fprint(lfd, "addr TOOLONGX") < 0,
		"it was accepted");
	ck("big-ssid-refused", sys->fprint(lfd, "addr N0CALL-16") < 0,
		"it was accepted");
	sys->fprint(lfd, "addr %s", call);

	c := clone();
	if(c == nil)
		return;
	if(sys->fprint(c.cfd, "ui on") < 0 ||
	   sys->fprint(c.cfd, "connect N0CALL-1") < 0){
		ck("connect-accepted", 0, sys->sprint("%r"));
		return;
	}
	ck("connect-accepted", 1, "");
	if(opendata(c) < 0)
		return;
	iou := sys->iounit(c.dfd);
	ck("iounit-no-digi", iou == nodigi,
		sys->sprint("iounit %d, carrier says %d", iou, nodigi));

	over := array[Maxbuf+1] of byte;
	over = over[0:nodigi+1];
	n := sys->write(c.dfd, over, len over);
	e := sys->sprint("%r");
	ck("oversize-write-refused", n < 0, sys->sprint("wrote %d", n));
	ck("oversize-names-budget", strstr(e, string nodigi) >= 0,
		sys->sprint("error was %q", e));

	# The path changes the frame size, so it may not change under an
	# open data file: the iounit is a promise, not an estimate.
	ck("late-via-refused",
		sys->fprint(c.cfd, "via WIDE1-1,WIDE2-1") < 0,
		"it was accepted while data was open");

	d := clone();
	if(d == nil)
		return;
	if(sys->fprint(d.cfd, "ui on") < 0 ||
	   sys->fprint(d.cfd, "connect N0CALL-1 via WIDE1-1,WIDE2-1") < 0){
		ck("connect-via-accepted", 0, sys->sprint("%r"));
		return;
	}
	ck("connect-via-accepted", 1, "");
	if(opendata(d) < 0)
		return;
	iou = sys->iounit(d.dfd);
	ck("iounit-two-digis", iou == twodigi,
		sys->sprint("iounit %d, carrier says %d", iou, twodigi));

	ck("three-digis-refused",
		sys->fprint(d.cfd, "via A-1,B-1,C-1") < 0,
		"it was accepted");
}

send(dest, via, text: string, count: int)
{
	c := clone();
	if(c == nil)
		return;
	if(sys->fprint(c.cfd, "ui on") < 0){
		sys->print("ax25chk: ui on: %r\n");
		return;
	}
	cmd := sys->sprint("connect %s", dest);
	if(via != "")
		cmd += sys->sprint(" via %s", via);
	if(sys->fprint(c.cfd, "%s", cmd) < 0){
		sys->print("ax25chk: %s: %r\n", cmd);
		return;
	}
	if(opendata(c) < 0)
		return;
	for(i := 0; i < count; i++){
		b := array of byte sys->sprint("%s-%d", text, i);
		n := sys->write(c.dfd, b, len b);
		ck(sys->sprint("write-%d", i), n == len b,
			sys->sprint("%d %r", n));
	}
	sys->print("%s\n", status(c.n));
}

recv(count: int)
{
	c := clone();
	if(c == nil)
		return;
	if(sys->fprint(c.cfd, "ui on") < 0){
		sys->print("ax25chk: ui on: %r\n");
		return;
	}
	if(sys->fprint(c.cfd, "announce") < 0){
		sys->print("ax25chk: announce: %r\n");
		return;
	}
	if(opendata(c) < 0)
		return;

	one := array[1] of byte;
	n := sys->read(c.dfd, one, len one);
	ck("short-read-refused", n < 0, sys->sprint("read %d", n));

	b := array[Maxbuf] of byte;
	b = b[0:nodigi];
	for(i := 0; i < count; i++){
		n = sys->read(c.dfd, b, len b);
		ck(sys->sprint("read-%d", i), n > 0, sys->sprint("%d %r", n));
		if(n > 0)
			sys->print("info %q\n", string b[0:n]);
	}
	sys->print("%s\n", status(c.n));
}

# A connected conversation: SABM, some I frames, then DISC.  The
# connect write does not return until the peer has answered, so a
# failure here is a failure to connect and not a failure to write.
call(dest, text: string, count, t2: int)
{
	c := clone();
	if(c == nil)
		return;
	if(t2 >= 0 && sys->fprint(c.cfd, "t2 %d", t2) < 0){
		ck("t2", 0, sys->sprint("%r"));
		return;
	}
	t0 := sys->millisec();
	if(sys->fprint(c.cfd, "connect %s", dest) < 0){
		ck("connect", 0, sys->sprint("%r"));
		return;
	}
	ck("connect", 1, "");
	sys->print("connected in %d ms\n", sys->millisec() - t0);
	if(opendata(c) < 0)
		return;
	for(i := 0; i < count; i++){
		b := array of byte sys->sprint("%s-%d", text, i);
		n := sys->write(c.dfd, b, len b);
		ck(sys->sprint("write-%d", i), n == len b,
			sys->sprint("%d %r", n));
	}
	# Let the acknowledgements come back before looking: an
	# acknowledgement that has not arrived yet is not a missing one.
	sys->sleep(3000);
	sys->print("%s\n", status(c.n));
	sys->print("%s", slurp(Astats));
	ck("disconnect", sys->fprint(c.cfd, "disconnect") > 0,
		sys->sprint("%r"));
	sys->print("%s\n", status(c.n));
}

# The server half: announce, then open listen, which blocks until
# somebody sends a SABM and comes back holding that connection.
listen(count, delay: int)
{
	c := clone();
	if(c == nil)
		return;
	if(sys->fprint(c.cfd, "announce") < 0){
		ck("announce", 0, sys->sprint("%r"));
		return;
	}
	ck("announce", 1, "");
	# Announce, then wait before taking anything.  Connections that
	# arrive meanwhile are accepted and queued, so a second caller
	# is still on the queue when this program takes the first and
	# exits -- which is the case that leaked.
	if(delay > 0)
		sys->sleep(delay);
	lfd := sys->open(sys->sprint("#a/%d/listen", c.n), Sys->ORDWR);
	if(lfd == nil){
		ck("listen", 0, sys->sprint("%r"));
		return;
	}
	b := array[32] of byte;
	n := sys->read(lfd, b, len b);
	if(n <= 0){
		ck("listen", 0, sys->sprint("%r"));
		return;
	}
	num := int string b[0:n];
	ck("listen", num != c.n, sys->sprint("same conversation %d", num));
	sys->print("accepted on #a/%d\n", num);
	d := ref Conv(num, lfd, nil);
	if(opendata(d) < 0)
		return;
	buf := array[Maxbuf] of byte;
	buf = buf[0:nodigi];
	for(i := 0; i < count; i++){
		n = sys->read(d.dfd, buf, len buf);
		ck(sys->sprint("read-%d", i), n > 0, sys->sprint("%d %r", n));
		if(n > 0)
			sys->print("info %q\n", string buf[0:n]);
	}
	sys->print("%s\n", status(num));
	# Stay up long enough for the other end to disconnect first.
	# Exiting here closes the conversation, which sends DISC, and
	# the caller would be reported as dropped when it was hung up
	# on -- which is correct behaviour and a useless measurement.
	sys->sleep(12000);
	sys->print("%s\n", status(num));
}

status(n: int): string
{
	return slurp(sys->sprint("#a/%d/status", n));
}

slurp(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("%s: %r", f);
	b := array[512] of byte;
	m := sys->read(fd, b, len b);
	if(m <= 0)
		return sys->sprint("%s: %r", f);
	return string b[0:m];
}

strstr(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return i;
	return -1;
}

second(l: list of string): int
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

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;

	argv = tl argv;
	if(argv == nil){
		sys->print("usage: ax25chk setup|send|sendvia|beacon|recv|call|listen|convs|stats\n");
		return;
	}
	mode := hd argv;
	argv = tl argv;

	case mode {
	"setup" =>
		mycall := "N0CALL";
		if(argv != nil)
			mycall = hd argv;
		setup(mycall);
	"send" =>
		if(argv == nil || tl argv == nil)
			return;
		send(hd argv, "", hd tl argv, count(tl tl argv));
	"beacon" =>
		t := "beacon";
		if(argv != nil)
			t = hd argv;
		send("QST", "", t, 1);
	"sendvia" =>
		if(argv == nil || tl argv == nil || tl tl argv == nil)
			return;
		send(hd argv, hd tl argv, hd tl tl argv, 1);
	"call" =>
		if(argv == nil || tl argv == nil)
			return;
		call(hd argv, hd tl argv, count(tl tl argv),
			second(tl tl argv) - 1);
	"listen" =>
		listen(count(argv), second(argv));
	"recv" =>
		recv(count(argv));
	"convs" =>
		# Every conversation's state, which is how a leak shows:
		# one that reads open with nobody attached to it.
		for(i := 0; i < 4; i++)
			sys->print("%s", slurp(sys->sprint("#a/%d/status", i)));
		return;
	"stats" =>
		sys->print("%s", slurp(Astats));
		return;
	* =>
		sys->print("ax25chk: %s?\n", mode);
		return;
	}

	sys->print("%d checks, %d failed\n", nrun, nfail);
	if(nfail == 0 && nrun > 0)
		sys->print("AX25CHK-OK\n");
}

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
#	ax25chk send CALL text [count]
#	ax25chk sendvia CALL d1,d2 text
#	ax25chk beacon text	a UI frame to QST, which is what a beacon is
#	ax25chk recv [count]
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

Nodigi:	con 239;		# 255 less 14 of address and 2 of control
Twodigi:	con 225;	# and 14 more for two digipeaters

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
	if(sys->fprint(c.cfd, "connect N0CALL-1") < 0){
		ck("connect-accepted", 0, sys->sprint("%r"));
		return;
	}
	ck("connect-accepted", 1, "");
	if(opendata(c) < 0)
		return;
	iou := sys->iounit(c.dfd);
	ck("iounit-no-digi", iou == Nodigi, sys->sprint("iounit %d", iou));

	over := array[Nodigi+1] of byte;
	n := sys->write(c.dfd, over, len over);
	e := sys->sprint("%r");
	ck("oversize-write-refused", n < 0, sys->sprint("wrote %d", n));
	ck("oversize-names-budget", strstr(e, string Nodigi) >= 0,
		sys->sprint("error was %q", e));

	# The path changes the frame size, so it may not change under an
	# open data file: the iounit is a promise, not an estimate.
	ck("late-via-refused",
		sys->fprint(c.cfd, "via WIDE1-1,WIDE2-1") < 0,
		"it was accepted while data was open");

	d := clone();
	if(d == nil)
		return;
	if(sys->fprint(d.cfd, "connect N0CALL-1 via WIDE1-1,WIDE2-1") < 0){
		ck("connect-via-accepted", 0, sys->sprint("%r"));
		return;
	}
	ck("connect-via-accepted", 1, "");
	if(opendata(d) < 0)
		return;
	iou = sys->iounit(d.dfd);
	ck("iounit-two-digis", iou == Twodigi, sys->sprint("iounit %d", iou));

	ck("three-digis-refused",
		sys->fprint(d.cfd, "via A-1,B-1,C-1") < 0,
		"it was accepted");
}

send(dest, via, text: string, count: int)
{
	c := clone();
	if(c == nil)
		return;
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
	if(sys->fprint(c.cfd, "announce") < 0){
		sys->print("ax25chk: announce: %r\n");
		return;
	}
	if(opendata(c) < 0)
		return;

	one := array[1] of byte;
	n := sys->read(c.dfd, one, len one);
	ck("short-read-refused", n < 0, sys->sprint("read %d", n));

	b := array[Nodigi] of byte;
	for(i := 0; i < count; i++){
		n = sys->read(c.dfd, b, len b);
		ck(sys->sprint("read-%d", i), n > 0, sys->sprint("%d %r", n));
		if(n > 0)
			sys->print("info %q\n", string b[0:n]);
	}
	sys->print("%s\n", status(c.n));
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
		sys->print("usage: ax25chk setup|send|sendvia|beacon|recv|stats\n");
		return;
	}
	mode := hd argv;
	argv = tl argv;

	case mode {
	"setup" =>
		call := "N0CALL";
		if(argv != nil)
			call = hd argv;
		setup(call);
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
	"recv" =>
		recv(count(argv));
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

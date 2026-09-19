implement Radiochk;

#
# Check what #W/radio0/data refuses, which is the part of its design
# that a shell cannot reach: the console line discipline will not carry
# a command line long enough to make an oversize write, so the two
# refusals below have no other test.
#
# They are refusals rather than conveniences on purpose.  A write longer
# than the payload budget is an error naming the budget, not a packet
# split silently in two, because splitting is the segmentation layer and
# doing it quietly would hide the message-size problem in
# doc/pycubed-plan.ms.  A read whose buffer is smaller than the packet
# is an error, not a truncation, because ssl(3) documents the
# one-write-one-read contract that everything above this depends on.
#
# With no argument it checks the write side, which needs no second
# station.  "recv" checks the read side and wants a packet sent to it.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Radiochk: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Data:	con "/dev/radio0/data";

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

writeside(fd: ref Sys->FD)
{
	# 255 is the FIFO, 4 of it the RadioHead header, so 251 is the
	# budget and 252 is one past it.
	over := array[252] of byte;
	for(i := 0; i < len over; i++)
		over[i] = byte 'x';
	n := sys->write(fd, over, len over);
	e := sys->sprint("%r");
	ck("oversize-write-refused", n < 0, sys->sprint("wrote %d", n));
	ck("oversize-write-names-budget", len e > 0 && strstr(e, "251") >= 0,
		sys->sprint("error was %q", e));

	small := array[16] of byte;
	for(j := 0; j < len small; j++)
		small[j] = byte 'y';
	n = sys->write(fd, small, len small);
	ck("legal-write-accepted", n == len small, sys->sprint("%d %r", n));
}

readside(fd: ref Sys->FD)
{
	# A packet is waiting, or this blocks until one is.  Ask for one
	# byte of it first: that must fail rather than hand back a byte.
	one := array[1] of byte;
	n := sys->read(fd, one, len one);
	ck("short-read-refused", n < 0, sys->sprint("read %d", n));

	full := array[251] of byte;
	n = sys->read(fd, full, len full);
	ck("full-read-accepted", n > 0, sys->sprint("%d %r", n));
	if(n > 0)
		sys->print("payload %q\n", string full[0:n]);
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

	mode := "";
	if(tl argv != nil)
		mode = hd tl argv;

	fd := sys->open(Data, Sys->ORDWR);
	if(fd == nil){
		sys->print("radiochk: %s: %r\n", Data);
		return;
	}

	if(mode == "recv")
		readside(fd);
	else
		writeside(fd);

	sys->print("%d checks, %d failed\n", nrun, nfail);
	if(nfail == 0 && nrun > 0)
		sys->print("RADIOCHK-OK\n");
}

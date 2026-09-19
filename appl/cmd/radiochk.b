implement Radiochk;

#
# Check what #W/radio0 refuses and what it hands back, which is the part
# of its design a shell cannot reach: the console line discipline will
# not carry a command line long enough to make an oversize write, and it
# cannot decode the ancillary header on pkt.
#
# The refusals are refusals rather than conveniences on purpose.  A write
# longer than the payload budget is an error naming the budget, not a
# packet split silently in two, because splitting is the segmentation
# layer and doing it quietly would hide the message-size problem in
# doc/pycubed-plan.ms.  A read whose buffer is smaller than the packet is
# an error, not a truncation, because ssl(3) documents the
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
Pkt:	con "/dev/radio0/pkt";

Maxpayload:	con 255;
Pkthdrlen:	con 12;

Pcrcerr:	con 1<<0;

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
	# The FIFO is 255 and the device adds nothing to what is written,
	# so 255 is the budget and 256 is one past it.
	over := array[Maxpayload+1] of byte;
	for(i := 0; i < len over; i++)
		over[i] = byte 'x';
	n := sys->write(fd, over, len over);
	e := sys->sprint("%r");
	ck("oversize-write-refused", n < 0, sys->sprint("wrote %d", n));
	ck("oversize-write-names-budget",
		len e > 0 && strstr(e, string Maxpayload) >= 0,
		sys->sprint("error was %q", e));

	small := array[16] of byte;
	for(j := 0; j < len small; j++)
		small[j] = byte 'y';
	n = sys->write(fd, small, len small);
	ck("legal-write-accepted", n == len small, sys->sprint("%d %r", n));
}

get2(b: array of byte, i: int): int
{
	return int b[i] | (int b[i+1] << 8);
}

sign16(v: int): int
{
	if(v & 16r8000)
		return v - 16r10000;
	return v;
}

get4(b: array of byte, i: int): int
{
	return int b[i] | (int b[i+1] << 8) | (int b[i+2] << 16) |
		(int b[i+3] << 24);
}

readside(fd: ref Sys->FD)
{
	# A packet is waiting, or this blocks until one is.  Ask for one
	# byte of it first: that must fail rather than hand back a byte.
	one := array[1] of byte;
	n := sys->read(fd, one, len one);
	ck("short-read-refused", n < 0, sys->sprint("read %d", n));

	full := array[Maxpayload] of byte;
	n = sys->read(fd, full, len full);
	ck("full-read-accepted", n > 0, sys->sprint("%d %r", n));
	if(n > 0)
		sys->print("payload %q\n", string full[0:n]);
}

pktside()
{
	fd := sys->open(Pkt, Sys->OREAD);
	if(fd == nil){
		ck("pkt-open", 0, sys->sprint("%r"));
		return;
	}

	# Same refusal as data: pkt is one read or none.
	one := array[1] of byte;
	n := sys->read(fd, one, len one);
	ck("pkt-short-read-refused", n < 0, sys->sprint("read %d", n));

	b := array[Pkthdrlen+Maxpayload] of byte;
	n = sys->read(fd, b, len b);
	ck("pkt-read-accepted", n >= Pkthdrlen, sys->sprint("%d %r", n));
	if(n < Pkthdrlen)
		return;

	plen := get2(b, 0);
	rssi := sign16(get2(b, 2));
	snr := sign16(get2(b, 4));
	flags := get2(b, 6);
	tick := get4(b, 8);

	# The ancillary length must agree with what the read returned,
	# or the header and the payload have been paired wrongly.
	ck("pkt-len-agrees", plen == n - Pkthdrlen,
		sys->sprint("header says %d, read %d", plen, n - Pkthdrlen));

	# A demodulated LoRa packet is between -148 and 0 dBm and its SNR
	# is between -20 and +10 dB.  Outside that the header is not being
	# read as the header.
	ck("pkt-rssi-sane", rssi < 0 && rssi > -160, sys->sprint("%d", rssi));
	ck("pkt-snr-sane", snr <= 20 && snr >= -30, sys->sprint("%d", snr));

	sys->print("pkt len %d rssi %d snr %d flags %#x tick %d payload %q\n",
		plen, rssi, snr, flags, tick,
		string b[Pkthdrlen:n]);
	if(flags & Pcrcerr)
		sys->print("pkt crc failed\n");
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

	if(mode == "pkt"){
		pktside();
		verdict();
		return;
	}

	# The write side only writes, and opening for reading would claim
	# the radio's receive path from whoever has it.
	omode := Sys->OWRITE;
	if(mode == "recv")
		omode = Sys->OREAD;
	fd := sys->open(Data, omode);
	if(fd == nil){
		sys->print("radiochk: %s: %r\n", Data);
		return;
	}

	if(mode == "recv")
		readside(fd);
	else
		writeside(fd);

	verdict();
}

verdict()
{
	sys->print("%d checks, %d failed\n", nrun, nfail);
	if(nfail == 0 && nrun > 0)
		sys->print("RADIOCHK-OK\n");
}

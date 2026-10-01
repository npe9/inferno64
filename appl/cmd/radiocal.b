implement Radiocal;

#
# Calibrate a radio's RSSI against its own transmitter's attenuator, with
# both ends on the boards and nothing typing at a console.
#
# doc/radio-plan.ms item 7.  Items 1 to 3 were measured by a Python
# script typing at two consoles, one ctl write per line, reading the stat
# file between them.  That found three driver bugs and is the wrong way
# to own the numbers, for three reasons that are all about where they
# come from.
#
# THE HOST SET THE PACE, so the transmitter's step and the receiver's
# reading were joined up by whatever was typing at both, and a dropped
# console line attributes a reading to the wrong step with nothing saying
# so.  Here the step is in the payload: every packet says which rung it
# belongs to, so the receiver needs no synchronisation at all and can be
# started and stopped independently of the transmitter.
#
# THE STAT FILE GIVES ONE "last" RSSI PER READ, so a rung got one sample
# however many packets it sent.  #W/radio0/pkt hands over the twelve-byte
# header with every packet -- length, RSSI, SNR, flags and arrival tick,
# out of the same queue entry -- so a rung gets a mean and a spread, and
# the CRC flag per packet instead of a counter difference.
#
# AND THE PACKET ERROR RATE HAS TO BE COUNTED WHERE THE PACKETS ARE.
# Reading recv before and after a rung measures what arrived minus what
# arrived, and cannot tell a lost packet from a late one.  A sequence
# number in the payload can.
#
# WHAT THIS MEASURES AND WHAT IT CANNOT.  PA_CFG2.PA_POWER_RAMP is the
# transmitter's own attenuator: SWRU295E gives its output as
# (PA_POWER_RAMP + 1)/2 - 18 dBm, so one count is half a decibel over a
# 31.5dB range.  Walking it and watching the RSSI measures the PRODUCT of
# two things -- how accurately that field steps, and how accurately this
# receiver reports a change -- and a slope of one means both are right or
# both are wrong by reciprocal amounts.  It cannot separate them, and it
# gives no offset, because free space between two antennas is an unknown
# loss.  It is worth having because a tinySA's attenuator, a real one
# stepping a real generator cabled into the click, already gave 0.93 over
# 24dB: a figure near that from an entirely different ladder is two
# independent instruments agreeing, and one far from it says that one of
# them is wrong.  The program prints that caveat with its answer, because
# a slope without it is a number somebody will quote.
#
# The payload is eleven bytes and its layout is this program's:
#
#	0	'C'		so a stray packet is not a rung
#	1	'L'
#	2	ramp		PA_POWER_RAMP, 0 to 63
#	3	seq		within the rung, 0 to npkt-1
#	4	npkt		how many this rung sends
#	5-10	'r','a','d','i','o'	filler, so a length is a length
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";

Radiocal: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Ctl:	con "/dev/radio0/ctl";
Data:	con "/dev/radio0/data";
Pkt:	con "/dev/radio0/pkt";
Stats:	con "/dev/radio0/stats";

Rpacfg2:	con 16r2b;	# PA_CFG2
Pareserved6:	con 16r40;	# reads 1; the driver's -10dBm is 0x4f
Rampmax:	con 63;

Maxpayload:	con 125;
Pkthdrlen:	con 12;
Pcrcerr:	con 1<<0;

Paylen:		con 11;
Magic0:		con 'C';
Magic1:		con 'L';

Nrung:		con Rampmax+1;

# per rung, filled in by the receiver
got:	array of int;
miss:	array of int;
crcbad:	array of int;
rsum:	array of int;
rmin:	array of int;
rmax:	array of int;
seen:	array of array of int;	# which sequence numbers arrived

nsent:	int;
nstray:	int;	# packets that were not this program's
nread:	int;	# reads that returned something
nreaderr: int;	# reads that failed
rerr:	string;	# why the last one failed
reported: int;	# the table is printed once
waited:	int;	# milliseconds the window really lasted
askedms: int;	# milliseconds it was asked for

usage()
{
	sys->fprint(sys->fildes(2),
		"usage: radiocal -t [-n per-rung] [-s step] [-f first] " +
		"[-l last]\n" +
		"       radiocal -r [-w seconds]\n");
	raise "fail:usage";
}

dbmof(ramp: int): int
{
	# (ramp+1)/2 - 18, in tenths so that the half-decibel steps are
	# not rounded away.  Limbo's int division truncates toward zero
	# and ramp+1 is positive, so (ramp+1)*5 is exact.
	return (ramp+1)*5 - 180;
}

put2(b: array of byte, i: int, v: int)
{
	b[i] = byte v;
	b[i+1] = byte (v >> 8);
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

# One ctl line, written and not assumed.
ctlwrite(fd: ref Sys->FD, s: string): int
{
	a := array of byte s;
	if(sys->write(fd, a, len a) != len a){
		sys->fprint(sys->fildes(2), "radiocal: write %q: %r\n", s);
		return 0;
	}
	return 1;
}

# Set PA_CFG2 and read it back off the part, rather than believing the
# write.
#
# TWO THINGS HERE WERE BUGS AND BOTH ARE WORTH THE COMMENT.
#
# The ctl verb parses its arguments with strtoul(s, nil, 0), which is C
# radix and not Limbo's: "16r2b" parses as 16 and stops at the r, so
# "reg 16r2b 16r7f" set register 0x10 to 0x10 -- a modem register, not
# the amplifier -- and the first run of this program transmitted four
# rungs that the receiver never heard.  It has to be written 0x.
#
# And the read-back could not be done at all.  The verb prints
# "reg 0xNN 0xNN" on the console, which a Dis program cannot read, so
# there was no way to assert that a rung's register had taken; a ladder
# whose rungs are not asserted is a ladder of guesses.  So PA_CFG2 and
# the power the datasheet's formula gives for it are in the stat file
# now -- fix the tool, not the caller.
setpower(ctl: ref Sys->FD, ramp: int): int
{
	if(!ctlwrite(ctl, sys->sprint("reg 0x%x 0x%x",
	    Rpacfg2, ramp|Pareserved6)))
		return 0;
	ln := statline("pacfg2");
	if(ln == nil){
		sys->fprint(sys->fildes(2), "radiocal: the stat file does "
			+ "not report pacfg2; this kernel cannot assert a "
			+ "rung\n");
		return 0;
	}
	# "pacfg2 0xNN ramp N power N.NdBm".  The decimal ramp and not
	# the hex register: Limbo's radix is 16r, so int "0x7f" is 0, and
	# the first cut of this read the hex field and declared every
	# rung void against a register that had taken.
	(nf, f) := sys->tokenize(ln, " ");
	if(nf < 4)
		return 0;
	v := (int hd tl tl tl f) | Pareserved6;
	if(v != (ramp|Pareserved6)){
		sys->fprint(sys->fildes(2), "radiocal: PA_CFG2 reads 0x%x, "
			+ "asked for 0x%x -- the rung is void\n",
			v, ramp|Pareserved6);
		return 0;
	}
	return 1;
}

statline(what: string): string
{
	fd := sys->open(Stats, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[1024] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	s := string b[0:n];
	for(l := sys->tokenize(s, "\n").t1; l != nil; l = tl l){
		ln := hd l;
		if(len ln >= len what && ln[0:len what] == what)
			return ln;
	}
	return nil;
}

transmit(npkt, step, first, last: int)
{
	ctl := sys->open(Ctl, Sys->OWRITE);
	if(ctl == nil){
		sys->fprint(sys->fildes(2), "radiocal: open %s: %r\n", Ctl);
		raise "fail:ctl";
	}
	data := sys->open(Data, Sys->OWRITE);
	if(data == nil){
		sys->fprint(sys->fildes(2), "radiocal: open %s: %r\n", Data);
		raise "fail:data";
	}

	sys->print("radiocal -t: %d packets a rung, ramp %d down to %d " +
		"in steps of %d\n", npkt, first, last, step);
	sys->print("%s\n", statline("freq"));

	b := array[Paylen] of byte;
	b[0] = byte Magic0;
	b[1] = byte Magic1;
	b[5] = byte 'r'; b[6] = byte 'a'; b[7] = byte 'd';
	b[8] = byte 'i'; b[9] = byte 'o'; b[10] = byte '!';

	for(ramp := first; ramp >= last; ramp -= step){
		if(!setpower(ctl, ramp)){
			sys->print("radiocal: rung %d refused, stopping\n",
				ramp);
			return;
		}
		b[2] = byte ramp;
		b[4] = byte npkt;
		nok := 0;
		for(i := 0; i < npkt; i++){
			b[3] = byte i;
			if(sys->write(data, b, len b) == len b)
				nok++;
			sys->sleep(60);
		}
		d := dbmof(ramp);
		sys->print("rung ramp %2d  %4d.%d dBm  wrote %d of %d\n",
			ramp, d/10, abs(d%10), nok, npkt);
		nsent += nok;
	}
	# and back to what the driver boots with, so a calibration run
	# does not leave the board quietly on a different power
	setpower(ctl, 16r0f);
	sys->print("radiocal -t: %d packets written, PA_CFG2 back to 0x4f\n",
		nsent);
}

abs(v: int): int
{
	if(v < 0)
		return -v;
	return v;
}

receive(secs: int)
{
	fd := sys->open(Pkt, Sys->OREAD);
	if(fd == nil){
		sys->fprint(sys->fildes(2), "radiocal: open %s: %r\n", Pkt);
		raise "fail:pkt";
	}

	got = array[Nrung] of {* => 0};
	miss = array[Nrung] of {* => 0};
	crcbad = array[Nrung] of {* => 0};
	rsum = array[Nrung] of {* => 0};
	rmin = array[Nrung] of {* => 0};
	rmax = array[Nrung] of {* => 0};
	seen = array[Nrung] of array of int;
	nstray = 0;
	nread = 0;
	nreaderr = 0;
	rerr = nil;
	reported = 0;

	askedms = secs*1000;
	waited = 0;
	sys->print("radiocal -r: listening on %s for %d seconds\n",
		Pkt, secs);
	sys->print("%s\n", statline("freq"));

	# WHICH PROCESS READS, AND TWO WAYS OF GETTING IT WRONG.
	#
	# A read of pkt blocks in qbread() and this board has no
	# interrupt character -- nothing in its devcons turns a keystroke
	# into a note -- so a timed run has to be ended by a process
	# other than the one blocked.  Two arrangements were tried and
	# both failed, differently:
	#
	# Reading here with a spawned ticker writing "killgrp" to this
	# process's ctl file killed the group, which includes this
	# process, so the table was never printed.  Under qemu the
	# receiver said "listening for 60 seconds" and then nothing at
	# all until qemu itself was terminated.
	#
	# Reading in a SPAWNED process, with this one owning the clock and
	# killing it by pid, printed the table and never read anything:
	# "0 reads returned, 0 failed" against the driver's own recv 12
	# and intr high 12 low 12 on the same run.  THE SPAWN WAS NOT THE
	# FAULT and this is kept because that took three runs to see: the
	# window had already closed.  Under qemu this board's clock runs
	# about three times fast, so -w 25 expired some eight host seconds
	# in, before the transmitter had been typed at, and the packets
	# arrived afterwards.  Reading here fails the same way with the
	# same window; what fixed it was a window long enough in GUEST
	# seconds, and the program now prints what its window really
	# lasted so that this cannot happen silently again.
	#
	# This process reads all the same, because it is the simpler of
	# the two and the shell is waiting on it, and the spawned one owns
	# the clock: when it expires it prints the table -- which it can,
	# because the counters are this module's and both processes are
	# the same module instance -- and only then kills the group.
	spawn ticker(secs);

	b := array[Pkthdrlen+Maxpayload] of byte;
	for(;;){
		n := sys->read(fd, b, len b);
		if(n < 0){
			# WHY THIS IS REPORTED AND NOT JUST BROKEN OUT OF.
			# A loop that ends in silence is the same bug as a
			# counter downstream of the fault: the receiver
			# printed an empty table while the driver's recv
			# said 12, which reads as "the radio heard
			# nothing" and was a reader that had stopped.
			rerr = sys->sprint("%r");
			nreaderr++;
			break;
		}
		nread++;
		if(n < Pkthdrlen+Paylen){
			nstray++;
			continue;
		}
		plen := get2(b, 0);
		rssi := sign16(get2(b, 2));
		flags := get2(b, 6);
		p := b[Pkthdrlen:n];
		if(plen != n - Pkthdrlen || len p < Paylen ||
		   int p[0] != Magic0 || int p[1] != Magic1){
			nstray++;
			continue;
		}
		ramp := int p[2];
		seq := int p[3];
		cnt := int p[4];
		if(ramp > Rampmax || cnt < 1 || cnt > 255 || seq >= cnt){
			nstray++;
			continue;
		}
		if(seen[ramp] == nil){
			# sized to what the rung says it sends, so the
			# missing ones are countable without the
			# transmitter and the receiver agreeing by
			# arrangement
			seen[ramp] = array[cnt] of {* => 0};
			rmin[ramp] = rssi;
			rmax[ramp] = rssi;
		}
		if(seq < len seen[ramp])
			seen[ramp][seq] = 1;
		got[ramp]++;
		if(flags & Pcrcerr)
			crcbad[ramp]++;
		rsum[ramp] += rssi;
		if(rssi < rmin[ramp])
			rmin[ramp] = rssi;
		if(rssi > rmax[ramp])
			rmax[ramp] = rssi;
	}

	# only reached if the read failed; the normal end is the ticker
	report();
}

# The clock.  It prints the table before killing the group, because the
# process that was reading cannot print after it is dead -- which is
# what the first arrangement here got wrong.
ticker(secs: int)
{
	t0 := sys->millisec();
	sys->sleep(secs*1000);
	# How long it really waited, because under qemu a guest second is
	# not a host second and that cost three runs: the table printed
	# empty while the driver's recv climbed to 12 afterwards, which
	# reads as a receiver that heard nothing and was a window that
	# had already closed.  A measurement whose duration is assumed is
	# a measurement whose duration is wrong.
	waited = sys->millisec() - t0;
	report();
	fd := sys->open("/prog/" + string sys->pctl(0, nil) + "/ctl",
		Sys->OWRITE);
	if(fd != nil){
		a := array of byte "killgrp";
		sys->write(fd, a, len a);
	}
}

# The table and the slope.  Called by the ticker in the normal case
# and by the reader if its read failed, so it must not run twice.
report()
{
	if(reported)
		return;
	reported = 1;
	sys->print("\n  ramp   nominal   got  lost  crcerr   RSSI mean " +
		"least most\n");
	# least squares of mean RSSI against the datasheet's dBm, in
	# tenths of a dB on the x axis so no step is rounded away
	nn := 0; sx := 0; sy := 0; sxx := 0; sxy := 0;
	for(r := Rampmax; r >= 0; r--){
		if(seen[r] == nil)
			continue;
		lost := 0;
		for(i := 0; i < len seen[r]; i++)
			if(seen[r][i] == 0)
				lost++;
		miss[r] = lost;
		mean := rsum[r] / got[r];
		d := dbmof(r);
		sys->print("  %4d  %4d.%d     %4d  %4d    %4d   %4d %4d %4d\n",
			r, d/10, abs(d%10), got[r], lost, crcbad[r],
			mean, rmin[r], rmax[r]);
		nn++;
		sx += d; sy += mean*10;
		sxx += d*d; sxy += d*mean*10;
	}
	if(nstray > 0)
		sys->print("  (%d packets were not this program's)\n", nstray);
	if(waited > 0)
		sys->print("  (the window asked for %d ms and lasted %d)\n",
			askedms, waited);
	sys->print("  (%d reads returned, %d failed", nread, nreaderr);
	if(rerr != nil)
		sys->print(", last: %s", rerr);
	sys->print(")\n");
	if(nn < 3){
		sys->print("RADIOCAL-FAILED fewer than three rungs arrived\n");
		return;
	}
	den := nn*sxx - sx*sx;
	if(den == 0){
		sys->print("RADIOCAL-FAILED every rung had the same power\n");
		return;
	}
	# slope in thousandths, so it can be printed without reals
	slope := (1000*(nn*sxy - sx*sy)) / den;
	sys->print("\nslope %d.%.3d dB of RSSI per dB of transmitter, " +
		"over %d rungs\n", slope/1000, abs(slope%1000), nn);
	sys->print("This is the PRODUCT of PA_POWER_RAMP's step accuracy and\n" +
		"this receiver's RSSI slope and cannot separate them, and it\n" +
		"gives no offset: free space between two antennas is an\n" +
		"unknown loss.  A tinySA attenuator cabled into the click\n" +
		"gave 0.930 over 24dB, so agreement with that is two\n" +
		"independent ladders agreeing.\n");
	sys->print("RADIOCAL-OK slope %d.%.3d rungs %d\n",
		slope/1000, abs(slope%1000), nn);
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	if(arg == nil){
		sys->fprint(sys->fildes(2), "radiocal: load %s: %r\n",
			Arg->PATH);
		raise "fail:load";
	}

	npkt := 5;
	step := 8;
	first := Rampmax;
	last := 0;
	secs := 120;
	role := ' ';

	arg->init(argv);
	arg->setusage("radiocal [-t|-r] [-n per-rung] [-s step] " +
		"[-f first] [-l last] [-w seconds]");
	while((c := arg->opt()) != 0)
		case c {
		't' =>	role = 't';
		'r' =>	role = 'r';
		'n' =>	npkt = int arg->earg();
		's' =>	step = int arg->earg();
		'f' =>	first = int arg->earg();
		'l' =>	last = int arg->earg();
		'w' =>	secs = int arg->earg();
		* =>	arg->usage();
		}
	if(arg->argv() != nil)
		arg->usage();
	arg = nil;

	if(npkt < 1 || npkt > 255 || step < 1 || step > 64 ||
	   first < 0 || first > Rampmax || last < 0 || last > first ||
	   secs < 1)
		usage();

	case role {
	't' =>	transmit(npkt, step, first, last);
	'r' =>	receive(secs);
	* =>	usage();
	}
}

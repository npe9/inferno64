implement Radiocfg;

#
# Apply this board's own radio calibration, from /lib/radio.
#
# doc/radio-plan.ms item 8.  Every calibration this bench has measured
# belongs to one board: the crystal error, the RSSI offset, the carrier
# sense threshold.  os/inferno/stm32f407/spistm32f4.c carried
# ".ppb = -3550, measured on this board and not taken from anywhere",
# which was right when there was one board.  With two it is wrong on
# half the bench, and the two crystals here are 64 parts per million
# apart -- 58.7kHz at 915MHz, wider than the 50kHz channel filter, so an
# uncorrected pair cannot hear each other even in principle.
#
# So the image carries the calibrations for every board it knows and
# each board picks its own.  The picking needs an identity, and an
# identity a board is told is circular: the thing that would tell it is
# the thing that needs to know.  #P/uid is the microcontroller's own
# 96-bit factory serial (RM0090 39.1), read-only, which no reflash can
# change.
#
# The reader is appl/lib/radiocal.b, shared with the init that applies
# the same file on a board running no shell: at NPROC 5 a shell and #a
# will not both fit here, so the thing that calibrates a board cannot
# always be a command.  Two callers, one format, one reader.
#
# The file is attrdb(6) and is /lib/radio and not /lib/ndb/radio,
# because ndb(6) is the attribute database for NETWORK configuration and
# /lib/ndb/local names the files of that one logical database -- a
# crystal error is not network data and would be read by every program
# that opens it.
#
# WHY IT PARSES THE FILE ITSELF, WHICH WAS NOT THE FIRST ANSWER.
# attrdb(2) is in this tree and the first version used it, on the
# argument that a format is a format and a second implementation of it
# is a second set of bugs.  That argument is right and it loses to a
# measurement: on silicon, with 147456 bytes of Dis pool and the shell
# already in it,
#
#	; radiocfg
#	radiocfg: uid 203730395931500800300022 is board2 in /lib/radio
#	sh: /dis/radiocfg.dis: exception: out of memory: heap
#
# and the same from a freshly booted board, where some 38000 bytes are
# free at the prompt.  The lookup worked -- that line is attrdb finding
# the right entry -- and then the parsed structures and the tokenising
# that followed did not fit.
#
# So the reader here is a strict subset: an entry begins in column one,
# indented lines continue it, "#" starts a comment, and pairs are
# attr=value separated by white space.  It is a single pass with one
# fixed buffer and no lists, and it REPORTS anything it cannot parse
# rather than skipping it, because a subset parser that silently ignores
# what it does not understand is how a calibration file comes to say one
# thing and mean another.  The file is still attrdb(6) and attrdb(2)
# still reads it on a host, which is where it is edited.
#
# WHAT IT REPORTS AND WHY.  Every line it writes, and every attribute
# the entry did not have.  A calibration silently not applied looks
# exactly like one applied wrongly, and this bench has already spent a
# day on a receiver that was working: a program that says "applied ppb
# -3550" and a program that says nothing are the difference between a
# measurement and a guess.  It also reads the figures back out of the
# stat file rather than trusting its own writes, which is the same rule
# one level up.
#
# A board with no entry is not an error.  It says so and leaves the
# driver's defaults, because a new board on this bench has no
# calibration yet and should still come up.  A board whose uid cannot be
# read IS an error: then it does not know whose numbers it would be
# using.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "radiocal.m";
	radiocal: Radiocal;

Radiocfg: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Ctl:	con "/dev/radio0/ctl";
Stats:	con "/dev/radio0/stats";

nset, nmissing: int;
dryrun, record: int;

# One field out of the stat file, by a scan and not by tokenising it.
#
# The first version read the whole file, split it into lines and split
# every line into fields, which on a seven-hundred-byte stat file is a
# list of lists of strings for the sake of one number.  That is a page
# of heap per call on a board that has about 38000 bytes, and it was
# part of what put the attrdb version over.
statfield(what: string): string
{
	fd := sys->open(Stats, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[1024] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	s := string b[0:n];
	# "<what> <value>" at the start of a line, or after a space
	for(i := 0; i <= len s - len what; i++){
		if(i > 0 && s[i-1] != '\n' && s[i-1] != ' ')
			continue;
		if(s[i:i+len what] != what)
			continue;
		j := i + len what;
		if(j >= len s || s[j] != ' ')
			continue;
		j++;
		k := j;
		while(k < len s && s[k] != ' ' && s[k] != '\n')
			k++;
		return s[j:k];
	}
	return nil;
}

# One ctl line, and then the stat file asked whether it took.
apply(ctl: ref Sys->FD, verb, val, field, src: string)
{
	if(val == nil){
		sys->print("radiocfg: no %s in the entry; the driver's "
			+ "default stands\n", verb);
		nmissing++;
		return;
	}
	line := verb + " " + val;
	if(dryrun){
		sys->print("radiocfg: would write %q\n", line);
		nset++;
		return;
	}
	a := array of byte line;
	if(sys->write(ctl, a, len a) != len a){
		sys->fprint(sys->fildes(2), "radiocfg: %q: %r\n", line);
		return;
	}
	got := statfield(field);
	if(got == nil)
		sys->print("radiocfg: wrote %q; the stat file does not "
			+ "report %s, so it cannot be checked\n", line, field);
	else if(int got != int val)
		sys->fprint(sys->fildes(2), "radiocfg: wrote %q and %s reads "
			+ "%s -- the calibration is NOT in force\n",
			line, field, got);
	else{
		sys->print("radiocfg: %s %s, from %s\n", verb, got, src);
		nset++;
	}
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	if(arg == nil){
		sys->fprint(sys->fildes(2), "radiocfg: load %s: %r\n",
			Arg->PATH);
		raise "fail:load";
	}

	cal := Radiocal->Cal;
	uidpath := Radiocal->Uid;
	uid := "";
	show := 0;

	arg->init(argv);
	arg->setusage("radiocfg [-n] [-s] [-w] [-f file] [-u uid]");
	while((c := arg->opt()) != 0)
		case c {
		'n' =>	dryrun = 1;
		's' =>	show = 1;
		'w' =>	record = 1;
		'f' =>	cal = arg->earg();
		'u' =>	uid = arg->earg();
		* =>	arg->usage();
		}
	if(arg->argv() != nil)
		arg->usage();
	arg = nil;

	radiocal = load Radiocal Radiocal->PATH;
	if(radiocal == nil){
		sys->fprint(sys->fildes(2), "radiocfg: load %s: %r\n",
			Radiocal->PATH);
		raise "fail:load";
	}
	radiocal->init();

	if(uid == nil || uid == ""){
		uid = radiocal->boarduid(uidpath);
		if(uid == nil){
			sys->fprint(sys->fildes(2), "radiocfg: cannot read "
				+ "%s: %r\nWithout it this board does not know "
				+ "whose calibration it would be applying, "
				+ "which is worse than having none.\n",
				uidpath);
			raise "fail:uid";
		}
	}
	if(show){
		sys->print("%s\n", uid);
		return;
	}

	Wppb, Wrssioffset, Wcsthr, Wname, Wslope, Wsrc, Nwant: con iota;
	want := array[Nwant] of string;
	want[Wppb] = "ppb";
	want[Wrssioffset] = "rssioffset";
	want[Wcsthr] = "csthr";
	want[Wname] = "name";
	want[Wslope] = "rssislope";
	want[Wsrc] = "slopesource";

	# Both sources, the store winning: /lib/radio is what the image
	# was built with and #P/cal is what this board has measured
	# since.  A board whose crystal was measured after its image was
	# built should use the measurement without being reflashed.
	(got, from, bad, err) := radiocal->current(cal, uid, want);
	if(err == "noentry"){
		sys->print("radiocfg: neither %s nor %s has an entry for uid "
			+ "%s; this board is uncalibrated and the driver's "
			+ "defaults stand\n", cal, Radiocal->Store, uid);
		return;
	}
	if(err != nil){
		sys->fprint(sys->fildes(2), "radiocfg: %s\n", err);
		raise "fail:db";
	}
	if(bad > 0)
		sys->fprint(sys->fildes(2), "radiocfg: %d unparsable pairs "
			+ "in %s, named above\n", bad, cal);

	name := got[Wname];
	if(name == nil)
		name = "unnamed";
	sys->print("radiocfg: uid %s is %q in %s\n", uid, name, cal);

	ctl := sys->open(Ctl, Sys->OWRITE);
	if(ctl == nil && !dryrun){
		sys->fprint(sys->fildes(2), "radiocfg: open %s: %r\n", Ctl);
		raise "fail:ctl";
	}

	# ppm takes parts per billion despite its name; see the verb's
	# own comment in os/inferno/radio/cc1120.c.
	apply(ctl, "ppm", got[Wppb], "ppb", from[Wppb]);
	apply(ctl, "rssioffset", got[Wrssioffset], "offset",
		from[Wrssioffset]);
	apply(ctl, "csthr", got[Wcsthr], "csthr", from[Wcsthr]);

	# Not applied, only reported: the slope is a property of the
	# receiver that nothing in the driver takes.  It is here so that
	# whoever reads an RSSI knows how much of a change it reports.
	if(got[Wslope] != nil)
		sys->print("radiocfg: rssislope %s (%s), which nothing "
			+ "applies: it is what an RSSI change is worth\n",
			got[Wslope], got[Wsrc]);

	sys->print("radiocfg: %d applied, %d absent from the entry\n",
		nset, nmissing);

	if(record)
		keepit(uid);
}

# Append what the part now holds to #P/cal, so that a figure worked out
# by hand survives a reboot without a reflash.
#
# It records what the PART holds and not what was asked for or what the
# file said: the whole arrangement here is that a number is read back off
# the hardware before it is believed, and a store written from an
# intention rather than from a read-back would be the one place that rule
# did not hold.
keepit(uid: string)
{
	ppb := statfield("ppb");
	off := statfield("offset");
	cs := statfield("csthr");
	if(ppb == nil || off == nil || cs == nil){
		sys->fprint(sys->fildes(2), "radiocfg: the stat file does "
			+ "not report all of ppb, offset and csthr, so there "
			+ "is nothing honest to record\n");
		return;
	}
	rec := sys->sprint("radio=cc1120 uid=%s ppb=%s rssioffset=%s "
		+ "csthr=%s\n", uid, ppb, off, cs);
	if(dryrun){
		sys->print("radiocfg: would append to %s: %s",
			Radiocal->Store, rec);
		return;
	}
	fd := sys->open(Radiocal->Store, Sys->OWRITE);
	if(fd == nil){
		sys->fprint(sys->fildes(2), "radiocfg: %s: %r\n",
			Radiocal->Store);
		return;
	}
	a := array of byte rec;
	if(sys->write(fd, a, len a) != len a){
		sys->fprint(sys->fildes(2), "radiocfg: append to %s: %r\n",
			Radiocal->Store);
		return;
	}
	sys->print("radiocfg: recorded in %s: %s", Radiocal->Store, rec);
}

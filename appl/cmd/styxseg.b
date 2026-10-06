implement Styxseg;

#
# Does a Styx message survive being chopped into radio-sized pieces?
#
#	styxseg [-b budget] [-n reads] [-d] file
#
# WHY THIS EXISTS.  os/inferno/init/armv7mstyx.b mounts a namespace over
# an AX.25 conversation whose information field is 109 bytes, which is
# below the 256 os/inferno/port/devmnt.c insists on, so a pipe sits
# between Styx and the radio and two processes chop writes into pieces
# the frame holds.  That worked for a message inside one frame and then
# a 284-byte Rread -- the 273 bytes of #P/arch and its eleven-byte
# header -- came back 273 bytes the first time and 271 the second.
#
# Two bytes, repeatably, and doc/pycubed-plan.ms records it as a fault
# in the transfer.  The trouble with chasing it on the bench is that the
# path has four things in it that could lose a pair of bytes -- the
# relay, devmnt's reassembly, devax25's connected mode, and the air --
# and a board is needed to exercise any of them.
#
# THIS TAKES THE RADIO OUT AND LEAVES EVERYTHING ELSE.  Two pipes and
# two chopping processes make a bidirectional link with the same write
# limit the conversation has; exportfs serves one end and devmnt mounts
# the other.  Run it under a host emu and it answers, in a second,
# whether the relay and the reassembly can lose two bytes on their own.
# If they cannot, the fault is in the device or on the air, and that is
# a narrower thing to take to a board.
#
# It is not a model of the radio and does not pretend to be: a pipe is
# ordered, reliable and never drops a frame, which is exactly what the
# connected mode is supposed to provide and what this therefore holds
# fixed.
#
include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";

Styxseg: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

debug := 0;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	if(arg == nil){
		sys->fprint(sys->fildes(2), "styxseg: load arg: %r\n");
		raise "fail:load";
	}
	budget := 109;
	nreads := 2;
	# /n/client because it exists in every root this has to run in --
	# the station init's own mount point is /n/dev, which the host
	# tree does not have, and a test that has to create its mount
	# point is a test that can fail for a reason that is not the
	# measurement.
	mpt := "/n/client";
	lo := 1;
	hi := 600;
	stride := 1;
	# THE MESSAGE SIZE IS NOT SETTABLE FROM HERE, and the attempt is
	# left in as a flag that defaults to off because the reason is
	# worth knowing.
	#
	# The board's msize is 436 -- four AX.25 information fields, set
	# by os/inferno/stm32f407/archstm32f407.c -- where over a host
	# pipe devmnt takes 8192.  Asking for 436 with sys->fversion()
	# before the mount does negotiate it, and then mount() sends its
	# OWN Tversion on the same connection, which 9P does not allow on
	# an established one: both ends wait and nothing is printed.  So
	# -M hangs, by construction, and is kept only so that nobody
	# spends an afternoon rediscovering that it does.
	#
	# What reaching the board's msize would really take is the
	# transport advertising a small iounit, because that is what
	# devmnt clamps to -- the same mechanism by which the AX.25
	# conversation's 109 became the msize in the first place.
	msize := 0;
	arg->init(argv);
	arg->setusage("styxseg [-d] [-b budget] [-n reads] [-m mpt]\n\t[-l lo] [-h hi] [-s stride] [-M msize] [file]");
	while((c := arg->opt()) != 0)
		case c {
		'b' =>	budget = int arg->earg();
		'n' =>	nreads = int arg->earg();
		'd' =>	debug = 1;
		'm' =>	mpt = arg->earg();
		'l' =>	lo = int arg->earg();
		'h' =>	hi = int arg->earg();
		's' =>	stride = int arg->earg();
		'M' =>	msize = int arg->earg();
		* =>	arg->usage();
		}
	argv = arg->argv();
	arg = nil;
	# WITH NO FILE IT MAKES ITS OWN, of a size it chooses, and that is
	# the difference between a test and an anecdote.  The first run of
	# this was pointed at /dev/time and reported the transfer
	# corrupting data at byte 13 -- which it had not; the clock had
	# moved between the two reads.  A file whose contents this wrote
	# cannot do that, and a size this chooses can be swept until one
	# of them loses bytes.
	path: string;
	if(argv != nil)
		path = hd argv;

	if(budget < 1){
		sys->fprint(sys->fildes(2),
			"styxseg: a budget of %d is not a frame\n", budget);
		raise "fail:budget";
	}

	s := array[2] of ref Sys->FD;
	c2 := array[2] of ref Sys->FD;
	if(sys->pipe(s) < 0 || sys->pipe(c2) < 0){
		sys->fprint(sys->fildes(2), "styxseg: pipe: %r\n");
		raise "fail:pipe";
	}

	# The two directions, each chopped.  A pipe end is full duplex, so
	# writing s[1] is read at s[0] and reading s[1] gets what was
	# written to s[0]: one process a direction is all it takes.
	spawn chop("down", s[1], c2[1], budget);
	spawn chop("up", c2[1], s[1], budget);

	# The server first, because the answerer has to be listening
	# before the caller calls -- the same ordering the station init
	# records, and the reason a first attempt at this hung with no
	# error from either end.
	spawn serve(s[0]);

	if(msize > 0){
		(n, ver) := sys->fversion(c2[0], msize, "9P2000");
		if(n <= 0){
			sys->fprint(sys->fildes(2),
				"styxseg: fversion %d: %r\n", msize);
			raise "fail:fversion";
		}
		sys->print("styxseg: negotiated msize %d version %s\n",
			n, ver);
	}
	if(sys->mount(c2[0], nil, mpt, Sys->MREPL, nil) < 0){
		sys->fprint(sys->fildes(2), "styxseg: mount: %r\n");
		raise "fail:mount";
	}

	if(path == nil){
		# A sweep, which is what finds a size that fails rather
		# than confirming one that does not.
		bad := 0;
		for(sz := lo; sz <= hi; sz += stride)
			if(!trial(mpt, sz, budget, nreads))
				bad++;
		if(bad != 0){
			sys->print("STYXSEG-FAILED %d of the sizes from %d to"
				+ " %d lost or changed data over %d-byte"
				+ " frames\n", bad, lo, hi, budget);
			raise "fail:sweep";
		}
		sys->print("STYXSEG-OK every size from %d to %d by %d"
			+ " survived %d-byte frames, %d reads each\n",
			lo, hi, stride, budget, nreads);
		return;
	}

	# The mounted file's own idea of a message, which is what devmnt
	# negotiated and therefore the number that decides how many
	# frames a read becomes.
	mfd := sys->open(mpt + path, Sys->OREAD);
	if(mfd == nil){
		sys->fprint(sys->fildes(2), "styxseg: %s%s: %r\n", mpt, path);
		raise "fail:open";
	}
	sys->print("styxseg: %s over a %d-byte budget, iounit %d\n",
		path, budget, sys->iounit(mfd));
	mfd = nil;

	# Every read whole and compared against the first, because a
	# transfer that loses bytes may do it on the second message
	# rather than the first -- which is exactly what the bench saw,
	# and a single read would have called it sound.
	first := "";
	for(i := 0; i < nreads; i++){
		d := slurp(mpt + path);
		if(d == nil){
			sys->print("styxseg: read %d failed: %r\n", i);
			sys->print("STYXSEG-FAILED read %d\n", i);
			raise "fail:read";
		}
		if(i == 0){
			first = string d;
			sys->print("styxseg: read 0 is %d bytes\n", len d);
			continue;
		}
		if(len d != len array of byte first){
			sys->print("styxseg: read %d is %d bytes where read 0"
				+ " was %d, so the transfer is losing data\n",
				i, len d, len array of byte first);
			sys->print("STYXSEG-SHORT %d %d\n",
				len array of byte first, len d);
			raise "fail:short";
		}
		fb := array of byte first;
		for(k := 0; k < len d; k++)
			if(d[k] != fb[k]){
				sys->print("styxseg: read %d differs from"
					+ " read 0 at byte %d\n", i, k);
				sys->print("STYXSEG-DIFFER %d\n", k);
				raise "fail:differ";
			}
	}
	sys->print("STYXSEG-OK %d reads of %d bytes identical over"
		+ " %d-byte frames\n", nreads, len array of byte first,
		budget);
}

# One size, written down and read back through the mount.  The content
# is a counted pattern rather than a constant byte, so a piece arriving
# out of order or a boundary dropped shows up as a difference at a byte
# whose value says which piece it came from.
trial(mpt: string, sz, budget, nreads: int): int
{
	# /tmp because every root this runs in has one, and the SAME file
	# is written locally and read through the mount: the server is
	# this process's own namespace, so the two paths differ only by
	# the mount point.  Removed afterwards, because an instrument
	# that leaves a file behind can be read by the next run of
	# itself.
	name := "/tmp/styxseg.dat";
	want := array[sz] of byte;
	for(i := 0; i < sz; i++)
		want[i] = byte (i & 16rff);
	fd := sys->create(name, Sys->OWRITE, 8r666);
	if(fd == nil){
		sys->print("styxseg: create %s: %r\n", name);
		return 0;
	}
	if(sys->write(fd, want, sz) != sz){
		sys->print("styxseg: write %s: %r\n", name);
		return 0;
	}
	fd = nil;

	for(k := 0; k < nreads; k++){
		got := slurp(mpt + name);
		if(got == nil){
			sys->print("styxseg: %d bytes, read %d failed: %r\n",
				sz, k);
			return 0;
		}
		if(len got != sz){
			sys->print("styxseg: %d bytes came back as %d on"
				+ " read %d over %d-byte frames\n",
				sz, len got, k, budget);
			return 0;
		}
		for(i = 0; i < sz; i++)
			if(got[i] != want[i]){
				sys->print("styxseg: %d bytes differ at byte"
					+ " %d on read %d (%d not %d)\n",
					sz, i, k, int got[i], int want[i]);
				return 0;
			}
	}
	sys->remove(name);
	return 1;
}

serve(fd: ref Sys->FD)
{
	if(sys->export(fd, "/", Sys->EXPWAIT) < 0)
		sys->print("styxseg: export: %r\n");
}

# One direction of the link, chopped into pieces the frame holds.  This
# is os/inferno/init/armv7mstyx.b's up() with the radio replaced by a
# pipe and nothing else changed: the question is whether the chopping
# and the reassembly are sound, so the chopping has to be the same.
chop(dir: string, src, dst: ref Sys->FD, budget: int)
{
	b := array[8192] of byte;
	tot := 0;
	for(;;){
		n := sys->read(src, b, len b);
		if(n <= 0)
			return;
		tot += n;
		if(debug)
			sys->print("styxseg: %s %d (%d so far)\n",
				dir, n, tot);
		for(i := 0; i < n; ){
			m := n - i;
			if(m > budget)
				m = budget;
			if(sys->write(dst, b[i:i+m], m) != m){
				sys->print("styxseg: %s write: %r\n", dir);
				return;
			}
			i += m;
		}
	}
}

# A whole file, however many reads it takes.  slurp in the station init
# did ONE read and returned what it got, which is right for a device
# file inside one message and wrong in general; here the point is to
# have the bytes, so it reads to end of file.
slurp(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	d := array[0] of byte;
	b := array[4096] of byte;
	for(;;){
		n := sys->read(fd, b, len b);
		if(n < 0)
			return nil;
		if(n == 0)
			break;
		nd := array[len d + n] of byte;
		nd[0:] = d;
		nd[len d:] = b[0:n];
		d = nd;
	}
	return d;
}

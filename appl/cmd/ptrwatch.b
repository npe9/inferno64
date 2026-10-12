implement Ptrwatch;

#
# ptrwatch - print pointer events for a bounded time, then say how many
#
# WHY THIS EXISTS.  doc/usb-split-plan.ms.  On the Pi 3B the only
# reader of /dev/pointer is mousecheck() in the board's init, and it
# gives up after twenty-five seconds and reports USB-MOUSE-NONE -- so
# for the rest of the board's uptime nothing is reading the queue, and a
# mouse moved by hand at any later moment produces events that nobody
# sees.  usbdwc.c's periodicdata counter says whether the CONTROLLER
# received a report; this says whether one came out the other end, at
# /dev/pointer, decoded.
#
# It is bounded on purpose.  tools/jtag/boardrun runs one command and
# waits for it, so `cat /dev/pointer' wedges the poller -- a cat that
# never returns is a board that answers nothing afterwards, and that
# class of self-inflicted wedge has cost this tree a board cycle before.
#
# DEVPOINTER ALLOWS ONE READER AND SAYS SO, which this reports as its
# own outcome rather than as a failure to find events: `device or
# object already in use' means something else holds the slot -- the
# init's own check if it is still inside its window, or a window
# manager -- and the right answer then is to say who, not to conclude
# the mouse is dead.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Ptrwatch: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Event: adt {
	line:	string;
};

init(nil: ref Draw->Context, argv: list of string)
{
	secs := 10;
	maxev := 20;

	sys = load Sys Sys->PATH;
	argv = tl argv;
	while(argv != nil){
		case hd argv {
		"-t" =>
			if(tl argv == nil)
				usage();
			argv = tl argv;
			secs = int hd argv;
		"-n" =>
			if(tl argv == nil)
				usage();
			argv = tl argv;
			maxev = int hd argv;
		* =>
			usage();
		}
		argv = tl argv;
	}
	if(secs <= 0 || maxev <= 0)
		usage();

	fd := sys->open("/dev/pointer", Sys->OREAD);
	if(fd == nil){
		#
		# Distinguish the two reasons, because they ask for
		# different next steps and the message is the only place
		# the difference shows.
		#
		err := sys->sprint("%r");
		if(len err >= 6 && err[len err-6:] == "in use")
			sys->print("PTRWATCH-INUSE /dev/pointer: %s\n", err);
		else
			sys->print("PTRWATCH-FAIL /dev/pointer: %s\n", err);
		return;
	}

	#
	# The read has to happen in its own process because a read on
	# /dev/pointer blocks until an event and there is no timeout on
	# it.  The timer process closes the clock channel after `secs',
	# and the alt below takes whichever arrives first.
	#
	evc := chan of string;
	tick := chan of int;
	spawn reader(fd, evc);
	spawn timer(secs, tick);

	n := 0;
	deadline := 0;
	while(n < maxev && !deadline){
		alt {
		line := <-evc =>
			if(line == nil){
				#
				# The reader stopped.  Not a timeout and not
				# a success: say so, because a reader that
				# died would otherwise look exactly like a
				# mouse that never moved.
				#
				sys->print("PTRWATCH-READFAIL after %d event(s)\n", n);
				return;
			}
			n++;
			sys->print("ptrwatch %d: %s\n", n, line);
		<-tick =>
			deadline = 1;
		}
	}

	#
	# The verdict names the number, and the number is the evidence.
	# `PTRWATCH-OK' with no count would be the same mistake
	# drawink(1) made: a line that cannot be told from a line printed
	# by a test that checked nothing.
	#
	if(n > 0)
		sys->print("PTRWATCH-OK %d event(s) in %d s from /dev/pointer\n",
			n, secs);
	else
		sys->print("PTRWATCH-NONE no events in %d s -- the queue was"
			+ " empty, which with a mouse attached means nobody"
			+ " moved it\n", secs);
}

reader(fd: ref Sys->FD, evc: chan of string)
{
	buf := array[128] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0){
			evc <-= nil;
			return;
		}
		evc <-= string buf[0:n];
	}
}

timer(secs: int, tick: chan of int)
{
	sys->sleep(secs * 1000);
	tick <-= 1;
}

usage()
{
	sys->fprint(sys->fildes(2), "usage: ptrwatch [-t secs] [-n events]\n");
	raise "fail:usage";
}

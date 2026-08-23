implement Command;

#
# Record what the system received on /dev/keyboard, with times.
#
# This exists so that an input recording can be checked against something read
# in the process rather than against a screenshot. A window that looks right
# proves less than a log of exactly which keys arrived and when, and it cannot
# be compared automatically between a recorded run and a replayed one.
#
# Keys reach /dev/keyboard through gkbdputc, which is where emu records and
# replays them, so this sees precisely what a replay injected.
#
include "sys.m";
	sys: Sys;
	sprint, fprint: import sys;
include "draw.m";
	draw: Draw;
	Display: import draw;
include "arg.m";

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	if(arg == nil){
		sys->print("inputtest: load arg: %r\n");
		raise "fail:load";
	}

	out := "/inputtest.log";
	nwant := 0;
	window := 0;
	ptr := 0;
	arg->init(argv);
	arg->setusage("inputtest [-w] [-p] [-o logfile] [-n events]");
	while((o := arg->opt()) != 0)
		case o {
		'o' =>	out = arg->earg();
		'n' =>	nwant = int arg->earg();	# exit after this many keys
		'w' =>	window++;	# allocate a display first, so host keys have somewhere to go
		'p' =>	ptr++;		# read /dev/pointer instead of /dev/keyboard
		* =>	arg->usage();
		}
	if(arg->argv() != nil)
		arg->usage();

	# Without a window the host window driver has no key window and never
	# calls gkbdputc, so a recording of a session with no display on screen
	# is empty for reasons that have nothing to do with the recorder.
	if(window){
		draw = load Draw Draw->PATH;
		if(draw == nil || Display.allocate(nil) == nil){
			sys->print("inputtest: allocate display: %r\n");
			raise "fail:display";
		}
	}

	dev := "/dev/keyboard";
	if(ptr)
		dev = "/dev/pointer";
	kfd := sys->open(dev, Sys->OREAD);
	if(kfd == nil){
		sys->print("inputtest: %s: %r\n", dev);
		raise "fail:open";
	}
	lfd := sys->create(out, Sys->OWRITE, 8r666);
	if(lfd == nil){
		sys->print("inputtest: %s: %r\n", out);
		raise "fail:create";
	}

	t0 := -1;
	n := 0;
	buf := array[64] of byte;
	for(;;){
		nr := sys->read(kfd, buf, len buf);
		if(nr <= 0)
			break;
		if(ptr){
			# "m<x> <y> <buttons> <msec>": the device's own msec is
			# what a replay must carry through, since consumers
			# compare its deltas to detect a double click
			fprint(lfd, "%s\n", string buf[0:nr]);
			n++;
			if(nwant > 0 && n >= nwant)
				break;
			continue;
		}
		# a read can carry more than one rune
		s := string buf[0:nr];
		for(i := 0; i < len s; i++){
			ms := sys->millisec();
			if(t0 < 0)
				t0 = ms;
			# the rune as a number, so non-printing keys are visible
			# too - this is the whole reason the tk key-release bug
			# was invisible to "type into a window and look"
			fprint(lfd, "%6d %d\n", ms - t0, int s[i]);
			n++;
		}
		if(nwant > 0 && n >= nwant)
			break;
	}
	fprint(lfd, "end %d\n", n);
}

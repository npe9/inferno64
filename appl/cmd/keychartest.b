implement Keychartest;

# Check that a key event's characters reach Inferno whole.
#
# The platform hands over UTF-16, so anything above the basic plane is a
# surrogate pair; taking one unit of it delivers half a rune. Nothing in
# the system can produce that on demand - a person has to type it - so
# emu(1) grows INFERNO_KEY_TEST, which pushes a string through the same
# path a key event takes. Writing to /dev/keyboard would go in below the
# platform and test nothing.
#
#	INFERNO_KEY_TEST=$s emu-cocoa /dis/keychartest.dis $s

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display: import draw;

Keychartest: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	argv = tl argv;
	if(argv == nil){
		sys->print("FAIL usage: keychartest 'expected string'\n");
		raise "fail:usage";
	}
	want := hd argv;

	# The platform delivers keys only once there is a window, and emu
	# makes one when something first opens the display.  A program that
	# only reads /dev/keyboard never gets that far, so ask for a display
	# and let the window come up.
	if(draw == nil || Display.allocate(nil) == nil){
		sys->print("FAIL no display: %r\n");
		raise "fail:display";
	}

	fd := sys->open("/dev/keyboard", Sys->OREAD);
	if(fd == nil){
		sys->print("FAIL open /dev/keyboard: %r\n");
		raise "fail:keyboard";
	}

	# A read of /dev/keyboard blocks, so a run that delivers fewer runes
	# than were asked for would wait for ever - and a test that hangs is
	# worse than one that fails, because it reports nothing at all. That
	# is what the first version of this did when the delivery was broken.
	#
	# Writing to /dev/keyboard puts runes in the same queue the platform
	# feeds, so a watchdog can end the wait with a rune that cannot occur
	# in a person's text. It goes in below the code under test and so
	# tells us nothing about it - which is the point: it is a timer, not
	# a probe.
	Sentinel: con 16r04;		# EOT
	spawn watchdog();

	got := "";
	b := array[256] of byte;
	for(;;){
		n := sys->read(fd, b, len b);
		if(n <= 0)
			break;
		chunk := string b[0:n];
		stop := 0;
		for(k := 0; k < len chunk; k++)
			if(chunk[k] == Sentinel){
				chunk = chunk[0:k];
				stop = 1;
				break;
			}
		got += chunk;
		if(stop || len got >= len want)
			break;
	}

	sys->print("     wanted %d runes, got %d\n", len want, len got);
	for(j := 0; j < len want && j < len got; j++)
		if(got[j] != want[j])
			sys->print("     rune %d: wanted 16r%x, got 16r%x\n",
				j, want[j], got[j]);
	if(got == want)
		sys->print("ok   every character arrived whole, %d of them\n", len got);
	else{
		sys->print("FAIL characters were mangled: wanted %q, got %q\n", want, got);
		raise "fail:keychartest";
	}
}

# End the wait, however the delivery went.
watchdog()
{
	sys->sleep(4000);
	fd := sys->open("/dev/keyboard", Sys->OWRITE);
	if(fd != nil){
		b := array of byte "\u0004";
		sys->write(fd, b, len b);
	}
}

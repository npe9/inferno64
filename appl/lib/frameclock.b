implement Frameclock;

# A frame clock that keeps time, for the TempleOS ports and anything else
# that draws every frame.
#
# What was there before was seventy copies of
#
#	timer(c: chan of int, ms: int)
#	{
#		for(;;){
#			sys->sleep(ms);
#			c <-= 1;
#		}
#	}
#
# which is wrong twice over.  Sleeping for a length of time is not the
# same as keeping to a rate: the time a frame's work takes is added to
# the sleep rather than taken out of it, so the period is always longer
# than asked and gets longer the more the frame does.  And this host's
# sleep overshoots on its own account - measured, nanosleep(16ms) takes
# 18.7ms here, a fifth over, and it is a fifth over at every length from
# 1ms to 33ms - so even a port that does nothing at all gets 53 frames a
# second when it asks for 60.
#
# The fix is not a better sleep.  It is to sleep to an absolute deadline:
# ask for the time between now and when the next frame is due, and the
# overshoot is subtracted from the following ask rather than added to the
# period.  With the very same nanosleep that gives 18.70ms a frame when
# it is asked for 16, deadline pacing gives 16.699ms - 59.9 frames a
# second.
#
# A slow consumer is not a reason to fall behind for ever: if a frame's
# work runs past the next deadline the missed frames are dropped and the
# clock starts again from now, so a port that stalls for a second does
# not then get a second's worth of ticks in a burst.

include "sys.m";
	sys: Sys;

include "frameclock.m";

# All of this is in microseconds.  A sixtieth of a second is 16667 and
# not 16, and a clock that cannot say so loses a frame every three.
period := 0;
frames := 0;
elapsed := 0;
watching := -1;

init()
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
}

ticker(c: chan of int, hz: int)
{
	if(hz <= 0)
		hz = FPS;
	run(c, 1000000/hz);
}

tickms(c: chan of int, ms: int)
{
	if(ms <= 0)
		ms = 1000/FPS;
	run(c, ms*1000);
}

run(c: chan of int, us: int)
{
	init();
	period = us;
	frames = 0;
	elapsed = 0;
	if(watching < 0){
		watching = 0;
		fd := sys->open("/env/INFERNO_FPS", Sys->OREAD);
		if(fd != nil)
			watching = 1;
	}
	start := sys->millisec();
	last := start;
	# The deadline is carried in microseconds against the start, so the
	# rounding of one frame does not accumulate into the next.
	due := 0;
	for(;;){
		due += period;
		d := start + due/1000 - sys->millisec();
		if(d > 0)
			sys->sleep(d);
		now := sys->millisec();
		if(now - start > due/1000 + period/1000){
			# A frame's work ran past the next deadline.  Drop
			# what was missed rather than firing a burst.
			due = (now - start)*1000;
		}
		c <-= now - last;
		last = now;
		frames++;
		elapsed = sys->millisec() - start;
		# Free measurement: a port that has a frame clock can be
		# asked what it is achieving without a line of its own.
		if(watching && frames % (2000000/period) == 0)
			report("frameclock");
	}
}

rate(): (int, int)
{
	if(frames == 0)
		return (0, 0);
	return (frames, elapsed*1000/frames);
}

report(who: string)
{
	init();
	(n, us) := rate();
	if(n == 0 || us == 0){
		sys->print("%s: no frames\n", who);
		return;
	}
	# Two decimals without floating point: 1000000*100/us is hundredths
	# of a frame a second.
	h := 100000000/us;
	sys->print("%s: %d.%.2d fps over %d frames, %d.%.3d ms a frame (asked %d.%.3d)\n",
		who, h/100, h%100, n, us/1000, us%1000,
		period/1000, period%1000);
}

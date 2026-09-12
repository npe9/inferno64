Frameclock: module
{
	PATH:	con "/dis/lib/frameclock.dis";

	init:	fn();

	# Tick on c at hz frames a second, or every ms milliseconds.  Both
	# pace to an absolute deadline rather than sleeping a fixed length
	# of time, which is the whole point: this host's sleep overshoots
	# what it is asked for by about a fifth, so sleeping 16ms a frame
	# gives 53 frames a second and not 60.
	#
	# The value sent is the milliseconds since the previous tick, so a
	# caller whose simulation has a timestep of its own can run the
	# right number of substeps for the time that actually passed.
	# A caller that ignores it sees the old chan of int.
	#
	# hz of 0 means "whenever the display wants one", read off
	# /dev/draw/vsync: the rate is then the refresh rate by
	# construction, and dynamic for free - a frame that takes longer
	# than a refresh lands on the next one instead of putting the whole
	# schedule out of phase.  Two clocks that are both nearly 60Hz are
	# what choppy animation is made of; this is one clock.  It falls
	# back to FPS off the timer where there is no such file, and stalls
	# while the window is not being displayed, which is the point.
	#
	# A caller whose simulation advances a fixed step per tick must NOT
	# ask for 0 without also reading the milliseconds the tick carries:
	# the display is 60Hz here and need not be anywhere else, and such
	# a port would then run at whatever rate the screen happens to be.
	ticker:	fn(c: chan of int, hz: int);
	tickms:	fn(c: chan of int, ms: int);

	# Is display pacing available?  So a caller can say so on screen
	# rather than wondering which it got.
	vsyncok:	fn(): int;

	FPS:	con 60;

	# Frames delivered and the mean period in microseconds, since the
	# ticker started.  A tick is not delivered until the consumer takes
	# it, so this is the rate the caller actually drew at, not the rate
	# it asked for.
	rate:	fn(): (int, int);

	# Print that, as ports do at exit, when /env/INFERNO_FPS is set.
	# Says nothing at all when it is not.
	report:	fn(who: string);

	# --- how smooth, rather than how fast ---
	#
	# A mean frame time says nothing about smoothness: sixty frames of
	# 2ms and one of 200ms average out to something that looks fine and
	# reads as a visible lurch.  What matters is the spread and the
	# tail, so this records every frame and reports the distribution.
	#
	# now() is microseconds, off /dev/time, because millisec() cannot
	# see a 2ms frame at all - it can only say 2 or 3.

	now:	fn(): big;

	Jitter: adt {
		us:	array of int;	# per-frame microseconds, in order
		n:	int;		# how many recorded
		prev:	big;		# the last mark
		over:	int;		# frames past the budget

		# Once a frame.  The first call only starts the clock.
		mark:	fn(j: self ref Jitter);
		# n, mean, min, median, p90, p99, max - all microseconds.
		stats:	fn(j: self ref Jitter): (int, int, int, int, int, int, int);
		# The distribution, a histogram, and how many frames were
		# slower than budget microseconds (0 for a sixtieth).
		report:	fn(j: self ref Jitter, who: string, budget: int);
	};

	jitter:	fn(most: int): ref Jitter;
};

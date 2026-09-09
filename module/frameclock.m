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
	ticker:	fn(c: chan of int, hz: int);
	tickms:	fn(c: chan of int, ms: int);

	FPS:	con 60;

	# Frames delivered and the mean period in microseconds, since the
	# ticker started.  A tick is not delivered until the consumer takes
	# it, so this is the rate the caller actually drew at, not the rate
	# it asked for.
	rate:	fn(): (int, int);

	# Print that, as ports do at exit, when /env/INFERNO_FPS is set.
	# Says nothing at all when it is not.
	report:	fn(who: string);
};

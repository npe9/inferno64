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

VSYNC: con "/dev/draw/vsync";

# Is the display willing to say when it wants a frame?
vsyncok(): int
{
	init();
	fd := sys->open(VSYNC, Sys->OREAD);
	return fd != nil;
}

ticker(c: chan of int, hz: int)
{
	if(hz == 0){
		init();
		fd := sys->open(VSYNC, Sys->OREAD);
		if(fd != nil){
			vsyncrun(c, fd);
			return;
		}
		# No display to ask - a memory image, a host without the
		# file, an emu built before it.  The timer is the fallback,
		# not an error.
		hz = FPS;
	}
	if(hz < 0)
		hz = FPS;
	run(c, 1000000/hz);
}

#
# One tick per display refresh.  No deadline arithmetic and no sleep: the
# read blocks until the display asks, so the period is the refresh period
# and a frame that overruns simply misses one rather than shifting the
# phase of every frame after it.
#
#
# One tick per display refresh - with a keep-alive, because the display is
# allowed to stop asking.  CADisplayLink stops when its window is not being
# displayed, and that includes states a program never sees and did not ask
# for: measured here, a run whose window never came to the front got zero
# refreshes in 25 seconds, and a caller blocked on the read simply stopped.
# So a timer runs alongside at the same nominal rate and delivers a tick
# only when the display did not.  While the display is asking it costs a
# channel operation a frame and changes nothing; when it goes quiet the
# program keeps running, slightly less smoothly, instead of freezing.
#
vsyncrun(c: chan of int, fd: ref Sys->FD)
{
	frames = 0;
	elapsed = 0;
	period = 1000000/FPS;
	if(watching < 0){
		watching = 0;
		wfd := sys->open("/env/INFERNO_FPS", Sys->OREAD);
		if(wfd != nil)
			watching = 1;
	}
	vc := chan of int;
	spawn vreader(fd, vc);
	tk := chan of int;
	spawn keepalive(tk, 1000/FPS);
	start := sys->millisec();
	last := start;
	asked := 0;	# the display asked since the last keep-alive
	for(;;){
		deliver := 0;
		alt{
		<-vc =>
			asked = 1;
			deliver = 1;
		<-tk =>
			# Only when the display did not: while it is doing its
			# job this arm resets the flag and delivers nothing.
			if(asked)
				asked = 0;
			else
				deliver = 1;
		}
		if(!deliver)
			continue;
		now := sys->millisec();
		c <-= now - last;
		last = now;
		frames++;
		elapsed = sys->millisec() - start;
		if(frames > 0 && elapsed > 0)
			period = (elapsed*1000)/frames;
		if(watching && frames % (2*FPS) == 0)
			report("frameclock");
	}
}

# Blocks in the read so the loop above can select on it.
vreader(fd: ref Sys->FD, c: chan of int)
{
	buf := array[32] of byte;
	for(;;){
		if(sys->read(fd, buf, len buf) <= 0)
			return;
		c <-= 1;
	}
}

keepalive(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
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

# ------------------------------------------------------- how smooth
#
# Kept apart from the pacing above on purpose: a caller that wants to
# know what its frames cost usually does NOT want them paced, because
# pacing is what hides the answer.  gorge -b and strider -b run flat out
# and measure; the play loops pace and could measure as well.

timefd: ref Sys->FD;

now(): big
{
	init();
	if(timefd == nil){
		timefd = sys->open("/dev/time", Sys->OREAD);
		if(timefd == nil)
			return big 0;
	}
	b := array[32] of byte;
	sys->seek(timefd, big 0, Sys->SEEKSTART);
	n := sys->read(timefd, b, len b);
	if(n <= 0)
		return big 0;
	s := string b[0:n];
	# the file is microseconds since the epoch, and nothing else
	v := big 0;
	for(i := 0; i < len s; i++){
		if(s[i] < '0' || s[i] > '9')
			break;
		v = v*big 10 + big (s[i] - '0');
	}
	return v;
}

jitter(most: int): ref Jitter
{
	if(most < 1)
		most = 1;
	return ref Jitter(array[most] of int, 0, big 0, 0);
}

Jitter.mark(j: self ref Jitter)
{
	t := now();
	if(j.prev != big 0 && j.n < len j.us)
		j.us[j.n++] = int (t - j.prev);
	j.prev = t;
}

Jitter.stats(j: self ref Jitter): (int, int, int, int, int, int, int)
{
	if(j.n == 0)
		return (0, 0, 0, 0, 0, 0, 0);
	a := array[j.n] of int;
	a[0:] = j.us[0:j.n];
	# insertion sort: this runs once, at the end, over a few hundred
	for(i := 1; i < j.n; i++){
		v := a[i];
		k := i - 1;
		while(k >= 0 && a[k] > v){
			a[k+1] = a[k];
			k--;
		}
		a[k+1] = v;
	}
	sum := 0;
	for(i = 0; i < j.n; i++)
		sum += a[i];
	return (j.n, sum/j.n, a[0], a[j.n/2], a[(j.n*90)/100],
		a[(j.n*99)/100], a[j.n-1]);
}

Jitter.report(j: self ref Jitter, who: string, budget: int)
{
	init();
	(n, mean, lo, p50, p90, p99, hi) := j.stats();
	if(n == 0){
		sys->print("%s: no frames timed\n", who);
		return;
	}
	if(budget <= 0)
		budget = 1000000/FPS;
	over := 0;
	for(i := 0; i < j.n; i++)
		if(j.us[i] > budget)
			over++;
	sys->print("%s: %d frames  mean %d  min %d  median %d  p90 %d  p99 %d  max %d us\n",
		who, n, mean, lo, p50, p90, p99, hi);
	sys->print("%s: %d past %d us (%d%%), worst is %d%% of budget\n",
		who, over, budget, over*100/n, hi*100/budget);
	# A histogram, because a tail is easier to see than to read.  Ten
	# buckets from the fastest frame to the slowest.
	if(hi > lo){
		bk := array[10] of int;
		for(i = 0; i < j.n; i++){
			b := (j.us[i] - lo) * 10 / (hi - lo);
			if(b > 9)
				b = 9;
			bk[b]++;
		}
		most := 1;
		for(i = 0; i < 10; i++)
			if(bk[i] > most)
				most = bk[i];
		for(i = 0; i < 10; i++){
			bar := "";
			w := bk[i] * 40 / most;
			for(k := 0; k < w; k++)
				bar[len bar] = '#';
			sys->print("%s: %7d us %-40s %d\n", who,
				lo + (hi-lo)*i/10, bar, bk[i]);
		}
	}
}

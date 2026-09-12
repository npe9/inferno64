implement Sleeptest;

#
# How accurate is sys->sleep?  Everything timed in this system is built on
# it - frameclock(2)'s ticker, and so every game's frame pacing - and a
# frame that is asked for every 16 ms and arrives somewhere between 10 and
# 25 looks exactly like choppy animation however correct the renderer is.
#
include "sys.m";
	sys: Sys;
include "draw.m";
include "frameclock.m";
	fclock: Frameclock;

Sleeptest: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	fclock = load Frameclock Frameclock->PATH;
	fclock->init();
	ms := 16;
	n := 200;
	if(tl argv != nil)
		ms = int hd tl argv;
	d := array[n] of int;
	for(i := 0; i < n; i++){
		t0 := fclock->now();
		sys->sleep(ms);
		d[i] = int (fclock->now() - t0);
	}
	# insertion sort, n is small
	for(i = 1; i < n; i++){
		t := d[i];
		for(j := i; j > 0 && d[j-1] > t; j--)
			d[j] = d[j-1];
		d[j] = t;
	}
	sum := 0;
	for(i = 0; i < n; i++)
		sum += d[i];
	sys->print("sleep(%d): n=%d mean %d min %d median %d p90 %d p99 %d max %d us\n",
		ms, n, sum/n, d[0], d[n/2], d[(n*9)/10], d[(n*99)/100], d[n-1]);
}

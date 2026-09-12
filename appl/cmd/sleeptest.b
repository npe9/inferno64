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
	vs := 0;
	if(tl argv != nil){
		a := hd tl argv;
		if(a == "vsync")
			vs = 1;
		else
			ms = int a;
	}
	# The same question asked of the display instead of the clock: how
	# far apart are the moments it asks for a frame?
	fd: ref Sys->FD;
	if(vs){
		fd = sys->open("/dev/draw/vsync", Sys->OREAD);
		if(fd == nil){
			sys->print("sleeptest: /dev/draw/vsync: %r\n");
			return;
		}
		n = 120;
	}
	d := array[n] of int;
	buf := array[32] of byte;
	for(i := 0; i < n; i++){
		t0 := fclock->now();
		if(vs){
			if(sys->read(fd, buf, len buf) <= 0){
				sys->print("sleeptest: vsync read: %r\n");
				return;
			}
		}else
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
	what := sys->sprint("sleep(%d)", ms);
	if(vs)
		what = "vsync";
	sys->print("%s: n=%d mean %d min %d median %d p90 %d p99 %d max %d us\n",
		what, n, sum/n, d[0], d[n/2], d[(n*9)/10], d[(n*99)/100], d[n-1]);
}

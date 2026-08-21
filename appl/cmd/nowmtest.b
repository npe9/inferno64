implement Command;

#
# Regression test for the no-window-manager fallback: an application
# started without a wm gets its Draw->Context from
# wmclient->makedrawcontext(), which returns a Context whose wm channel
# is nil.  This walks the whole path a real Tk application takes in
# that state (see e.g. dreammachines/tutor.b, which does exactly
# "if(ctxt == nil) ctxt = wmclient->makedrawcontext()") and checks that
# each stage returns rather than blocking, then proves that drawing
# actually reached the toplevel's image.
#
# The last check is the point.  Every earlier stage returning only
# shows nothing deadlocked; it does not show anything was drawn.
# Reading the toplevel image back and counting non-zero bytes does,
# and unlike a screenshot it depends on nothing outside the process -
# no window server, no accessibility API, no unlocked screen.
#

include "sys.m";
	sys: Sys;
	print: import sys;
include "draw.m";
	draw: Draw;
	Image, Rect, Point: import draw;
include "tk.m";
	tk: Tk;
include "tkclient.m";
	tkclient: Tkclient;
include "wmclient.m";
	wmclient: Wmclient;

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Waitms: con 3000;

timeout(sync: chan of int)
{
	sys->sleep(Waitms);
	sync <-= 1;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	if(draw == nil || tk == nil || tkclient == nil || wmclient == nil){
		print("FAIL: cannot load modules: %r\n");
		return;
	}
	ok := 1;
	# Tk brings up helper processes that would otherwise keep the
	# emulator alive after the test has finished; run in our own group
	# so we can take them down and actually exit.
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();

	# Ignore any context we were given: the point is the fallback.
	ctxt := wmclient->makedrawcontext();
	if(ctxt == nil || ctxt.display == nil){
		print("FAIL: makedrawcontext gave no display (needs a graphical backend)\n");
		return;
	}
	if(ctxt.wm != nil)
		print("note: ctxt.wm is not nil - a wm is present, so this is not testing the fallback\n");
	print("makedrawcontext: display ok, wm nil = %d\n", ctxt.wm == nil);

	tkclient->init();
	(top, wmctl) := tkclient->toplevel(ctxt, "", "nowmtest", Tkclient->Appl);
	if(top == nil){
		print("FAIL: toplevel returned nil\n");
		return;
	}
	print("toplevel: ok\n");

	tkclient->onscreen(top, nil);
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);
	print("onscreen + startinput: returned\n");

	tk->cmd(top, "button .b -text {hello}");
	tk->cmd(top, "pack .b");
	tk->cmd(top, "update");
	tk->cmd(top, ". configure -width 200 -height 100");
	tk->cmd(top, "update");
	print("widget create/pack/update/resize: returned\n");

	# Did anything actually get drawn?
	img := top.image;
	if(img == nil){
		print("FAIL: toplevel has no image\n");
		ok = 0;
	} else {
		nb := img.r.dy() * draw->bytesperline(img.r, img.depth);
		buf := array[nb] of byte;
		n := img.readpixels(img.r, buf);
		if(n != nb){
			print("FAIL: readpixels returned %d, wanted %d\n", n, nb);
			ok = 0;
		}
		nz := 0;
		for(k := 0; k < nb; k++)
			if(buf[k] != byte 0)
				nz++;
		print("toplevel image %dx%d depth %d: %d/%d non-zero bytes\n",
			img.r.dx(), img.r.dy(), img.depth, nz, nb);
		if(nz == 0){
			print("FAIL: nothing was drawn - image is entirely zero\n");
			ok = 0;
		}
	}

	# With no wm nothing should arrive on the control channel; make
	# sure reading it is not required for progress either.
	sync := chan of int;
	spawn timeout(sync);
	alt {
	c := <-wmctl =>
		print("wmctl: got %q (unexpected with no wm, but not a failure)\n", c);
	<-sync =>
		print("wmctl: quiet for %dms, as expected with no wm\n", Waitms);
	}

	if(ok)
		print("PASS\n");
	else
		print("SOME CHECKS FAILED\n");
	killgrp(sys->pctl(0, nil));
}

killgrp(pid: int)
{
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
}

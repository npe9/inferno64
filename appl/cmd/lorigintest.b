implement Lorigintest;

#
# Moving a window must leave nothing of it behind, and must not wipe what
# was underneath it.  Both halves are checked, because the fix for the
# first can easily cause the second.
#
# Entirely offscreen: a Screen allocated over an ordinary image, never the
# display's own screen, so readpixels works and nothing here depends on a
# window system, on Tk, or on the Metal upload path.
#

include "sys.m";
include "draw.m";

sys: Sys;
draw: Draw;
Display, Image, Screen, Rect, Point: import draw;

Lorigintest: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

W: con 200;
H: con 200;

base: ref Image;
ok := 0;
fail := 0;

report(good: int, what: string)
{
	if(good){
		ok++;
		sys->print("OK   %s\n", what);
	}else{
		fail++;
		sys->print("FAIL %s\n", what);
	}
}

#
# How many pixels of r are NOT the given colour.
#
# RGB24 readpixels hands back B,G,R.  Probing one pixel of each settled
# it: the red background reads 0 0 255 and a blue window reads 255 0 0.
# Getting this backwards inverts every check here, and did.
#
notcol(r: Rect, b, g, rr: int): int
{
	n := r.dx()*r.dy();
	if(n <= 0)
		return -1;
	buf := array[n*3] of byte;
	base.readpixels(r, buf);
	bad := 0;
	for(i := 0; i < n*3; i += 3)
		if(int buf[i] != b || int buf[i+1] != g || int buf[i+2] != rr)
			bad++;
	return bad;
}

Red, Green, Blue: con iota;

allof(r: Rect, which: int, what: string)
{
	bad := 0;
	case which {
	Red =>		bad = notcol(r, 0, 0, 255);
	Green =>	bad = notcol(r, 0, 255, 0);
	Blue =>		bad = notcol(r, 255, 0, 0);
	}
	if(bad == 0)
		report(1, what);
	else
		report(0, sys->sprint("%s (%d of %d pixels wrong)",
			what, bad, r.dx()*r.dy()));
}

disp: ref Display;

# a fresh offscreen screen, so one scenario cannot colour the next
fresh(): ref Screen
{
	base = disp.newimage(Rect((0,0),(W,H)), draw->RGB24, 0, Draw->Red);
	red := disp.color(Draw->Red);
	if(base == nil || red == nil)
		return nil;
	return Screen.allocate(base, red, 0);
}

# One window, nothing behind it but the screen's fill.  This is the case
# ldelete.c's comment does not enumerate: memltorear() passes no layer, so
# memlexpose() repaints nothing, and without a restore the old rectangle
# keeps the window's pixels.
alone()
{
	scr := fresh();
	if(scr == nil){
		report(0, "alone: no screen");
		return;
	}
	old := Rect((10,10),(60,60));
	w := scr.newwindow(old, Draw->Refbackup, Draw->Blue);
	if(w == nil){
		report(0, "alone: no window");
		return;
	}
	w.flush(Draw->Flushnow);
	allof(old, Blue, "a lone window covers its own rectangle");

	new := Rect((120,120),(170,170));
	if(w.origin(w.r.min, new.min) < 0){
		report(0, "alone: origin failed");
		return;
	}
	w.flush(Draw->Flushnow);
	allof(new, Blue, "and after a move it is at the new place");
	allof(old, Red, "and leaves NO afterimage on the background");
}

# A front window overlapping one behind it.  The restore must reveal the
# one behind rather than painting the screen fill over it.
over()
{
	scr := fresh();
	if(scr == nil){
		report(0, "over: no screen");
		return;
	}
	brect := Rect((40,40),(90,90));
	b := scr.newwindow(brect, Draw->Refbackup, Draw->Green);
	arect := Rect((10,10),(60,60));
	a := scr.newwindow(arect, Draw->Refbackup, Draw->Blue);
	if(a == nil || b == nil){
		report(0, "over: no windows");
		return;
	}
	a.flush(Draw->Flushnow);
	allof(arect, Blue, "the front window covers its own rectangle");
	allof(Rect((60,60),(90,90)), Green,
		"the one behind shows where the front one does not reach");

	newr := Rect((120,120),(170,170));
	if(a.origin(a.r.min, newr.min) < 0){
		report(0, "over: origin failed");
		return;
	}
	a.flush(Draw->Flushnow);
	allof(newr, Blue, "after a move the front window is at its new place");
	allof(Rect((10,10),(40,40)), Red,
		"the background it vacated is background again");
	allof(Rect((40,40),(60,60)), Green,
		"and the window underneath is revealed, NOT wiped");
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	if(draw == nil){
		sys->print("lorigintest: no draw module\n");
		return;
	}
	disp = Display.allocate(nil);
	if(disp == nil){
		sys->print("lorigintest: no display\n");
		return;
	}
	alone();
	over();
	sys->print("lorigintest: %d ok, %d fail\n", ok, fail);
}

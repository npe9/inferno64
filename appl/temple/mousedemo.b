implement Mousedemo;

# TempleOS Demo/Graphics/MouseDemo.HC — the whole program is
#
#	"Press left mouse bttn to exit.\n";
#	while (!ms.lb) { GrPlot(,ms.pos.x,ms.pos.y); Refresh; }
#	DCFill;
#
# so it plots one pixel wherever the pointer is, over and over, until the
# left button is pressed, then clears.  Plotting in a tight loop and not
# only on movement is the point: hold the mouse still and the pixel is
# simply redrawn, move it and you get a trail with no interpolation, so a
# fast sweep leaves a dotted line rather than a stroke.
#
# GrPlot with no DC uses gr.dc, whose colour is BLACK, on the task's
# default WHITE background (Kernel/KTask.HC: WHITE<<4+BLUE).

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;
include "grpalette.m";
	grpal: Grpalette;
include "frameclock.m";
	fclock: Frameclock;

Mousedemo: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# The port's own simulation step, in milliseconds.  The frame clock
# runs at 60fps and this many milliseconds of simulation are run for
# each frame's worth of real time, so the picture is smooth and the
# simulation keeps the speed it was written for.
FCSTEP: con 10;
fcacc := 0;

win: ref Window;
font: ref Font;
black, white, blue: ref Image;
mx, my: int;
have_ms := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	fclock = load Frameclock Frameclock->PATH;
	fclock->init();
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS MouseDemo", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	black = d.color(grpal->value(Grpalette->BLACK));
	white = d.color(grpal->value(Grpalette->WHITE));
	blue = d.color(grpal->value(Grpalette->BLUE));

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	clear();

	ticks := chan of int;
	spawn fclock->ticker(ticks, 60);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		img := win.image;
		if(img != nil){
			mx = p.xy.x - img.r.min.x;
			my = p.xy.y - img.r.min.y;
			have_ms = 1;
		}
		if(p.buttons & 1){		# ms.lb ends it
			clear();
			exit;
		}
	dtms := <-ticks =>
		fcacc += dtms;
		for(fcn := 0; fcacc >= FCSTEP && fcn < 4; fcn++){
			plot();
			fcacc -= FCSTEP;
		}
	}
}

# GrPlot(,ms.pos.x,ms.pos.y) then Refresh, once round the loop
plot()
{
	img := win.image;
	if(img == nil || !have_ms)
		return;
	o := img.r.min;
	img.draw(Rect((o.x+mx, o.y+my), (o.x+mx+1, o.y+my+1)), black, nil, Point(0, 0));
	img.flush(Draw->Flushnow);
}

# DCFill, plus the line the original prints before the loop
clear()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, white, nil, Point(0, 0));
	if(font != nil)
		img.text(img.r.min, blue, Point(0, 0), font,
			"Press left mouse bttn to exit.");
	img.flush(Draw->Flushnow);
}


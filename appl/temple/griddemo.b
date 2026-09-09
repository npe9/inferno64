implement Griddemo;

# TempleOS Demo/Graphics/Grid.HC — the mouse-grid demo.
#
# It is MouseDemo with two changes, and those two changes are the whole
# point: ms_grid.snap is set with ms_grid.x = ms_grid.y = GRID (5), so the
# pointer position the program sees is snapped to a five-pixel lattice,
# and gr.fp_draw_ms is replaced by a DrawMyMs that draws a GRIDxGRID
# GrRect instead of the usual arrow — with DCF_TRANSFORMATION and
# DCF_SYMMETRY cleared, so no ambient transform reaches the cursor.
# Left button exits and DCFill clears, as before.
#
# The snapping is what shows: plotted points land only on multiples of
# five, so a slow sweep leaves a dotted lattice rather than a line.

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

Griddemo: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# The port's own simulation step, in milliseconds.  The frame clock
# runs at 60fps and this many milliseconds of simulation are run for
# each frame's worth of real time, so the picture is smooth and the
# simulation keeps the speed it was written for.
FCSTEP: con 10;
fcacc := 0;

GRID: con 5;

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

	win = wmclient->window(ctxt, "TempleOS GridDemo", Wmclient->Appl);
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
			# ms_grid.snap with ms_grid.x = ms_grid.y = GRID
			mx = snap(p.xy.x - img.r.min.x);
			my = snap(p.xy.y - img.r.min.y);
			have_ms = 1;
		}
		if(p.buttons & 1){
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

snap(v: int): int
{
	return (v + GRID/2) / GRID * GRID;
}

plot()
{
	img := win.image;
	if(img == nil || !have_ms)
		return;
	o := img.r.min;
	img.draw(Rect((o.x+mx, o.y+my), (o.x+mx+1, o.y+my+1)), black, nil, Point(0, 0));
	# DrawMyMs: a GRIDxGRID GrRect where the arrow cursor would be
	r := Rect((o.x+mx, o.y+my), (o.x+mx+GRID, o.y+my+GRID));
	img.line(r.min, Point(r.max.x, r.min.y), Draw->Endsquare, Draw->Endsquare,
		0, black, Point(0, 0));
	img.line(Point(r.max.x, r.min.y), r.max, Draw->Endsquare, Draw->Endsquare,
		0, black, Point(0, 0));
	img.line(r.max, Point(r.min.x, r.max.y), Draw->Endsquare, Draw->Endsquare,
		0, black, Point(0, 0));
	img.line(Point(r.min.x, r.max.y), r.min, Draw->Endsquare, Draw->Endsquare,
		0, black, Point(0, 0));
	img.flush(Draw->Flushnow);
}

clear()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, white, nil, Point(0, 0));
	if(font != nil)
		img.text(img.r.min, blue, Point(0, 0), font,
			sys->sprint("Snapped to a %d pixel grid.  Left mouse bttn to exit.", GRID));
	img.flush(Draw->Flushnow);
}


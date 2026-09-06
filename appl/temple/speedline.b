implement Speedline;

# TempleOS Demo/Graphics/Speedline.HC — "This is a drawing program".
#
# It is a drawing program with one idea in it: the pen is as thick as the
# mouse is fast.  The left-button loop reads MSG_MS_MOVE messages and, for
# every one, sets
#
#	dc->thick = 0.04*ms.speed;
#	GrLine3(dc,x1,y1,0,x2,y2,0);
#
# before shuffling the previous point along, so a slow careful stroke is a
# hairline and a fast flick is a fat one.  Right button is PopUpColor; a
# key press ends it and DCFill clears.
#
# ms.speed is the pointer's speed in pixels per second, which TempleOS
# maintains for exactly this sort of thing; here it is measured from the
# gap between consecutive pointer events.  PopUpColor's list is drawn in
# the window as the sixteen palette entries, since wm(1) has no pop-up
# menu of the TempleOS kind.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "math.m";
	math: Math;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

Speedline: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

SWATCH: con 24;

win: ref Window;
font: ref Font;
ink: array of ref Image;
colour := 0;			# BLACK, as the original starts
picking := 0;

lastx, lasty: int;
lastms: int;
have_last := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS SpeedLine", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");

	# the exact TempleOS 16-color palette, index = TempleOS color
	ink = array[16] of ref Image;
	cols := array[] of {
		int 16r000000FF, int 16r0000AAFF, int 16r00AA00FF, int 16r00AAAAFF,
		int 16rAA0000FF, int 16rAA00AAFF, int 16rAA5500FF, int 16rAAAAAAFF,
		int 16r555555FF, int 16r5555FFFF, int 16r55FF55FF, int 16r55FFFFFF,
		int 16rFF5555FF, int 16rFF55FFFF, int 16rFFFF55FF, int 16rFFFFFFFF
	};
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	clear();

	down := 0;
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	<-win.ctxt.kbd =>
		if(picking)
			picking = 0;
		else{
			clear();		# DCFill, then out
			exit;
		}
		redrawpicker();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		img := win.image;
		if(img == nil)
			continue;
		x := p.xy.x - img.r.min.x;
		y := p.xy.y - img.r.min.y;
		b := p.buttons;
		if(picking){
			if(b == 0 && down){
				c := swatchat(x, y);
				if(c >= 0)
					colour = c;
				picking = 0;
				clear();
			}
			down = b;
			continue;
		}
		if(b == 0 && (down & 4)){	# MSG_MS_R_UP: PopUpColor
			picking = 1;
			redrawpicker();
			down = b;
			continue;
		}
		if(b & 1){
			if(down & 1)
				stroke(img, x, y);
			else{
				lastx = x;
				lasty = y;
				lastms = sys->millisec();
				have_last = 1;
			}
		}else
			have_last = 0;
		down = b;
	}
}

# One MSG_MS_MOVE of the original's inner loop: thick from the speed, a
# line from the previous point, then the previous point moves up.
stroke(img: ref Image, x, y: int)
{
	if(!have_last){
		lastx = x;
		lasty = y;
		lastms = sys->millisec();
		have_last = 1;
		return;
	}
	now := sys->millisec();
	dt := now - lastms;
	if(dt <= 0)
		dt = 1;
	dx := real(x - lastx);
	dy := real(y - lasty);
	speed := math->sqrt(dx*dx + dy*dy) * 1000.0 / real dt;
	thick := int(0.04 * speed);
	if(thick < 0)
		thick = 0;
	if(thick > 40)
		thick = 40;		# dc->thick is not clamped; a window is
	o := img.r.min;
	img.line(Point(o.x+lastx, o.y+lasty), Point(o.x+x, o.y+y),
		Draw->Enddisc, Draw->Enddisc, thick, ink[colour], Point(0, 0));
	img.flush(Draw->Flushnow);
	lastx = x;
	lasty = y;
	lastms = now;
}

# PopUpColor: the sixteen palette entries, click one
redrawpicker()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	for(i := 0; i < 16; i++){
		r := swatchrect(o, i);
		img.draw(r, ink[i], nil, Point(0, 0));
		img.draw(Rect(r.min, Point(r.max.x, r.min.y+1)), ink[0], nil, Point(0,0));
		img.draw(Rect(r.min, Point(r.min.x+1, r.max.y)), ink[0], nil, Point(0,0));
	}
	if(font != nil)
		img.text(Point(o.x, o.y + 2*SWATCH + 4), ink[0], Point(0, 0), font,
			"Pick a color, or any key to cancel.");
	img.flush(Draw->Flushnow);
}

swatchrect(o: Point, i: int): Rect
{
	col := i % 8;
	row := i / 8;
	return Rect((o.x + col*SWATCH, o.y + row*SWATCH),
		(o.x + (col+1)*SWATCH, o.y + (row+1)*SWATCH));
}

swatchat(x, y: int): int
{
	if(x < 0 || y < 0 || x >= 8*SWATCH || y >= 2*SWATCH)
		return -1;
	return (y/SWATCH)*8 + x/SWATCH;
}

clear()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, ink[15], nil, Point(0, 0));
	if(font != nil)
		img.text(img.r.min, ink[1], Point(0, 0), font,
			"Draw with the left mouse; the faster you go the thicker it is.  "+
			"Right mouse for a color, a key to finish.");
	img.flush(Draw->Flushnow);
}

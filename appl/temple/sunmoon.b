implement Sunmoon;

# TempleOS Demo/Graphics/SunMoon.HC — dithered flood fills, and gr.dc.
#
#	Fs->text_attr=BLACK<<4+WHITE;
#	for (i=0;i<0x8000;i+=0x200) {
#	  x=0.2*GR_WIDTH; y=0.5*GR_HEIGHT; radius=120;
#	  gr.dc->color=DKGRAY; GrCircle(gr.dc,x,y,radius);
#	  gr.dc->color=ROPF_DITHER+RED<<16+YELLOW; GrFloodFill(gr.dc,x,y);
#	  x=0.8*GR_WIDTH-i/0x200; radius=75;
#	  gr.dc->color=DKGRAY; GrCircle(gr.dc,x,y,radius);
#	  GrCircle(gr.dc,x+0.5*radius,y,1.2*radius,,pi-.31*pi,0.62*pi);
#	  gr.dc->color=ROPF_PROBABILITY_DITHER+LTGRAY<<16+BLACK;
#	  gr.dc->dither_probability_u16=i;    GrFloodFill(gr.dc,x+0.5*radius,y);
#	  gr.dc->dither_probability_u16=2*i;  GrFloodFill(gr.dc,x-0.75*radius,y);
#	  Refresh; DCFill;
#	}
#
# The file's own comment is about gr.dc being the persistent layer, which
# two tasks must not touch at once without DCAlias.  What it draws is two
# kinds of dither: ROPF_DITHER, a fixed checkerboard of RED and YELLOW
# that makes the sun orange out of a palette with no orange in it, and
# ROPF_PROBABILITY_DITHER, which picks LTGRAY over BLACK with probability
# dither_probability_u16/65536.  The moon is outlined twice — its rim and
# an arc from pi-0.31pi through 0.62pi, which is the terminator — and the
# two regions either side of that arc are filled at probabilities i and
# 2i, so over the 64 frames the moon waxes while it drifts left.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "math.m";
	math: Math;

include "rand.m";
	rand: Rand;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "keyboard.m";
include "grpalette.m";
	grpal: Grpalette;
include "frameclock.m";
	fclock: Frameclock;

Sunmoon: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# The port's own simulation step, in milliseconds.  The frame clock
# runs at 60fps and this many milliseconds of simulation are run for
# each frame's worth of real time, so the picture is smooth and the
# simulation keeps the speed it was written for.
FCSTEP: con 33;
# The most substeps one frame may run: enough to cover a frame of
# real time at this step, with headroom.  A fixed cap is wrong -
# four substeps covers 40ms at FCSTEP 10 and only 4ms at FCSTEP 1.
FCMAX: con 2 + 20/FCSTEP;
fcacc := 0;

PI: con 3.141592653589793;
GR_WIDTH: con 640;
GR_HEIGHT: con 480;

BLACK, BLUE, GREEN, CYAN, RED, PURPLE, BROWN, LTGRAY: con iota;
DKGRAY, LTBLUE, LTGREEN, LTCYAN, LTRED, LTPURPLE, YELLOW, WHITE: con iota + 8;

win: ref Window;
font: ref Font;
ink: array of ref Image;
cmap: array of int;		# palette index per pixel of the canvas
cw, ch: int;
i := 0;
done := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	math = load Math Math->PATH;
	rand = load Rand Rand->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	fclock = load Frameclock Frameclock->PATH;
	fclock->init();
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS SunMoon", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/lucida/unicode.8.font");
	if(font == nil)
		font = Font.open(d, "/fonts/temple/temple.font");
	ink = array[16] of ref Image;
	cols := grpal->values();
	for(ci := 0; ci < 16; ci++)
		ink[ci] = d.color(cols[ci]);

	win.reshape(Rect((0, 0), (GR_WIDTH, GR_HEIGHT)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn fclock->ticker(ticks, 60);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	pointerev := <-win.ctxt.ptr =>
		# The titlebar is drawn by this window and only sees a click
		# if the program hands it one: without this arm the move,
		# resize and menu buttons on the window do nothing at all.
		win.pointer(*pointerev);
	k := <-win.ctxt.kbd =>
		if((k & Keyboard->Keyup) != Keyboard->Keyup)
			exit;
	dtms := <-ticks =>
		fcacc += dtms;
		if(fcacc > FCSTEP*FCMAX)
			fcacc = FCSTEP*FCMAX;
		for(fcn := 0; fcacc >= FCSTEP && fcn < FCMAX; fcn++){
			if(!done){
				i += 16r200;
				if(i >= 16r8000)
					done = 1;
				redraw();
			}
			fcacc -= FCSTEP;
		}
	}
}

# The canvas is kept as palette indices so a flood fill can see where one
# region ends, exactly as GrFloodFill reads the frame buffer.
redraw()
{
	img := win.image;
	if(img == nil)
		return;
	cw = img.r.dx();
	ch = img.r.dy();
	cmap = array[cw*ch] of { * => BLACK };		# text_attr BLACK<<4+WHITE

	# Sun
	x := int(0.2 * real GR_WIDTH);
	y := GR_HEIGHT/2;
	circle(x, y, 120, DKGRAY);
	flooddither(x, y, RED, YELLOW, -1);

	# Moon: rim, then the terminator arc
	x = int(0.8 * real GR_WIDTH) - i/16r200;
	r := 75;
	circle(x, y, r, DKGRAY);
	arc(x + r/2, y, int(1.2 * real r), PI - 0.31*PI, 0.62*PI, DKGRAY);
	flooddither(x + r/2, y, LTGRAY, BLACK, i);
	flooddither(x - 3*r/4, y, LTGRAY, BLACK, 2*i);

	blitcanvas(img);
	if(font != nil)
		img.text(Point(img.r.min.x, img.r.max.y - font.height), ink[WHITE],
			Point(0, 0), font,
			sys->sprint("dither_probability_u16=%d    any key exits", i));
	img.flush(Draw->Flushnow);
}

blitcanvas(img: ref Image)
{
	o := img.r.min;
	for(y := 0; y < ch; y++){
		x := 0;
		while(x < cw){
			c := cmap[y*cw + x];
			x2 := x + 1;
			while(x2 < cw && cmap[y*cw + x2] == c)
				x2++;
			img.draw(Rect((o.x+x, o.y+y), (o.x+x2, o.y+y+1)), ink[c],
				nil, Point(0, 0));
			x = x2;
		}
	}
}

plot(x, y, c: int)
{
	if(x >= 0 && x < cw && y >= 0 && y < ch)
		cmap[y*cw + x] = c;
}

circle(cx, cy, r, c: int)
{
	arc(cx, cy, r, 0.0, 2.0*PI, c);
}

arc(cx, cy, r: int, start, sweep: real, c: int)
{
	n := 8*r;
	if(n < 64)
		n = 64;
	for(k := 0; k <= n; k++){
		a := start + sweep*real k/real n;
		plot(cx + int(real r*math->cos(a)), cy + int(real r*math->sin(a)), c);
	}
}

# GrFloodFill with a dithered colour.  prob < 0 is ROPF_DITHER, the fixed
# checkerboard; otherwise ROPF_PROBABILITY_DITHER picks c1 with
# probability prob/65536 and c2 the rest of the time.
flooddither(sx, sy, c1, c2, prob: int)
{
	if(sx < 0 || sx >= cw || sy < 0 || sy >= ch)
		return;
	bg := cmap[sy*cw + sx];
	if(bg == c1 || bg == c2)
		return;
	stack := array[cw*ch] of int;
	sp := 0;
	stack[sp++] = sy*cw + sx;
	while(sp > 0){
		p := stack[--sp];
		if(cmap[p] != bg)
			continue;
		y := p / cw;
		x0 := p % cw;
		while(x0 > 0 && cmap[y*cw + x0 - 1] == bg)
			x0--;
		x1 := p % cw;
		while(x1 < cw-1 && cmap[y*cw + x1 + 1] == bg)
			x1++;
		for(x := x0; x <= x1; x++){
			c := c2;
			if(prob < 0){
				if(((x + y) & 1) == 0)
					c = c1;
			}else if(rn(65536) < prob)
				c = c1;
			cmap[y*cw + x] = c;
			if(y > 0 && cmap[(y-1)*cw + x] == bg && sp < len stack - 1)
				stack[sp++] = (y-1)*cw + x;
			if(y < ch-1 && cmap[(y+1)*cw + x] == bg && sp < len stack - 1)
				stack[sp++] = (y+1)*cw + x;
		}
	}
}

rn(n: int): int
{
	if(rand == nil)
		return sys->millisec() % n;
	return rand->rand(n);
}


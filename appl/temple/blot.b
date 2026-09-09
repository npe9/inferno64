implement Blot;

# TempleOS Demo/Graphics/Blot.HC — device contexts as images, and brushes.
#
#	img1=DCNew(64,64);  img2=DCNew(512,512);
#	img1->color=COLOR_MONO; img1->thick=3;
#	GrCircle(img1,30,30,20); GrFloodFill3(img1,30,30,0,TRUE);
#	GrLine3(img1,60,0,0, 0,60,0);
#	DCFill(img2); img2->color=RED; img2->brush=img1;
#	GrCircle(img2,256-30,256-30,128,67);
#	img2->color=BLUE; img2->thick=6; img2->brush=NULL;
#	GrLine3(img2,128,128,0,256+128,256+128,0);
#	GrLine3(img2,256+128,128,0,128,256+128,0);
#	img2->color=YELLOW; GrRect(img2,256-20,256-20,40,40);
#	for (i=0;i<256;i+=4) { Refresh; DCFill; GrBlot(dc,i-256,i-256,img2); Sleep(10); }
#	tmpg=DC2Sprite(img1); Sprite(tmpg);
#
# Two off-screen device contexts.  The small one is a monochrome brush: a
# filled circle with a diagonal through it.  Setting img2->brush to it and
# then drawing a circle stamps the brush at every plotted point instead of
# a pixel, which is what makes the big ring look like a chain — the 67 is
# the circle's step, so it stamps every 67th point rather than every one.
# Clearing the brush puts the pen back to a plain six-thick line.
#
# Then the 512x512 context is blotted across the window from -256,-256 up
# to 0,0 in steps of four, and at the end the brush itself is turned into
# a sprite with DC2Sprite and drawn — a device context and a sprite being
# two views of the same pixels.

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

include "keyboard.m";
include "grpalette.m";
	grpal: Grpalette;
include "frameclock.m";
	fclock: Frameclock;

Blot: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# The port's own simulation step, in milliseconds.  The frame clock
# runs at 60fps and this many milliseconds of simulation are run for
# each frame's worth of real time, so the picture is smooth and the
# simulation keeps the speed it was written for.
FCSTEP: con 10;
fcacc := 0;

PI: con 3.141592653589793;

win: ref Window;
font: ref Font;
d: ref Display;
white, black, blue, red, yellow: ref Image;
img1, img1mask: ref Image;		# the 64x64 brush
img2: ref Image;			# the 512x512 canvas
i := 0;
done := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	fclock = load Frameclock Frameclock->PATH;
	fclock->init();
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS Blot", Wmclient->Appl);
	d = win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	white = d.color(grpal->value(Grpalette->WHITE));
	black = d.color(grpal->value(Grpalette->BLACK));
	blue = d.color(grpal->value(Grpalette->BLUE));
	red = d.color(grpal->value(Grpalette->RED));
	yellow = d.color(grpal->value(Grpalette->YELLOW));
	makebrush();
	makecanvas();

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn fclock->ticker(ticks, 60);	# 60fps: the original's Sleep(10)
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
		if(done && (k & Keyboard->Keyup) != Keyboard->Keyup)
			exit;
	dtms := <-ticks =>
		fcacc += dtms;
		for(fcn := 0; fcacc >= FCSTEP && fcn < 4; fcn++){
			if(!done){
				i += 4;			# i<256, i+=4
				if(i >= 256)
					done = 1;
				redraw();
			}
			fcacc -= FCSTEP;
		}
	}
}

# img1: COLOR_MONO, thick 3, a filled circle at (30,30) r20 and a diagonal
makebrush()
{
	img1 = d.newimage(Rect((0,0),(64,64)), Draw->CMAP8, 0, Draw->White);
	img1mask = d.newimage(Rect((0,0),(64,64)), Draw->GREY1, 0, 0);
	if(img1 == nil || img1mask == nil)
		return;
	# the mask is the monochrome shape; the colour comes from the pen
	img1mask.fillellipse(Point(30, 30), 20, 20, black, Point(0, 0));
	img1mask.line(Point(60, 0), Point(0, 60), Draw->Endsquare,
		Draw->Endsquare, 1, d.opaque, Point(0, 0));
	img1mask.fillellipse(Point(30, 30), 20, 20, d.opaque, Point(0, 0));
	img1.draw(img1.r, black, img1mask, Point(0, 0));
}

# img2: the brushed ring, the two thick blue diagonals, the yellow square
makecanvas()
{
	img2 = d.newimage(Rect((0,0),(512,512)), Draw->CMAP8, 0, Draw->White);
	if(img2 == nil)
		return;
	# GrCircle(img2,226,226,128,67): a circle stamped every 67th point
	# rather than plotted pixel by pixel, with img1 as the brush
	cx := 256-30;
	cy := 256-30;
	r := 128.0;
	for(k := 0; k < 67; k++){
		a := 2.0*PI*real k/67.0;
		x := cx + int(r*math->cos(a));
		y := cy + int(r*math->sin(a));
		stamp(img2, x, y, red);
	}
	# brush cleared, thick 6, two diagonals
	img2.line(Point(128,128), Point(256+128,256+128), Draw->Endsquare,
		Draw->Endsquare, 3, blue, Point(0, 0));
	img2.line(Point(256+128,128), Point(128,256+128), Draw->Endsquare,
		Draw->Endsquare, 3, blue, Point(0, 0));
	img2.draw(Rect((256-20,256-20),(256+20,256+20)), yellow, nil, Point(0,0));
}

# one brush stamp, centred where the pen is
stamp(dst: ref Image, x, y: int, col: ref Image)
{
	if(img1mask == nil)
		return;
	dst.draw(Rect((x-32, y-32), (x+32, y+32)), col, img1mask, Point(0, 0));
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	img.draw(img.r, white, nil, Point(0, 0));	# DCFill
	if(img2 != nil)
		img.draw(img2.r.addpt(Point(o.x + i - 256, o.y + i - 256)),
			img2, nil, img2.r.min);
	if(done && img1 != nil){
		# DC2Sprite(img1); Sprite(tmpg): the brush itself, as a sprite
		img.draw(img1.r.addpt(Point(o.x + 16, o.y + 16)), img1, img1mask,
			img1.r.min);
		if(font != nil)
			img.text(Point(o.x + 16, o.y + 16 + 66), black, Point(0, 0),
				font, "the brush, as a sprite");
	}
	if(font != nil)
		img.text(Point(o.x, img.r.max.y - font.height), blue, Point(0, 0),
			font, "any key exits");
	img.flush(Draw->Flushnow);
}


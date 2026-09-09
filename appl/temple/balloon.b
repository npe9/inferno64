implement Balloon;

# TempleOS Demo/Graphics/Balloon.HC — "Classic Commodore 64 Sprite".
#
#	U8 a[60]={0,127,0, 1,255,192, 3,255,224, ... 0,28,0};
#	CLI
#	OutU8(VGAP_IDX,VGAR_MAP_MASK); OutU8(VGAP_DATA,0xF);
#	MemSetI64(text.vga_alias,0,640*480/64);
#	OutU8(VGAP_IDX,VGAR_MAP_MASK); OutU8(VGAP_DATA,RED+GREEN+8);
#	for (k=100;k<150;k++) {
#	  for (i=0;i<20;i++) for (j=0;j<3;j++)
#	    *(text.vga_alias+0x1000+(i+k)*640/8+j)(U8*)=a[i*3+j];
#	  Busy(40000);
#	  ... and write zeroes back over it
#	}
#	STI  VGAFlush;
#
# Twenty rows of three bytes: the balloon sprite from a Commodore 64, at
# its original 24 by 21, one bit to the pixel.  Everything else in the
# program is the VGA: interrupts off, the plane mask set so writes land in
# the red, green and intensity planes at once — which is yellow — the
# screen cleared, and then the sprite poked straight into the framebuffer
# a byte at a time, erased, and poked one row lower.
#
# GAP: there is no framebuffer to poke and no plane mask to set, so the
#      port draws the same bits as pixels.  The sprite data, its 24x21
#      shape, the yellow, and the fifty rows it falls through are the
#      original's; the mechanism the demo is really showing off is not
#      reproducible outside a VGA.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "keyboard.m";
include "grpalette.m";
	grpal: Grpalette;
include "frameclock.m";
	fclock: Frameclock;

Balloon: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# The port's own simulation step, in milliseconds.  The frame clock
# runs at 60fps and this many milliseconds of simulation are run for
# each frame's worth of real time, so the picture is smooth and the
# simulation keeps the speed it was written for.
FCSTEP: con 40;
# The most substeps one frame may run: enough to cover a frame of
# real time at this step, with headroom.  A fixed cap is wrong -
# four substeps covers 40ms at FCSTEP 10 and only 4ms at FCSTEP 1.
FCMAX: con 2 + 20/FCSTEP;
fcacc := 0;

# the sixty bytes, verbatim
a := array[] of {
	0,127,0,   1,255,192, 3,255,224, 3,231,224,
	7,217,240, 7,223,240, 7,217,240, 3,231,224,
	3,255,224, 3,255,224, 2,255,160, 1,127,64,
	1,62,64,   0,156,128, 0,156,128, 0,73,0, 0,73,0,
	0,62,0,    0,62,0,    0,28,0
};

win: ref Window;
font: ref Font;
black, yellow, blue: ref Image;
k := 100;

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
	win = wmclient->window(ctxt, "TempleOS Balloon", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/lucida/unicode.8.font");
	if(font == nil)
		font = Font.open(d, "/fonts/temple/temple.font");
	black = d.color(grpal->value(Grpalette->BLACK));
	blue = d.color(grpal->value(Grpalette->BLUE));
	yellow = d.color(grpal->value(Grpalette->YELLOW));	# RED+GREEN+8 in the plane mask

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn fclock->ticker(ticks, 60);	# 60fps: Busy(40000), near enough
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	pointerev := <-win.ctxt.ptr =>
		# The titlebar is drawn by this window and only sees a click
		# if the program hands it one: without this arm the move,
		# resize and menu buttons on the window do nothing at all.
		win.pointer(*pointerev);
	kk := <-win.ctxt.kbd =>
		if((kk & Keyboard->Keyup) != Keyboard->Keyup)
			exit;
	dtms := <-ticks =>
		fcacc += dtms;
		if(fcacc > FCSTEP*FCMAX)
			fcacc = FCSTEP*FCMAX;
		for(fcn := 0; fcacc >= FCSTEP && fcn < FCMAX; fcn++){
			if(++k >= 150)
				k = 100;
			fcacc -= FCSTEP;
		}
		redraw();
	}
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	img.draw(img.r, black, nil, Point(0, 0));	# the cleared screen
	# the sprite: twenty rows of three bytes, most significant bit left
	for(i := 0; i < 20; i++)
		for(j := 0; j < 3; j++){
			b := a[i*3 + j];
			for(bit := 0; bit < 8; bit++)
				if((b & (16r80 >> bit)) != 0){
					x := o.x + j*8 + bit;
					y := o.y + i + k;
					img.draw(Rect((x, y), (x+1, y+1)), yellow,
						nil, Point(0, 0));
				}
		}
	if(font != nil)
		img.text(Point(o.x, o.y), blue, Point(0, 0), font,
			sys->sprint("row %d of 100..149    any key exits", k));
	img.flush(Draw->Flushnow);
}


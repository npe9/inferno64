implement Charanimation;

# TempleOS Demo/Graphics/CharAnimation.HC — animate a font glyph.
#
#	U64 waves[4]={0x0011AA440011AA44,0x0022558800225588,
#	              0x0044AA110044AA11,0x0088552200885522};
#	AnimateTask: font=MAlloc(256*8); MemCpy(font,text.font,256*8);
#	             text.font=font;
#	             while (TRUE) { font[CH_SPACE]=waves[i++&0x3]; Sleep(100); }
#	Spawn(&AnimateTask,...); TaskRep;
#
# Twenty-eight lines, and the trick is in one of them.  A TempleOS font is
# 256 glyphs of eight bytes, one byte to a row, and text.font is just a
# pointer at it — so copying the font, pointing text.font at the copy and
# rewriting the eight bytes of the space character makes every space
# already on the screen ripple, in any window, without redrawing anything.
# The four masks are the same diagonal shifted a pixel at a time, which is
# what makes it flow rather than flicker.  TaskRep then prints the task
# list, whose spaces are now waves.
#
# GAP: there is no shared font to repoint, so the port draws the wave
#      glyph itself wherever a space falls in its own text.  The original
#      changes every space on the display.

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

Charanimation: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# The port's own simulation step, in milliseconds.  The frame clock
# runs at 60fps and this many milliseconds of simulation are run for
# each frame's worth of real time, so the picture is smooth and the
# simulation keeps the speed it was written for.
FCSTEP: con 100;
# The most substeps one frame may run: enough to cover a frame of
# real time at this step, with headroom.  A fixed cap is wrong -
# four substeps covers 40ms at FCSTEP 10 and only 4ms at FCSTEP 1.
FCMAX: con 2 + 20/FCSTEP;
fcacc := 0;

FW: con 8;
FH: con 8;

# the four glyphs, MSB-first per row exactly as TempleOS stores a font:
# eight bytes low-to-high are the eight rows top-to-bottom
waves := array[] of {
	array[] of {16r00, 16r11, 16rAA, 16r44, 16r00, 16r11, 16rAA, 16r44},
	array[] of {16r00, 16r22, 16r55, 16r88, 16r00, 16r22, 16r55, 16r88},
	array[] of {16r00, 16r44, 16rAA, 16r11, 16r00, 16r44, 16rAA, 16r11},
	array[] of {16r00, 16r88, 16r55, 16r22, 16r00, 16r88, 16r55, 16r22},
};

# what TaskRep prints, near enough: this port's own tasks
report := array[] of {
	"Task       Stack  State",
	"Adam       16384  Waiting",
	"CharAnimation 4096  Running",
	"Animate     2048  Sleeping",
	"",
	"every space above is the wave glyph, not a blank",
};

win: ref Window;
font: ref Font;
white, black, blue: ref Image;
phase := 0;

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
	win = wmclient->window(ctxt, "TempleOS CharAnimation", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	white = d.color(grpal->value(Grpalette->WHITE));
	black = d.color(grpal->value(Grpalette->BLACK));
	blue = d.color(grpal->value(Grpalette->BLUE));

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn fclock->ticker(ticks, 60);	# 60fps: the original's Sleep(100)
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
			phase = (phase + 1) & 3;
			fcacc -= FCSTEP;
		}
		redraw();
	}
}

redraw()
{
	img := win.image;
	if(img == nil || font == nil)
		return;
	o := img.r.min;
	img.draw(img.r, white, nil, Point(0, 0));
	y := o.y + FH;
	for(i := 0; i < len report; i++){
		putline(img, Point(o.x + FW, y), report[i]);
		y += FH + 4;
	}
	img.text(Point(o.x, img.r.max.y - FH), blue, Point(0, 0), font,
		sys->sprint("waves[%d]    any key exits", phase));
	img.flush(Draw->Flushnow);
}

# draw a line of text, substituting the animated glyph for every space
putline(img: ref Image, at: Point, s: string)
{
	x := at.x;
	for(i := 0; i < len s; i++){
		if(s[i] == ' ')
			glyph(img, Point(x, at.y), waves[phase]);
		else
			img.text(Point(x, at.y), black, Point(0, 0), font, s[i:i+1]);
		x += FW;
	}
}

# eight bytes, one to a row, MSB the leftmost pixel
glyph(img: ref Image, at: Point, g: array of int)
{
	for(r := 0; r < 8; r++)
		for(c := 0; c < 8; c++)
			if((g[r] & (16r80 >> c)) != 0)
				img.draw(Rect((at.x+c, at.y+r), (at.x+c+1, at.y+r+1)),
					black, nil, Point(0, 0));
}


implement Wallpaperctrl;

# TempleOS Demo/Graphics/WallPaperCtrl.HC — a control on the wallpaper.
#
# "This is an advanced demo that shows that you can place ctrls on the
# wall paper.  See Slider.HC and WallPaperFish.HC before messing with
# this program.  It must be 'Adam Included'."
#
# The control is Slider.HC's, unchanged.  What is different is where it
# lives: the CCtrl is queued on Adam, the system task that owns the
# desktop, rather than on the program's own window — which is why the
# file has to be included into Adam rather than run.  So the slider sits
# on the wallpaper, under every window, and still takes clicks.
#
# GAP: an Inferno client cannot put anything on wm(1)'s background, and
#      nothing here corresponds to being included into Adam.  The port
#      draws the wallpaper in its own window and puts the slider on that,
#      which shows the control and its backdrop but not the one thing the
#      demo is actually about.

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

Wallpaperctrl: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

SLIDER_RANGE: con 30;
SLIDER_SPACING: con 20;
SLIDER_BORDER: con 2;
FW: con 8;
FH: con 8;

win: ref Window;
font: ref Font;
white, black, blue, ltred, yellow: ref Image;
leftpos, rightpos: int;
cleft, ctop: int;
done := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS WallPaperCtrl", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	white = d.color(grpal->value(Grpalette->WHITE));
	black = d.color(grpal->value(Grpalette->BLACK));
	blue = d.color(grpal->value(Grpalette->BLUE));
	ltred = d.color(grpal->value(Grpalette->LTRED));
	yellow = d.color(grpal->value(Grpalette->YELLOW));

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	redraw();
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		redraw();
	k := <-win.ctxt.kbd =>
		if((k & Keyboard->Keyup) == Keyboard->Keyup)
			continue;
		if(done)
			exit;
		done = 1;		# PressAKey, then print the values
		redraw();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		img := win.image;
		if(img == nil || done)
			continue;
		if(p.buttons & 1)
			leftclick(p.xy.x - img.r.min.x, p.xy.y - img.r.min.y);
		redraw();
	}
}

# UpdateDerivedCtrlSlider: re-centre in the window, clamp both positions
derive(w, h: int)
{
	cleft = w/2 - (SLIDER_SPACING*3 + 2)/2;
	ctop = h/2 - (SLIDER_SPACING*2 + SLIDER_RANGE)/2;
	leftpos = clamp(leftpos, 0, SLIDER_RANGE-1);
	rightpos = clamp(rightpos, 0, SLIDER_RANGE-1);
}

clamp(v, lo, hi: int): int
{
	if(v < lo)
		return lo;
	if(v > hi)
		return hi;
	return v;
}

leftclick(x, y: int)
{
	if(x < cleft + 1*SLIDER_SPACING + SLIDER_SPACING/2)
		leftpos = SLIDER_RANGE - 1 - (y - (ctop + SLIDER_SPACING));
	else
		rightpos = SLIDER_RANGE - 1 - (y - (ctop + SLIDER_SPACING));
	leftpos = clamp(leftpos, 0, SLIDER_RANGE-1);
	rightpos = clamp(rightpos, 0, SLIDER_RANGE-1);
}

# the desktop behind it: TempleOS's own diagonal weave
wallpaper(img: ref Image, o: Point)
{
	img.draw(img.r, black, nil, Point(0, 0));
	w := img.r.dx();
	h := img.r.dy();
	for(i := -h; i < w; i += 16)
		img.line(Point(o.x+i, o.y), Point(o.x+i+h, o.y+h),
			Draw->Endsquare, Draw->Endsquare, 0, blue, Point(0, 0));
}

rect(img: ref Image, o: Point, x, y, w, h: int, col: ref Image)
{
	img.draw(Rect((o.x+x, o.y+y), (o.x+x+w, o.y+y+h)), col, nil, Point(0, 0));
}

redraw()
{
	img := win.image;
	if(img == nil || font == nil)
		return;
	o := img.r.min;
	derive(img.r.dx(), img.r.dy());
	wallpaper(img, o);

	# DrawCtrlSlider, line for line
	rect(img, o, cleft, ctop, SLIDER_SPACING*3+2,
		SLIDER_SPACING*2+SLIDER_RANGE, ltred);
	rect(img, o, cleft+SLIDER_BORDER, ctop+SLIDER_BORDER,
		SLIDER_SPACING*3+2-2*SLIDER_BORDER,
		SLIDER_SPACING*2+SLIDER_RANGE-2*SLIDER_BORDER, blue);
	for(i := 1; i <= 2; i++){
		tx := cleft + i*SLIDER_SPACING + (i - 1);
		img.line(Point(o.x+tx, o.y+ctop+SLIDER_SPACING),
			Point(o.x+tx, o.y+ctop+SLIDER_SPACING+SLIDER_RANGE-1),
			Draw->Endsquare, Draw->Endsquare, 0, black, Point(0, 0));
		pos := leftpos;
		if(i == 2)
			pos = rightpos;
		img.text(Point(o.x+tx-FW/2, o.y+ctop+SLIDER_SPACING+SLIDER_RANGE+3),
			ltred, Point(0, 0), font,
			sys->sprint("%d", pos*10/SLIDER_RANGE));
		hy := ctop + SLIDER_SPACING + SLIDER_RANGE - 1 - pos;
		rect(img, o, tx-3, hy-2, 7, 5, ltred);
		rect(img, o, tx-2, hy-1, 5, 3, yellow);
	}

	if(done)
		img.text(Point(o.x, o.y + 2*FH), black, Point(0, 0), font,
			sys->sprint("Left: %d  Right: %d",
				leftpos*10/SLIDER_RANGE, rightpos*10/SLIDER_RANGE));
	img.text(Point(o.x, img.r.max.y - font.height), yellow, Point(0, 0), font,
		"a control on the wallpaper; click it, a key reads the values");
	img.flush(Draw->Flushnow);
}

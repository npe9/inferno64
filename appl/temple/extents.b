implement Extents;

# TempleOS Demo/Graphics/Extents.HC — what did that sprite actually cover?
#
#	DCExtentsInit(dc);
#	dc->thick=3;
#	Sprite3(dc,40,GR_HEIGHT>>1,0,$IB,"<1>",BI=1$);
#	dc->color=LTRED; dc->thick=1;
#	GrLine(dc,dc->min_x-h,dc->min_y-v,dc->max_x-h,dc->min_y-v);  ... (a box)
#	PressAKey; DCFill;
#	SpriteExtents($IB,"<1>",BI=1$,&min_x,&max_x,&min_y,&max_y);
#	"X: %d to %d\n"; "Y: %d to %d\n";
#
# Two different extents, which is the whole demo.  DCExtentsInit makes the
# device context record the bounding box of everything actually drawn
# through it, in screen coordinates (hence the -h/-v to bring them back to
# window coordinates), and that box is drawn in LTRED.  SpriteExtents
# instead measures the sprite itself, in its own coordinates, without
# drawing anything.  The two differ by the draw position and by the
# thick=3 pen, which fattens what was drawn beyond what the sprite says.
#
# Here the drawn extents are measured from the sprite's mask — the pixels
# that were really painted — and the sprite extents are the rect the
# extractor recorded, which is SpriteExtents' own answer.

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

Extents: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

SPR: con "/icons/temple/extents_1";
THICK: con 3;			# the original's dc->thick

win: ref Window;
font: ref Font;
white, black, ltred: ref Image;
spr, mask: ref Image;
drawn: Rect;
haveDrawn := 0;
showing := 0;			# 0 = the picture, 1 = the printed extents

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS Extents", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	white = d.color(int 16rFFFFFFFF);
	black = d.color(int 16r000000FF);
	ltred = d.color(int 16rFF5555FF);
	spr = d.open(SPR + ".bit");
	mask = d.open(SPR + ".mask");

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	redraw();
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		redraw();
	pointerev := <-win.ctxt.ptr =>
		# The titlebar is drawn by this window and only sees a click
		# if the program hands it one: without this arm the move,
		# resize and menu buttons on the window do nothing at all.
		win.pointer(*pointerev);
	k := <-win.ctxt.kbd =>
		if((k & Keyboard->Keyup) == Keyboard->Keyup)
			continue;
		if(showing)			# the second PressAKey
			exit;
		showing = 1;			# DCFill, then print
		redraw();
	}
}

# DCExtentsInit: the bounding box of what was really painted, found from
# the mask rather than assumed from the sprite rect, then grown by the pen.
maskextents(at: Point): (Rect, int)
{
	if(mask == nil)
		return (Rect((0,0),(0,0)), 0);
	w := mask.r.dx();
	h := mask.r.dy();
	stride := (w + 7) / 8;
	buf := array[stride*h] of byte;
	if(mask.readpixels(mask.r, buf) <= 0)
		return (Rect((0,0),(0,0)), 0);
	minx := w; maxx := -1; miny := h; maxy := -1;
	for(y := 0; y < h; y++)
		for(x := 0; x < w; x++)
			if((int buf[y*stride + x/8] & (16r80 >> (x&7))) != 0){
				if(x < minx) minx = x;
				if(x > maxx) maxx = x;
				if(y < miny) miny = y;
				if(y > maxy) maxy = y;
			}
	if(maxx < 0)
		return (Rect((0,0),(0,0)), 0);
	# back to window coordinates, then grown by the thick=3 pen
	x0 := at.x + mask.r.min.x + minx - THICK;
	y0 := at.y + mask.r.min.y + miny - THICK;
	x1 := at.x + mask.r.min.x + maxx + THICK;
	y1 := at.y + mask.r.min.y + maxy + THICK;
	return (Rect((x0, y0), (x1, y1)), 1);
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	img.draw(img.r, white, nil, Point(0, 0));
	at := Point(40, img.r.dy()/2);		# Sprite3(dc,40,GR_HEIGHT>>1,0,...)
	if(!showing){
		if(spr != nil)
			img.draw(spr.r.addpt(at.add(o)), spr, mask, spr.r.min);
		(r, ok) := maskextents(at);
		drawn = r;
		haveDrawn = ok;
		if(ok)
			box(img, o, r, ltred);
		if(font != nil)
			img.text(Point(o.x, img.r.max.y - font.height), black,
				Point(0, 0), font,
				"red box: what the DC recorded as drawn.  Any key.");
	}else if(font != nil){
		# SpriteExtents: the sprite's own extents, nothing drawn
		y := o.y;
		if(spr != nil){
			img.text(Point(o.x, y), black, Point(0, 0), font,
				sys->sprint("X: %d to %d", spr.r.min.x, spr.r.max.x - 1));
			y += font.height;
			img.text(Point(o.x, y), black, Point(0, 0), font,
				sys->sprint("Y: %d to %d", spr.r.min.y, spr.r.max.y - 1));
			y += 2*font.height;
		}
		if(haveDrawn){
			img.text(Point(o.x, y), black, Point(0, 0), font,
				sys->sprint("drawn with thick=%d at (40,%d): x %d to %d, y %d to %d",
					THICK, img.r.dy()/2, drawn.min.x, drawn.max.x,
					drawn.min.y, drawn.max.y));
			y += font.height;
		}
		img.text(Point(o.x, y + font.height), black, Point(0, 0), font,
			"any key exits");
	}
	img.flush(Draw->Flushnow);
}

box(img: ref Image, o: Point, r: Rect, col: ref Image)
{
	a := Point(o.x+r.min.x, o.y+r.min.y);
	b := Point(o.x+r.max.x, o.y+r.min.y);
	c := Point(o.x+r.max.x, o.y+r.max.y);
	d := Point(o.x+r.min.x, o.y+r.max.y);
	img.line(a, b, Draw->Endsquare, Draw->Endsquare, 0, col, Point(0,0));
	img.line(a, d, Draw->Endsquare, Draw->Endsquare, 0, col, Point(0,0));
	img.line(c, b, Draw->Endsquare, Draw->Endsquare, 0, col, Point(0,0));
	img.line(c, d, Draw->Endsquare, Draw->Endsquare, 0, col, Point(0,0));
}

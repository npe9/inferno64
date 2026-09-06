implement Spriteraw;

# TempleOS Demo/Graphics/SpriteRaw.HC — a sprite built by hand.
#
# "Normally, you make sprites with <CTRL-r>.  This shows how to build a
# sprite by hand."  The original declares a struct of sprite elements and
# fills the type fields itself:
#
#	s.color.type=SPT_COLOR;      s.color.color=GREEN;
#	s.line1.type=SPT_LINE;       s.line1.x2=100; s.line1.y2=50;
#	s.line2.type=SPT_LINE;       s.line2.x2=50;  s.line2.y2=100;
#	s.line3.type=SPT_LINE;       s.line3.x1=100; s.line3.y1=50;
#	                             s.line3.x2=50;  s.line3.y2=100;
#	s.fill.type=SPT_FLOOD_FILL;  s.fill.x1=20;   s.fill.y1=20;
#	s.end.type=SPT_END;
#	Sprite(&s);
#
# A green triangle with its interior flooded, three lines from the origin
# and between the two far corners.  The unset fields are zero from the
# MemSet, so line1 and line2 both start at (0,0).
#
# The element list is written out below in the same text vocabulary
# scripts/tos_extract_sprites.py uses and temple/spriteedit(1) edits, so
# the hand-built sprite can be read as well as drawn — which is the point
# the original is making about what a CSprite is.

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

Spriteraw: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# TempleOS palette indices
BLACK, BLUE, GREEN: con iota;

# the sprite, element by element, exactly as the original fills it in
elems := array[] of {
	"color 2",			# SPT_COLOR, GREEN
	"line 0 0 100 50",		# SPT_LINE
	"line 0 0 50 100",		# SPT_LINE
	"line 100 50 50 100",		# SPT_LINE
	"floodfill 20 20",		# SPT_FLOOD_FILL
};

ORIGIN: con 120;		# where the sprite is planted in the window

win: ref Window;
font: ref Font;
white, black, green: ref Image;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS SpriteRaw", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	white = d.color(int 16rFFFFFFFF);
	black = d.color(int 16r000000FF);
	green = d.color(int 16r00AA00FF);

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: nil);
	redraw();
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		redraw();
	k := <-win.ctxt.kbd =>
		if((k & Keyboard->Keyup) != Keyboard->Keyup)
			exit;
	}
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	img.draw(img.r, white, nil, Point(0, 0));
	drawsprite(img, Point(o.x + ORIGIN, o.y + ORIGIN));
	if(font != nil){
		y := img.r.max.y - (len elems + 2)*font.height;
		img.text(Point(o.x, y), black, Point(0, 0), font,
			"the elements, in order:");
		y += font.height;
		for(i := 0; i < len elems; i++){
			img.text(Point(o.x + 8, y), black, Point(0, 0), font, elems[i]);
			y += font.height;
		}
	}
	img.flush(Draw->Flushnow);
}

# Replay the element list the way a DC replays a CSprite: colour, then
# strokes, then the flood fill, in the order written.
drawsprite(img: ref Image, at: Point)
{
	col := black;
	for(i := 0; i < len elems; i++){
		(n, t) := sys->tokenize(elems[i], " ");
		if(n == 0)
			continue;
		kind := hd t;
		t = tl t;
		case kind {
		"color" =>
			if(int hd t == GREEN)
				col = green;
			else if(int hd t == BLUE)
				col = black;
		"line" =>
			x1 := int hd t; t = tl t;
			y1 := int hd t; t = tl t;
			x2 := int hd t; t = tl t;
			y2 := int hd t;
			img.line(Point(at.x+x1, at.y+y1), Point(at.x+x2, at.y+y2),
				Draw->Endsquare, Draw->Endsquare, 0, col, Point(0, 0));
		"floodfill" =>
			x := int hd t; t = tl t;
			y := int hd t;
			flood(img, Point(at.x+x, at.y+y), col);
		}
	}
}

# SPT_FLOOD_FILL: spread from the seed over every pixel that still holds
# the background colour.  A scanline fill, so the recursion depth does not
# depend on the area.
flood(img: ref Image, seed: Point, col: ref Image)
{
	r := img.r;
	w := r.dx();
	h := r.dy();
	if(!seed.in(r))
		return;
	buf := array[w*h] of byte;
	if(img.readpixels(r, buf) <= 0)
		return;
	bg := buf[(seed.y-r.min.y)*w + (seed.x-r.min.x)];
	stack := array[w*h] of int;
	sp := 0;
	stack[sp++] = (seed.y-r.min.y)*w + (seed.x-r.min.x);
	seen := array[w*h] of { * => byte 0 };
	while(sp > 0){
		p := stack[--sp];
		if(seen[p] != byte 0 || buf[p] != bg)
			continue;
		y := p / w;
		# run left and right along this scanline
		x0 := p % w;
		while(x0 > 0 && buf[y*w + x0 - 1] == bg && seen[y*w + x0 - 1] == byte 0)
			x0--;
		x1 := p % w;
		while(x1 < w-1 && buf[y*w + x1 + 1] == bg && seen[y*w + x1 + 1] == byte 0)
			x1++;
		for(x := x0; x <= x1; x++){
			seen[y*w + x] = byte 1;
			if(y > 0 && buf[(y-1)*w + x] == bg && seen[(y-1)*w + x] == byte 0)
				stack[sp++] = (y-1)*w + x;
			if(y < h-1 && buf[(y+1)*w + x] == bg && seen[(y+1)*w + x] == byte 0)
				stack[sp++] = (y+1)*w + x;
			if(sp >= len stack - 2)
				sp = len stack - 3;
		}
		img.draw(Rect((r.min.x+x0, r.min.y+y), (r.min.x+x1+1, r.min.y+y+1)),
			col, nil, Point(0, 0));
	}
}

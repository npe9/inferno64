implement Ropcollision;

# TempleOS Demo/Graphics/Collision.HC — the whole of DrawIt is
#
#	x=ms.pos.x-task->pix_left; y=ms.pos.y-task->pix_top;
#	Sprite3(dc,x,y,0,$IB,"<1>",BI=1$);
#	x=task->pix_width>>1; y=task->pix_height>>1;
#	dc->color=ROP_COLLISION; dc->bkcolor=WHITE; dc->collision_cnt=0;
#	Sprite3(dc,x,y,0,$IB,"<1>",BI=1$);
#	dc->color=ROP_EQU;
#	GrPrint(dc,0,(task->pix_height-FONT_HEIGHT)>>1,
#		"Collisions:%d",dc->collision_cnt);
#	if (!dc->collision_cnt) Sprite3(dc,x,y,0,$IB,"<1>",BI=1$);
#	else                    Sprite3(dc,x,y,0,$IB,"<2>",BI=2$);
#
# ROP_COLLISION is the demo.  A raster op that draws nothing: it walks the
# pixels the sprite would have set and increments dc->collision_cnt for
# each one that is already something other than dc->bkcolor.  So the
# centre sprite is drawn twice — once invisibly, to ask what it would have
# landed on, and once for real, in the second shape if the answer was
# anything at all.  Nothing is remembered between frames and no rectangles
# are intersected; the test is exactly the sprite's own pixels against
# whatever is on the screen under them, which is why a sprite with a hole
# in it can be moved right through the hole without a hit.
#
# This tree has no ROP_COLLISION, so it is done here the way the raster op
# does it: the frame is composed offscreen, the centre sprite's mask is
# walked, and every set pixel of it is compared against the background
# colour in the offscreen image.  Note the order — the mouse sprite is
# already drawn when the question is asked, and the text is printed after
# the count, so it can never contribute to it.
#
# Distinct from Demo/Games/Collision.HC, which is 64 elastic balls and is
# ported as collision(1).

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

Ropcollision: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

FH: con 8;			# TempleOS FONT_HEIGHT

win: ref Window;
font: ref Font;
buf: ref Image;			# the frame, composed offscreen
white, black, blue: ref Image;
spr1, msk1, spr2, msk2: ref Image;
mbits: array of byte;		# spr1's mask, one byte a pixel
mw, mh: int;
mx, my: int;
have_ms := 0;

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

	win = wmclient->window(ctxt, "TempleOS Collision", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	white = d.color(grpal->value(Grpalette->WHITE));
	black = d.color(grpal->value(Grpalette->BLACK));
	blue = d.color(grpal->value(Grpalette->BLUE));
	spr1 = d.open("/icons/temple/collision_1.bit");
	msk1 = d.open("/icons/temple/collision_1.mask");
	spr2 = d.open("/icons/temple/collision_2.bit");
	msk2 = d.open("/icons/temple/collision_2.mask");
	if(spr1 != nil)
		mbits = maskbits(d, spr1.r, msk1);

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 20);
	redraw();
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		buf = nil;
		redraw();
	k := <-win.ctxt.kbd =>
		if((k & Keyboard->Keyup) != Keyboard->Keyup)	# PressAKey
			exit;
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		img := win.image;
		if(img != nil){
			mx = p.xy.x - img.r.min.x;
			my = p.xy.y - img.r.min.y;
			have_ms = 1;
		}
	<-ticks =>
		redraw();
	}
}

# The mask as one byte a pixel: draw it white on black into an image we
# can read back, since a GREY1 readpixels comes out packed.
maskbits(d: ref Display, r: Rect, mask: ref Image): array of byte
{
	mw = r.dx();
	mh = r.dy();
	t := d.newimage(Rect((0,0),(mw,mh)), Draw->RGB24, 0, Draw->Black);
	if(t == nil)
		return nil;
	t.draw(t.r, white, mask, r.min);
	b := array[mw*mh*3] of byte;
	if(t.readpixels(t.r, b) < 0)
		return nil;
	m := array[mw*mh] of byte;
	for(i := 0; i < mw*mh; i++)
		m[i] = byte (int b[i*3] != 0);
	return m;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	d := win.display;
	r := img.r;
	if(buf == nil || buf.r.dx() != r.dx() || buf.r.dy() != r.dy())
		buf = d.newimage(Rect((0,0),(r.dx(),r.dy())), Draw->RGB24, 0,
			Draw->White);
	if(buf == nil)
		return;
	buf.draw(buf.r, white, nil, Point(0, 0));

	if(have_ms)
		blit(buf, spr1, msk1, mx, my);

	cx := r.dx()>>1;
	cy := r.dy()>>1;
	n := collisions(cx, cy);

	if(font != nil)
		buf.text(Point(0, (r.dy()-FH)>>1), blue, Point(0, 0), font,
			sys->sprint("Collisions:%d", n));
	if(n == 0)
		blit(buf, spr1, msk1, cx, cy);
	else
		blit(buf, spr2, msk2, cx, cy);

	img.draw(r, buf, nil, buf.r.min);
	img.flush(Draw->Flushnow);
}

# ROP_COLLISION: sprite <1> at (x,y), counting the pixels it would set
# that are not already dc->bkcolor.
collisions(x, y: int): int
{
	if(mbits == nil || spr1 == nil)
		return 0;
	rr := spr1.r.addpt(Point(x, y));
	cr := rr;
	if(cr.min.x < 0) cr.min.x = 0;
	if(cr.min.y < 0) cr.min.y = 0;
	if(cr.max.x > buf.r.max.x) cr.max.x = buf.r.max.x;
	if(cr.max.y > buf.r.max.y) cr.max.y = buf.r.max.y;
	if(cr.dx() <= 0 || cr.dy() <= 0)
		return 0;
	b := array[cr.dx()*cr.dy()*3] of byte;
	if(buf.readpixels(cr, b) < 0)
		return 0;
	n := 0;
	for(py := cr.min.y; py < cr.max.y; py++){
		row := (py - cr.min.y)*cr.dx()*3;
		mrow := (py - rr.min.y)*mw;
		for(px := cr.min.x; px < cr.max.x; px++){
			if(mbits[mrow + px - rr.min.x] == byte 0)
				continue;
			o := row + (px - cr.min.x)*3;
			if(b[o] != byte 16rFF || b[o+1] != byte 16rFF ||
			   b[o+2] != byte 16rFF)		# dc->bkcolor=WHITE
				n++;
		}
	}
	return n;
}

blit(dst, src, mask: ref Image, x, y: int)
{
	if(src == nil)
		return;
	dst.draw(src.r.addpt(Point(x, y)), src, mask, src.r.min);
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}

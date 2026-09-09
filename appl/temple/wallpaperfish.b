implement Wallpaperfish;

# TempleOS Demo/Graphics/WallPaperFish.HC — an aquarium for a desktop.
#
#	WallPaperFish(task):
#	  task->text_attr=CYAN<<4+WHITE;
#	  dc->color=BROWN;
#	  for (i=0;i<GR_HEIGHT;i+=20) { j=16*Tri(tS*10,20);
#	    GrLine(dc,0,GR_HEIGHT-i-j,GR_HEIGHT-i-j,GR_HEIGHT); }
#	  for each critter:
#	    j=(tS*4+c->t_offset)%FRAMES_PER_CRITTER;
#	    x=c->x>>16%GR_WIDTH; y=c->y>>16%GR_HEIGHT;
#	    if (c->dx<0) { DCF_SYMMETRY|DCF_JUST_MIRROR;
#	                   DCSymmetrySet(dc,x,y-1,x,y+1); }
#	    Sprite3(dc,x,y,0,imgs[c->type][j]);
#	    c->x+=c->dx;  c->y+=c->dy;
#	  WallInit: gr.fp_wall_paper=&WallPaperFish;
#
# Sixteen critters of three kinds, each a four-frame cycle {1,2,3,2} so
# the middle frame is shared going out and coming back — the same trick
# the games use.  Positions are 32.32 fixed point, which is why they are
# shifted right by sixteen before use and why a critter that runs off one
# edge reappears at the other for free.  A critter swimming left is drawn
# through DCF_JUST_MIRROR about a vertical line through itself rather
# than from a second set of sprites.
#
# The background is one line per twenty pixels, all parallel diagonals,
# with an offset that is a triangle wave of the clock: the water moves
# because the whole rack of lines slides.
#
# GAP: the original replaces gr.fp_wall_paper, the desktop's own paint
#      routine, and has to be included into Adam so its code outlives the
#      task — "Would crash when code mem was freed."  An Inferno client
#      cannot paint wm(1)'s background, so this draws in its own window.

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

include "rand.m";
	rand: Rand;
include "grpalette.m";
	grpal: Grpalette;
include "frameclock.m";
	fclock: Frameclock;

Wallpaperfish: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

TYPES_OF_CRITTERS: con 3;
FRAMES_PER_CRITTER: con 4;
CRITTERS_NUM: con 16;
GR_WIDTH: con 640;
GR_HEIGHT: con 480;

Critter: adt {
	x, y, dx, dy: real;		# the original's 32.32 fixed point
	ctype: int;
	toffset: real;
};

win: ref Window;
font: ref Font;
white, cyan, brown: ref Image;
spr: array of array of ref Image;	# [type][frame]
mask: array of array of ref Image;
flip: array of array of ref Image;	# DCF_JUST_MIRROR
flipmask: array of array of ref Image;
crits: array of Critter;
t0: int;

# imgs[type][frame], the original's table: {1,2,3,2} {4,5,6,5} {7,8,9,8}
frames := array[] of {
	array[] of {1, 2, 3, 2},
	array[] of {4, 5, 6, 5},
	array[] of {7, 8, 9, 8},
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	fclock = load Frameclock Frameclock->PATH;
	fclock->init();
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS WallPaperFish", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	white = d.color(grpal->value(Grpalette->WHITE));
	cyan = d.color(grpal->value(Grpalette->CYAN));	# text_attr CYAN<<4+WHITE
	brown = d.color(grpal->value(Grpalette->BROWN));

	spr = array[TYPES_OF_CRITTERS] of array of ref Image;
	mask = array[TYPES_OF_CRITTERS] of array of ref Image;
	flip = array[TYPES_OF_CRITTERS] of array of ref Image;
	flipmask = array[TYPES_OF_CRITTERS] of array of ref Image;
	for(t := 0; t < TYPES_OF_CRITTERS; t++){
		spr[t] = array[FRAMES_PER_CRITTER] of ref Image;
		mask[t] = array[FRAMES_PER_CRITTER] of ref Image;
		flip[t] = array[FRAMES_PER_CRITTER] of ref Image;
		flipmask[t] = array[FRAMES_PER_CRITTER] of ref Image;
		for(f := 0; f < FRAMES_PER_CRITTER; f++){
			n := frames[t][f];
			spr[t][f] = d.open(sys->sprint("/icons/temple/wallpaperfish_%d.bit", n));
			mask[t][f] = d.open(sys->sprint("/icons/temple/wallpaperfish_%d.mask", n));
			flip[t][f] = mirror(d, spr[t][f]);
			flipmask[t][f] = mirror(d, mask[t][f]);
		}
	}

	crits = array[CRITTERS_NUM] of Critter;
	for(i := 0; i < CRITTERS_NUM; i++){
		dx := real(rn(65536) - 32768);
		if(dx < 0.0)
			dx -= 16384.0;		# the original's 0x4000 bias
		else
			dx += 16384.0;
		crits[i] = Critter(real rn(GR_WIDTH) * 65536.0,
			real rn(GR_HEIGHT) * 65536.0, dx,
			real(rn(65536) - 32768), rn(TYPES_OF_CRITTERS),
			rnreal() * real FRAMES_PER_CRITTER);
	}
	t0 = sys->millisec();

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
	<-ticks =>
		redraw();
	}
}

mirror(d: ref Display, src: ref Image): ref Image
{
	if(src == nil)
		return nil;
	n := d.newimage(Rect((1-src.r.max.x, src.r.min.y),
		(1-src.r.min.x, src.r.max.y)), src.chans, 0, 0);
	if(n == nil)
		return nil;
	for(x := 0; x < src.r.dx(); x++)
		n.draw(Rect((n.r.min.x + src.r.dx()-1-x, n.r.min.y),
			(n.r.min.x + src.r.dx()-x, n.r.max.y)), src, nil,
			Point(src.r.min.x + x, src.r.min.y));
	return n;
}

now(): real
{
	return real(sys->millisec() - t0) / 1000.0;
}

# Adam/ASnd.HC Tri: 0.0 - 1.0 - 0.0
tri(t, period: real): real
{
	if(period == 0.0)
		return 0.0;
	a := t;
	if(a < 0.0)
		a = -a;
	u := 2.0*math->fmod(a, period)/period;
	if(u <= 1.0)
		return u;
	return 2.0 - u;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	tS := now();
	img.draw(img.r, cyan, nil, Point(0, 0));

	# the water: one diagonal every twenty pixels, the rack sliding on a
	# triangle wave of the clock
	j := int(16.0 * tri(tS*10.0, 20.0));
	for(i := 0; i < h; i += 20){
		y := h - i - j;
		img.line(Point(o.x, o.y+y), Point(o.x+h-i-j, o.y+h),
			Draw->Endsquare, Draw->Endsquare, 0, brown, Point(0, 0));
	}

	for(i = 0; i < CRITTERS_NUM; i++){
		c := crits[i];
		# Limbo's int of a real rounds to nearest, so 3.7 would become
		# 4 and step off the end; the original's % is a truncation.
		fr := math->fmod(tS*4.0 + c.toffset, real FRAMES_PER_CRITTER);
		if(fr < 0.0)
			fr += real FRAMES_PER_CRITTER;
		f := int math->floor(fr);
		if(f < 0)
			f = 0;
		if(f >= FRAMES_PER_CRITTER)
			f = FRAMES_PER_CRITTER - 1;
		x := int(c.x/65536.0) % w;
		if(x < 0)
			x += w;
		y := int(c.y/65536.0) % h;
		if(y < 0)
			y += h;
		s := spr[c.ctype][f];
		mk := mask[c.ctype][f];
		if(c.dx < 0.0){			# DCF_JUST_MIRROR about x
			s = flip[c.ctype][f];
			mk = flipmask[c.ctype][f];
		}
		if(s != nil)
			img.draw(s.r.addpt(Point(o.x+x, o.y+y)), s, mk, s.r.min);
		c.x += c.dx;
		c.y += c.dy;
		crits[i] = c;
	}
	if(font != nil)
		img.text(Point(o.x, img.r.max.y - font.height), white, Point(0, 0),
			font, "any key exits");
	img.flush(Draw->Flushnow);
}

rn(n: int): int
{
	if(rand == nil)
		return sys->millisec() % n;
	return rand->rand(n);
}

rnreal(): real
{
	if(rand == nil)
		return real(sys->millisec() & 1023) / 1023.0;
	return real(rand->rand(1000000)) / 1000000.0;
}


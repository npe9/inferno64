implement Elephant;

# TempleOS Demo/Graphics/Elephant.HC — a scene, and one interpolation.
#
#	DrawIt:
#	  Sprite3(dc,100,pix_height-60, 0,$IB,"<3>",BI=3$);
#	  Sprite3(dc,194,pix_height-140,0,$IB,"<4>",BI=4$);
#	  Sprite3(dc,400,pix_height-10, 0,$IB,"<5>",BI=5$);
#	  Sprite3(dc, 50,pix_height-160,0,$IB,"<6>",BI=6$);
#	  tmps=SpriteInterpolate(Tri(tS,2.0),$IB,"<1>",BI=1$,$IB,"<2>",BI=2$);
#	  Sprite3(dc,0,pix_height,0,tmps);
#	Fs->text_attr=YELLOW<<4+BLACK;  "$$BG,LTCYAN$$%h31c",'\n';
#
# Four fixed sprites make the scene, and the elephant itself is two
# drawings blended by SpriteInterpolate on a triangle wave of period two
# seconds — one function call, and the animation is a tween between two
# hand-drawn frames rather than a cycle of them.  Because the blend is of
# vector elements, not pixels, the intermediate frames are drawings in
# their own right rather than cross-fades.
#
# The song is Terry's, four Play() strings looped.
#
# GAP: this port has the two frames as rasterised bitmaps rather than as
#      the vector element lists SpriteInterpolate blends, so it cross-
#      fades between them by alternating pixels in the blend ratio.  The
#      motion is the tween the original shows; the mechanism, which
#      interpolates coordinates and not colours, is not.

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

include "tone.m";
	tone: Tone;

Elephant: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
font: ref Font;
ltcyan, black: ref Image;
spr, msk: array of ref Image;		# bins 1..6
t0: int;
have_tone := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	tone = load Tone Tone->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS Elephant", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	ltcyan = d.color(int 16r55FFFFFF);	# "$$BG,LTCYAN$$"
	black = d.color(int 16r000000FF);
	spr = array[7] of ref Image;
	msk = array[7] of ref Image;
	for(i := 1; i <= 6; i++){
		spr[i] = d.open(sys->sprint("/icons/temple/elephant_%d.bit", i));
		msk[i] = d.open(sys->sprint("/icons/temple/elephant_%d.mask", i));
	}
	t0 = sys->millisec();

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	if(have_tone)
		spawn songtask();

	ticks := chan of int;
	spawn timer(ticks, 33);
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
		if((k & Keyboard->Keyup) != Keyboard->Keyup){
			if(have_tone)
				tone->stop();
			exit;
		}
	<-ticks =>
		redraw();
	}
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
	h := img.r.dy();
	img.draw(img.r, ltcyan, nil, Point(0, 0));

	# the scene, at the original's own coordinates
	blit(img, 3, o.x + 100, o.y + h - 60);
	blit(img, 4, o.x + 194, o.y + h - 140);
	blit(img, 5, o.x + 400, o.y + h - 10);
	blit(img, 6, o.x + 50, o.y + h - 160);

	# SpriteInterpolate(Tri(tS,2.0), <1>, <2>)
	t := tri(now(), 2.0);
	interp(img, o.x, o.y + h, t);

	if(font != nil)
		img.text(Point(o.x, img.r.max.y - font.height), black, Point(0, 0),
			font, sys->sprint("tween %4.2f    any key exits", t));
	img.flush(Draw->Flushnow);
}

blit(img: ref Image, n, x, y: int)
{
	if(spr[n] == nil)
		return;
	img.draw(spr[n].r.addpt(Point(x, y)), spr[n], msk[n], spr[n].r.min);
}

# The blend: an ordered pattern picks frame 2 over frame 1 in the ratio t,
# which is a cross-fade rather than the original's element interpolation.
interp(img: ref Image, x, y: int, t: real)
{
	if(spr[1] == nil || spr[2] == nil)
		return;
	if(t <= 0.02){
		blit(img, 1, x, y);
		return;
	}
	if(t >= 0.98){
		blit(img, 2, x, y);
		return;
	}
	blit(img, 1, x, y);
	# every nth column of frame 2 over frame 1
	step := int(1.0/t);
	if(step < 1)
		step = 1;
	s := spr[2];
	m := msk[2];
	for(c := 0; c < s.r.dx(); c += step)
		img.draw(Rect((x + s.r.min.x + c, y + s.r.min.y),
			(x + s.r.min.x + c + 1, y + s.r.max.y)), s, m,
			Point(s.r.min.x + c, s.r.min.y));
}

songtask()
{
	# "Randomly generate (by God :-)" — the four looped Play() strings
	for(;;){
		tone->play("4qG5eCGqE4A5FCeDF4qB");
		tone->play("4G5eCGqE4A5FCeDF4qB");
		tone->play("4B5DeF4G5etE4BAqBAetA5EDeE4G");
		tone->play("4qB5DeF4G5etE4BAqBAetA5EDeE4G");
	}
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}

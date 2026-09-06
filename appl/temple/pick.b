implement Pick;

# TempleOS Demo/Graphics/Pick.HC — picking with DCF_LOCATE_NEAREST.
#
#	dc->flags|=DCF_LOCATE_NEAREST;
#	dc->cur_x=ms.pos.x; dc->cur_y=ms.pos.y; dc->cur_z=0;
#	for (i=0;i<APPLES_NUM;i++) {
#	  Sprite3(dc,x[i],y[i],0,$IB,"<1>",BI=1$);
#	  if (dc->nearest_dist<=best_dist) { best_dist=...; best_apple=i; }
#	}
#	GrPrint(dc,FONT_WIDTH,FONT_HEIGHT,"Dist Squared:%d",cur_dist);
#
# 128 apples and the neat idea that picking needs no hit-test geometry at
# all.  Setting DCF_LOCATE_NEAREST makes the device context measure, for
# everything drawn through it, the squared distance from the cursor to
# the nearest pixel that was actually painted — so drawing the sprites is
# the pick.  The distance is squared throughout because, as the original's
# comment says, Sqrt is expensive and the comparison does not need it.
#
# Left button grabs the nearest apple and drags it, keeping the offset
# from where it was grabbed, until the button is released.  A key exits.
#
# Here the measurement is over the sprite's mask — the pixels that would
# really be painted — which is what DCF_LOCATE_NEAREST counts.  It is done
# once per apple per frame, as the original does it.

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

include "rand.m";
	rand: Rand;

Pick: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

APPLES_NUM: con 128;
FW: con 8;
FH: con 8;
GR_WIDTH: con 640;
GR_HEIGHT: con 480;

win: ref Window;
font: ref Font;
white, black: ref Image;
apple, applemask: ref Image;
mpx, mpy: array of int;		# the mask's set pixels, precomputed once
ax, ay: array of int;
curapple := 0;
curdist := 0;
dragging := 0;
dx, dy: int;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS Pick", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	white = d.color(int 16rFFFFFFFF);
	black = d.color(int 16r000000FF);
	apple = d.open("/icons/temple/pick_1.bit");
	applemask = d.open("/icons/temple/pick_1.mask");
	loadmask();

	ax = array[APPLES_NUM] of int;
	ay = array[APPLES_NUM] of int;
	for(i := 0; i < APPLES_NUM; i++){
		ax[i] = rn(GR_WIDTH);
		ay[i] = rn(GR_HEIGHT - FH*3) + FH*3;
	}

	win.reshape(Rect((0, 0), (GR_WIDTH, GR_HEIGHT)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	redraw(Point(0, 0));
	ms := Point(0, 0);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		redraw(ms);
	k := <-win.ctxt.kbd =>
		if((k & Keyboard->Keyup) != Keyboard->Keyup)
			exit;
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		img := win.image;
		if(img == nil)
			continue;
		ms = Point(p.xy.x - img.r.min.x, p.xy.y - img.r.min.y);
		if(p.buttons & 1){
			if(!dragging){
				# MSG_MS_L_DOWN: the pick is whatever the last
				# frame's nearest was
				dragging = 1;
				dx = ax[curapple] - ms.x;
				dy = ay[curapple] - ms.y;
			}
			ax[curapple] = ms.x + dx;
			ay[curapple] = ms.y + dy;
		}else
			dragging = 0;
		redraw(ms);
	}
}

loadmask()
{
	if(applemask == nil)
		return;
	mw := applemask.r.dx();
	mh := applemask.r.dy();
	stride := (mw + 7) / 8;
	buf := array[stride*mh] of byte;
	if(applemask.readpixels(applemask.r, buf) <= 0)
		return;
	n := 0;
	for(y := 0; y < mh; y++)
		for(x := 0; x < mw; x++)
			if((int buf[y*stride + x/8] & (16r80 >> (x&7))) != 0)
				n++;
	mpx = array[n] of int;
	mpy = array[n] of int;
	n = 0;
	for(y = 0; y < mh; y++)
		for(x = 0; x < mw; x++)
			if((int buf[y*stride + x/8] & (16r80 >> (x&7))) != 0){
				mpx[n] = applemask.r.min.x + x;
				mpy[n] = applemask.r.min.y + y;
				n++;
			}
}

# DCF_LOCATE_NEAREST: the squared distance from the cursor to the nearest
# pixel this sprite would actually paint, at this position.
neardist(at: Point, cur: Point, sofar: int): int
{
	if(mpx == nil)
		return 16r7FFFFFFF;
	# an apple whose whole rect is already further than the best found
	# cannot win: skip it without touching a pixel.  Exact, not a
	# heuristic — the rect contains every pixel the mask can set.
	r := applemask.r.addpt(at);
	ddx := 0;
	if(cur.x < r.min.x) ddx = r.min.x - cur.x;
	else if(cur.x > r.max.x) ddx = cur.x - r.max.x;
	ddy := 0;
	if(cur.y < r.min.y) ddy = r.min.y - cur.y;
	else if(cur.y > r.max.y) ddy = cur.y - r.max.y;
	if(ddx*ddx + ddy*ddy > sofar)
		return 16r7FFFFFFF;
	best := 16r7FFFFFFF;
	for(i := 0; i < len mpx; i++){
		px := at.x + mpx[i] - cur.x;
		py := at.y + mpy[i] - cur.y;
		d := px*px + py*py;
		if(d < best)
			best = d;
	}
	return best;
}

redraw(ms: Point)
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	img.draw(img.r, white, nil, Point(0, 0));
	best := 16r7FFFFFFF;
	bestapple := 0;
	for(i := 0; i < APPLES_NUM; i++){
		at := Point(ax[i], ay[i]);
		if(apple != nil)
			img.draw(apple.r.addpt(at.add(o)), apple, applemask, apple.r.min);
		d := neardist(at, ms, best);
		if(d <= best){			# <=, as the original has it
			best = d;
			bestapple = i;
		}
	}
	if(!dragging){
		curapple = bestapple;
		curdist = best;
	}
	if(font != nil){
		img.text(Point(o.x + FW, o.y + FH), black, Point(0, 0), font,
			sys->sprint("Dist Squared:%d", curdist));
		img.text(Point(o.x, img.r.max.y - font.height), black, Point(0, 0),
			font, "drag an apple with the left button; any key exits");
	}
	img.flush(Draw->Flushnow);
}

rn(n: int): int
{
	if(rand == nil)
		return sys->millisec() % n;
	return rand->rand(n);
}

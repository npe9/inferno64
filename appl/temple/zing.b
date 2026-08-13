implement Zing;

# TempleOS Demo/Games/Zing.HC — bow and arrow toy
# LMB drag in bow box to aim; release to shoot; Enter restart; q quit
# GAP: no Sprite3ZB arrow art / Gr2BSpline3 — lines + triangle head;
#      no mouse clamp-to-box during animate task

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "math.m";
	math: Math;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "rand.m";
	rand: Rand;

include "tone.m";
	tone: Tone;

Zing: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
black, brown, red, white: ref Image;
box_x0, box_y0, box_x1, box_y1: int;
bow_x, bow_y: real;
bow_drawn := 0;
bow_ang := 0.0;
mx, my: int;
prev_btn := 0;
have_tone := 0;
last_tick: int;

ax, ay, adx, ady: array of real;
narrows := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	tone = load Tone Tone->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS Zing", Wmclient->Appl);
	d := win.display;
	black = d.color(Draw->Black);
	brown = d.color(int 16r8B4513FF);
	red = d.color(Draw->Red);
	white = d.color(Draw->White);
	last_tick = sys->millisec();
	reset();
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 10);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		handleptr(p);
	k := <-win.ctxt.kbd =>
		case k {
		16r1b or 'q' or 'Q' =>
			if(have_tone) tone->stop();
			exit;
		'\n' =>
			reset();
		}
	<-ticks =>
		animate();
		redraw();
	}
}

reset()
{
	img := win.image;
	w := 640; h := 480;
	if(img != nil){
		w = img.r.dx();
		h = img.r.dy();
	}
	box_x0 = 7 * w / 16;
	box_y0 = 6 * h / 8;
	box_x1 = 9 * w / 16;
	box_y1 = 7 * h / 8;
	bow_x = real(box_x0 + box_x1) / 2.0;
	bow_y = real(box_y0 + box_y1) / 2.0;
	bow_drawn = 0;
	bow_ang = -math->Pi / 2.0;
	narrows = 0;
	ax = array[0] of real;
	ay = array[0] of real;
	adx = array[0] of real;
	ady = array[0] of real;
	mx = int bow_x;
	my = int bow_y;
}

handleptr(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil)
		return;
	mx = p.xy.x - img.r.min.x;
	my = p.xy.y - img.r.min.y;
	btn := p.buttons & 1;
	if(btn && !prev_btn){
		bow_x = real(clampi(mx, box_x0, box_x1));
		bow_y = real(clampi(my, box_y0, box_y1));
		bow_drawn = 1;
	}
	if(!btn && prev_btn && bow_drawn){
		sx := clampi(mx, box_x0, box_x1);
		sy := clampi(my, box_y0, box_y1);
		if(sx != int bow_x || sy != int bow_y)
			shoot(real(sx), real(sy));
		bow_drawn = 0;
	}
	prev_btn = btn;
}

shoot(sx, sy: real)
{
	n := narrows;
	narrows = n + 1;
	ax = extend(ax, n);
	ay = extend(ay, n);
	adx = extend(adx, n);
	ady = extend(ady, n);
	ax[n] = sx;
	ay[n] = sy;
	adx[n] = 10.0 * (bow_x - sx);
	ady[n] = 10.0 * (bow_y - sy);
	if(have_tone)
		tone->beep(110, 50);
}

extend(a: array of real, n: int): array of real
{
	b := array[n + 1] of real;
	for(i := 0; i < n; i++)
		b[i] = a[i];
	return b;
}

animate()
{
	now := sys->millisec();
	dt := real(now - last_tick) / 1000.0;
	if(dt <= 0.0)
		dt = 0.01;
	last_tick = now;
	keep := 0;
	for(i := 0; i < narrows; i++){
		ax[i] += adx[i] * dt;
		ay[i] += ady[i] * dt;
		if(ax[i] >= -20.0 && ax[i] < 660.0 && ay[i] >= -20.0 && ay[i] < 500.0){
			if(keep != i){
				ax[keep] = ax[i];
				ay[keep] = ay[i];
				adx[keep] = adx[i];
				ady[keep] = ady[i];
			}
			keep++;
		}
	}
	narrows = keep;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	img.draw(img.r, white, nil, Point(0, 0));
	img.draw(Rect((o.x + box_x0, o.y + box_y0), (o.x + box_x1, o.y + box_y1)),
		red, nil, Point(0, 0));

	x := real(clampi(mx, box_x0, box_x1));
	y := real(clampi(my, box_y0, box_y1));
	dx := bow_x - x;
	dy := bow_y - y;
	if(bow_drawn && (dx != 0.0 || dy != 0.0))
		bow_ang = math->atan2(dy, dx);
	else if(!bow_drawn){
		bow_x = x;
		bow_y = y;
	}

	draw_len := math->sqrt(dx * dx + dy * dy);
	str_w := draw_len / 3.0;
	str_h := math->sqrt(3600.0 - str_w * str_w);
	if(str_h != str_h)	# NaN guard
		str_h = 0.0;

	# bow string
	img.line(pt(o, x - str_h / 2.0 * math->cos(bow_ang + math->Pi / 2.0) + str_w * math->cos(bow_ang),
			y - str_h / 2.0 * math->sin(bow_ang + math->Pi / 2.0) + str_w * math->sin(bow_ang)),
		pt(o, x, y), Draw->Endsquare, Draw->Endsquare, 1, black, Point(0, 0));
	img.line(pt(o, x + str_h / 2.0 * math->cos(bow_ang + math->Pi / 2.0) + str_w * math->cos(bow_ang),
			y + str_h / 2.0 * math->sin(bow_ang + math->Pi / 2.0) + str_w * math->sin(bow_ang)),
		pt(o, x, y), Draw->Endsquare, Draw->Endsquare, 1, black, Point(0, 0));

	# bow limbs (polyline stand-in for BSpline)
	prev: Point;
	prev2: Point;
	for(t := 0; t <= 4; t++){
		tt := real(t) / 4.0;
		bx := x - (1.0 - 0.25 * tt) * str_h / 2.0 * math->cos(bow_ang + math->Pi / 2.0)
			+ (draw_len / 2.0 * tt + str_w) * math->cos(bow_ang);
		by := y - (1.0 - 0.25 * tt) * str_h / 2.0 * math->sin(bow_ang + math->Pi / 2.0)
			+ (draw_len / 2.0 * tt + str_w) * math->sin(bow_ang);
		if(t > 0){
			img.line(prev, pt(o, bx, by), Draw->Endsquare, Draw->Endsquare, 2, brown, Point(0, 0));
			img.line(prev2, pt(o, x + (bx - x), y + (by - y)), Draw->Endsquare, Draw->Endsquare, 2, brown, Point(0, 0));
		}
		prev = pt(o, bx, by);
		prev2 = pt(o, x + (bx - x), y + (by - y));
	}

	if(bow_drawn)
		drawarrow(img, o, int bow_x, int bow_y, bow_ang);

	for(i := 0; i < narrows; i++){
		ang := math->atan2(ady[i], adx[i]);
		drawarrow(img, o, int ax[i], int ay[i], ang);
	}
	img.flush(Draw->Flushnow);
}

drawarrow(img: ref Image, o: Point, x, y: int, ang: real)
{
	tip := pt(o, real(x), real(y));
	tail := pt(o, real(x) - 18.0 * math->cos(ang), real(y) - 18.0 * math->sin(ang));
	img.line(tail, tip, Draw->Endsquare, Draw->Endsquare, 2, black, Point(0, 0));
	lx := tip.x - int(6.0 * math->cos(ang - math->Pi / 2.0));
	ly := tip.y - int(6.0 * math->sin(ang - math->Pi / 2.0));
	rx := tip.x - int(6.0 * math->cos(ang + math->Pi / 2.0));
	ry := tip.y - int(6.0 * math->sin(ang + math->Pi / 2.0));
	img.line(tip, Point(lx, ly), Draw->Endsquare, Draw->Endsquare, 1, black, Point(0, 0));
	img.line(tip, Point(rx, ry), Draw->Endsquare, Draw->Endsquare, 1, black, Point(0, 0));
}

pt(o: Point, x, y: real): Point
{
	return Point(o.x + int x, o.y + int y);
}

clampi(v, lo, hi: int): int
{
	if(v < lo) return lo;
	if(v > hi) return hi;
	return v;
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}

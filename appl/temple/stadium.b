implement Stadium;

# TempleOS Demo/Games/Stadium/Stadium.HC — peg wandering fans
# LMB throw ball; Enter restart; q quit
# GAP: no GRRead StadiumBG / Sprite3ZB — procedural field + circle fans;
#      ball scale via ellipse radius not Mat4x4 transform

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

Stadium: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

FANS: con 10;
BALL_MS: con 200;

win: ref Window;
sky, grass, dirt, white, red, black, brown, yellow: ref Image;
fx, fy, fang: array of real;
fhit: array of int;
ball_t := 0;
target_x, target_y: int;
pitcher_x, pitcher_y: int;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS Stadium", Wmclient->Appl);
	d := win.display;
	sky = d.color(int 16r87CEEBFF);
	grass = d.color(Draw->Green);
	dirt = d.color(int 16r8B4513FF);
	white = d.color(Draw->White);
	red = d.color(Draw->Red);
	black = d.color(Draw->Black);
	brown = d.color(int 16r654321FF);
	yellow = d.color(Draw->Yellow);
	fx = array[FANS] of real;
	fy = array[FANS] of real;
	fang = array[FANS] of real;
	fhit = array[FANS] of int;
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
	pitcher_x = w / 2;
	pitcher_y = h;
	ball_t = 0;
	for(i := 0; i < FANS; i++){
		fx[i] = real(rn(w));
		fy[i] = 50.0;
		fang[i] = 0.0;
		fhit[i] = 0;
	}
}

handleptr(p: ref Draw->Pointer)
{
	if((p.buttons & 1) == 0)
		return;
	img := win.image;
	if(img == nil)
		return;
	target_x = p.xy.x - img.r.min.x;
	target_y = p.xy.y - img.r.min.y;
	ball_t = sys->millisec();
}

animate()
{
	img := win.image;
	if(img == nil)
		return;
	w := img.r.dx();
	bx := 0.0; by := 0.0;
	have_ball := 0;
	if(ball_t != 0){
		t0 := real(sys->millisec() - ball_t) / real(BALL_MS);
		if(t0 > 1.0)
			ball_t = 0;
		else{
			have_ball = 1;
			bx = t0 * real(target_x) + (1.0 - t0) * real(pitcher_x);
			by = t0 * real(target_y) + (1.0 - t0) * real(pitcher_y);
			scale := 1.5 - t0;
			bx /= scale;
			by /= scale;
		}
	}
	for(i := 0; i < FANS; i++){
		if(have_ball){
			dx := fx[i] - bx;
			dy := fy[i] - by;
			if(dx * dx + dy * dy < 200.0){
				fhit[i] = 1;
				fang[i] = -fang[i];
			}
		}
		if(!fhit[i]){
			fx[i] += real(sign(rn(3) - 1));
			fy[i] += real(sign(rn(3) - 1));
			fang[i] += real(sign(rn(3) - 1)) / 25.0;
			if(fx[i] < 0.0 || fx[i] >= real(w))
				fx[i] = real(w / 2);
			if(fy[i] < 10.0 || fy[i] >= 100.0)
				fy[i] = 50.0;
			if(fang[i] < -0.75)
				fang[i] = 0.0;
			if(fang[i] > 0.75)
				fang[i] = 0.0;
		}
	}
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	drawbg(img, o, w, h);
	for(i := 0; i < FANS; i++)
		drawfan(img, o, int fx[i], int fy[i], fang[i], fhit[i]);
	if(ball_t != 0){
		t0 := real(sys->millisec() - ball_t) / real(BALL_MS);
		if(t0 <= 1.0){
			bx := t0 * real(target_x) + (1.0 - t0) * real(pitcher_x);
			by := t0 * real(target_y) + (1.0 - t0) * real(pitcher_y);
			scale := 1.5 - t0;
			bx /= scale;
			by /= scale;
			rad := int(6.0 * scale);
			if(rad < 2)
				rad = 2;
			img.ellipse(Point(o.x + int bx, o.y + int by), rad, rad, 0, white, Point(0, 0));
		}
	}
	img.draw(Rect((o.x + 8, o.y + 16), (o.x + 120, o.y + 28)), red, nil, Point(0, 0));
	img.flush(Draw->Flushnow);
}

drawbg(img: ref Image, o: Point, w, h: int)
{
	img.draw(Rect((o.x, o.y), (o.x + w, o.y + h * 2 / 5)), sky, nil, Point(0, 0));
	img.draw(Rect((o.x, o.y + h * 2 / 5), (o.x + w, o.y + h)), grass, nil, Point(0, 0));
	img.draw(Rect((o.x, o.y + h - 24), (o.x + w, o.y + h)), dirt, nil, Point(0, 0));
	for(i := 0; i < 12; i++){
		x0 := o.x + i * w / 12;
		img.draw(Rect((x0, o.y + 20), (x0 + w / 12 - 2, o.y + h * 2 / 5 - 4)), brown, nil, Point(0, 0));
	}
	img.line(Point(o.x, o.y + h * 2 / 5), Point(o.x + w, o.y + h * 2 / 5),
		Draw->Endsquare, Draw->Endsquare, 1, white, Point(0, 0));
}

drawfan(img: ref Image, o: Point, x, y: int, ang: real, hit: int)
{
	col := yellow;
	if(hit)
		col = red;
	img.ellipse(Point(o.x + x, o.y + y), 8, 8, 0, col, Point(0, 0));
	dx := int(10.0 * math->cos(ang));
	dy := int(10.0 * math->sin(ang));
	img.line(Point(o.x + x, o.y + y), Point(o.x + x + dx, o.y + y + dy),
		Draw->Endsquare, Draw->Endsquare, 1, black, Point(0, 0));
}

sign(v: int): int
{
	if(v < 0) return -1;
	if(v > 0) return 1;
	return 0;
}

rn(n: int): int
{
	if(rand == nil)
		return sys->millisec() % n;
	return rand->rand(n);
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}

implement Halogen;

# TempleOS Demo/Games/Halogen.HC — perspective road; left/right steer
# arrows/a/d steer; up/w accelerate; q quit

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "keyboard.m";

include "rand.m";
	rand: Rand;

Halogen: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

ROAD_NUM: con 512;
ROAD_W2: con 200;
CAR_W2: con 40;

win: ref Window;
road: array of int;
road_ptr := 0;
road_trend := 0;
car_x := 0;
speed := 0.0;
distance := 0.0;
crash := 0;
grey, white, yellow, black, red: ref Image;

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

	win = wmclient->window(ctxt, "TempleOS Halogen", Wmclient->Appl);
	d := win.display;
	grey = d.color(Draw->Grey);
	white = d.color(Draw->White);
	yellow = d.color(Draw->Yellow);
	black = d.color(int 16r333333FF);
	red = d.color(Draw->Red);
	reset();
	win.reshape(Rect((0, 0), (640, 400)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 16);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		case k {
		16r1b or 'q' or 'Q' =>
			exit;
		'r' or 'R' or '\n' =>
			reset();
		Keyboard->Left or 'a' or 'A' =>
			car_x -= 8;
		Keyboard->Right or 'd' or 'D' =>
			car_x += 8;
		Keyboard->Up or 'w' or 'W' =>
			speed += 0.5;
			if(speed > 12.0)
				speed = 12.0;
		Keyboard->Down or 's' or 'S' =>
			speed -= 0.5;
			if(speed < 0.0)
				speed = 0.0;
		}
	<-ticks =>
		if(!crash){
			update();
			redraw();
		}
	}
}

reset()
{
	road = array[ROAD_NUM] of int;
	road_trend = 0;
	road_ptr = 0;
	car_x = 0;
	speed = 2.0;
	distance = 0.0;
	crash = 0;
	x := 0;
	for(i := 0; i < ROAD_NUM; i++){
		road[i] = x;
		road_trend = clamp(road_trend + sign(rn(3)-1), -5, 5);
		x += road_trend / 3;
	}
}

update()
{
	distance += speed;
	while(distance > 1.0){
		road_trend = clamp(road_trend + sign(rn(3)-1), -5, 5);
		prev := road[(road_ptr - 1 + ROAD_NUM) & (ROAD_NUM - 1)];
		road[road_ptr & (ROAD_NUM - 1)] = prev + road_trend / 3;
		road_ptr++;
		distance -= 1.0;
	}
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, black, nil, Point(0, 0));
	w := img.r.dx();
	h := img.r.dy();
	o := img.r.min;
	xx := w/2 - car_x + road[road_ptr & (ROAD_NUM-1)];
	for(i := 0; i < ROAD_NUM; i++){
		x := w/2 - car_x + road[(i+road_ptr) & (ROAD_NUM-1)];
		y := h - i/2;
		if(y < h/2)
			break;
		lw := ROAD_W2 - (2*i)/5;
		if(lw < 10)
			lw = 10;
		img.draw(Rect((o.x+x-lw, o.y+y), (o.x+x-lw+1, o.y+y+1)), grey, nil, Point(0, 0));
		img.draw(Rect((o.x+x+lw, o.y+y), (o.x+x+lw+1, o.y+y+1)), grey, nil, Point(0, 0));
	}
	# car hood lines
	xl := w/2 - CAR_W2;
	xr := w/2 + CAR_W2;
	if(xl < xx - ROAD_W2 || xr > xx + ROAD_W2)
		crash = 1;
	img.line(Point(o.x+xl-10, o.y+h), Point(o.x+xl-40, o.y+h-80),
		Draw->Endsquare, Draw->Endsquare, 1, white, Point(0, 0));
	img.line(Point(o.x+xl+10, o.y+h), Point(o.x+xl+40, o.y+h-80),
		Draw->Endsquare, Draw->Endsquare, 1, white, Point(0, 0));
	img.line(Point(o.x+xr-10, o.y+h), Point(o.x+xr-40, o.y+h-80),
		Draw->Endsquare, Draw->Endsquare, 1, white, Point(0, 0));
	img.line(Point(o.x+xr+10, o.y+h), Point(o.x+xr+40, o.y+h-80),
		Draw->Endsquare, Draw->Endsquare, 1, white, Point(0, 0));
	if(crash){
		# crude text via lines — use fillrect banner
		img.draw(Rect((o.x+w/2-60, o.y+h/2-10), (o.x+w/2+60, o.y+h/2+10)), red, nil, Point(0, 0));
	}
	img.flush(Draw->Flushnow);
}

clamp(v, lo, hi: int): int
{
	if(v < lo) return lo;
	if(v > hi) return hi;
	return v;
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

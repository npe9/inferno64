implement Halogen;

# TempleOS Demo/Games/Halogen.HC — perspective road; left/right steer
# arrows/wasd drive (held keys act continuously); Enter/r restart; Esc/q quit
#
# GAP: the original's MenuPush File/Play menu bar (Abort/Exit/Restart/
# Accelerate/Deccellerate/Left/Right) is not replicated; its key bindings
# are mapped directly on the keyboard instead.

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

include "tone.m";
	tone: Tone;
include "grpalette.m";
	grpal: Grpalette;
include "frameclock.m";
	fclock: Frameclock;

Halogen: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# The port's own simulation step, in milliseconds.  The frame clock
# runs at 60fps and this many milliseconds of simulation are run for
# each frame's worth of real time, so the picture is smooth and the
# simulation keeps the speed it was written for.
FCSTEP: con 10;
# The most substeps one frame may run: enough to cover a frame of
# real time at this step, with headroom.  A fixed cap is wrong -
# four substeps covers 40ms at FCSTEP 10 and only 4ms at FCSTEP 1.
FCMAX: con 2 + 20/FCSTEP;
fcacc := 0;

ROAD_NUM: con 512;
ROAD_W2: con 200;	# ROAD_WIDTH_BY_2
CAR_W2: con 100;	# CAR_WIDTH_BY_2
FONT_W: con 8;
FONT_H: con 8;

win: ref Window;
road: array of int;
road_ptr := 0;
road_trend := 0;
car_x := 0;
speed := 0.0;
distance := 0.0;
t_last := 0.0;
crash := 0;
heldsc := 0;		# most recent held drive key (0 = none), like the original's sc
have_tone := 0;
sndfreq := -1;		# last frequency handed to tone->snd (-1 = off)
ltgray, white, yellow, black, dkgray: ref Image;
font: ref Font;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	tone = load Tone Tone->PATH;
	fclock = load Frameclock Frameclock->PATH;
	fclock->init();
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS Halogen", Wmclient->Appl);
	d := win.display;
	# the exact TempleOS palette entries this program touches
	black = d.color(grpal->value(Grpalette->BLACK));	# BLACK task background
	dkgray = d.color(grpal->value(Grpalette->DKGRAY));	# DKGRAY sky
	ltgray = d.color(grpal->value(Grpalette->LTGRAY));	# LTGRAY road dots
	white = d.color(grpal->value(Grpalette->WHITE));	# WHITE headlight cones
	yellow = d.color(grpal->value(Grpalette->YELLOW));	# YELLOW "Game Over"
	font = Font.open(d, "/fonts/temple/temple.font");
	reset();
	win.reshape(Rect((0, 0), (640, 400)));
	win.onscreen("place");
	win.startinput("kbd" :: "keyup" :: "ptr" :: nil);

	# The original loops ScanMsg + Sleep(10): ~100 iterations/sec, each
	# applying the held key once (car_x±1, speed±1) and advancing the road
	# by speed * real elapsed seconds. We tick at the same 10ms, so the
	# per-tick constants carry over unchanged.
	ticks := chan of int;
	spawn fclock->ticker(ticks, 60);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		key(k);
	dtms := <-ticks =>
		fcacc += dtms;
		if(fcacc > FCSTEP*FCMAX)
			fcacc = FCSTEP*FCMAX;
		for(fcn := 0; fcacc >= FCSTEP && fcn < FCMAX; fcn++){
			# held key acts every tick, even after a crash (the original's
			# sc switch runs before the crash check, so you can pan the
			# frozen road)
			case heldsc {
			Keyboard->Left =>
				car_x--;
			Keyboard->Right =>
				car_x++;
			Keyboard->Up =>
				speed += 1.0;
				if(speed > 200.0)
					speed = 200.0;
			Keyboard->Down =>
				speed -= 1.0;
				if(speed < 0.0)
					speed = 0.0;
			}
			if(!crash)
				update();
			enginesound();
			fcacc -= FCSTEP;
		}
		redraw();
	}
}

key(k: int)
{
	if((k & Keyboard->Keyup) == Keyboard->Keyup){
		# releasing any drive key stops the current action
		# (the original zeroes its single sc on any arrow release)
		case k & ~Keyboard->Keyup {
		Keyboard->Left & 16r7ff or 'a' or 'A' or
		Keyboard->Right & 16r7ff or 'd' or 'D' or
		Keyboard->Up & 16r7ff or 'w' or 'W' or
		Keyboard->Down & 16r7ff or 's' or 'S' =>
			heldsc = 0;
		}
		return;
	}
	case k {
	16r1b or 'q' or 'Q' =>
		if(have_tone)
			tone->stop();
		exit;
	'r' or 'R' or '\n' =>
		reset();
	Keyboard->Left or 'a' or 'A' =>
		heldsc = Keyboard->Left;
	Keyboard->Right or 'd' or 'D' =>
		heldsc = Keyboard->Right;
	Keyboard->Up or 'w' or 'W' =>
		heldsc = Keyboard->Up;
	Keyboard->Down or 's' or 'S' =>
		heldsc = Keyboard->Down;
	}
}

reset()
{
	road = array[ROAD_NUM] of int;
	road_trend = 0;
	road_ptr = 0;
	car_x = 0;
	speed = 0.0;		# the original starts stopped; you must accelerate
	distance = 0.0;
	crash = 0;
	x := 0;
	for(i := 0; i < ROAD_NUM; i++){
		road[i] = x;
		road_trend = clamp(road_trend + sign(rn(3)-1), -5, 5);
		x += road_trend / 3;
	}
	t_last = real sys->millisec() / 1000.0;
}

update()
{
	# distance advances by speed * elapsed real seconds, exactly as the
	# original's UpdateRoad (tS is seconds as F64)
	t0 := real sys->millisec() / 1000.0;
	distance += speed * (t0 - t_last);
	t_last = t0;
	while(distance > 1.0){
		road_trend = clamp(road_trend + sign(rn(3)-1), -5, 5);
		prev := road[(road_ptr - 1 + ROAD_NUM) & (ROAD_NUM - 1)];
		road[road_ptr & (ROAD_NUM - 1)] = prev + road_trend / 3;
		road_ptr++;
		distance -= 1.0;
	}
}

# original: Snd(Freq2Ona(speed+10)) while moving — i.e. a tone of
# (speed+10) Hz tracking the throttle; silent when stopped or crashed
enginesound()
{
	if(!have_tone)
		return;
	want := -1;
	if(!crash && speed > 0.0)
		want = int speed + 10;
	if(want == sndfreq)
		return;
	sndfreq = want;
	if(want < 0)
		tone->stop();
	else
		tone->snd(want);
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	w := img.r.dx();
	h := img.r.dy();
	o := img.r.min;
	# Init paints the top (TEXT_ROWS-1)/2 8-pixel text rows DKGRAY over
	# the BLACK task background: gray sky above, black ground below
	sky := ((h/FONT_H - 1) / 2) * FONT_H;
	img.draw(Rect((o.x, o.y), (o.x+w, o.y+sky)), dkgray, nil, Point(0, 0));
	img.draw(Rect((o.x, o.y+sky), (o.x+w, o.y+h)), black, nil, Point(0, 0));

	xx := w/2 - car_x + road[road_ptr & (ROAD_NUM-1)];
	for(i := 0; i < ROAD_NUM; i++){
		x := w/2 - car_x + road[(i+road_ptr) & (ROAD_NUM-1)];
		y := int (real h - 0.5*real i);
		if(y < (h+FONT_H)/2)
			break;
		# HolyC rounds F64->I64, as Limbo's int cast does
		xr := int (real x + real ROAD_W2 - 0.4*real i);
		xl := int (real x - real ROAD_W2 + 0.4*real i);
		img.draw(Rect((o.x+xr, o.y+y), (o.x+xr+1, o.y+y+1)), ltgray, nil, Point(0, 0));
		img.draw(Rect((o.x+xl, o.y+y), (o.x+xl+1, o.y+y+1)), ltgray, nil, Point(0, 0));
	}
	# headlight cones; crossing a road edge is the crash
	cl := w/2 - CAR_W2;
	cr := w/2 + CAR_W2;
	if(cl < xx - ROAD_W2 || cr > xx + ROAD_W2)
		crash = 1;
	cone(img, o, cl, h);
	cone(img, o, cr, h);
	if(crash != 0 && font != nil)
		img.text(Point(o.x + w/2 - FONT_W*4, o.y + (h-FONT_H)/2),
			yellow, Point(0, 0), font, "Game Over");
	img.flush(Draw->Flushnow);
}

# GrLine(x-10,h, x-40,h-100); GrLine(x+10,h, x+40,h-100)
cone(img: ref Image, o: Point, x, h: int)
{
	img.line(Point(o.x+x-10, o.y+h), Point(o.x+x-40, o.y+h-100),
		Draw->Endsquare, Draw->Endsquare, 0, white, Point(0, 0));
	img.line(Point(o.x+x+10, o.y+h), Point(o.x+x+40, o.y+h-100),
		Draw->Endsquare, Draw->Endsquare, 0, white, Point(0, 0));
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


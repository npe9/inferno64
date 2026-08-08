implement Varoom;

# TempleOS Demo/Games/Varoom.HC — oval-track racing
# arrows/wasd steer+accelerate; Enter restart; q quit
#
# GAP: no 3D Mat4x4 track strips / car sprites / MP JobQue rendering
# GAP: top-down view not behind-the-car; 4 cars not 8; no engine Snd loop
# GAP: no minimap track_map / bush scenery; RegWrite best_score not persisted

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

include "keyboard.m";

include "rand.m";
	rand: Rand;

include "tone.m";
	tone: Tone;

Varoom: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

PI: con 3.141592653589793;
TRACK_PTS: con 360;
CARS: con 4;
TRACK_RX: con 220;
TRACK_RZ: con 140;
TRACK_W: con 42;
CAR_LEN: con 14;

TrackPt: adt { x, z, ang, dist: real; };

Car: adt {
	x, z, ang, steer, speed: real;
	idx: int;
};

win: ref Window;
ink: array of ref Image;
track: array of TrackPt;
cars: array of Car;
track_len: real;
distance: real;
game_over := 0;
won := 0;
t0, tf: real;
best_score := 9999.0;
have_tone := 0;

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

	win = wmclient->window(ctxt, "TempleOS Varoom", Wmclient->Appl);
	d := win.display;
	ink = array[16] of ref Image;
	cols := array[] of {
		Draw->Black, Draw->Blue, Draw->Green, Draw->Cyan,
		Draw->Red, Draw->Magenta, Draw->Darkyellow, Draw->Grey,
		int 16r444444FF, Draw->Paleblue, Draw->Palegreen, Draw->Palebluegreen,
		int 16rFF8888FF, int 16rFF88FFFF, Draw->Yellow, Draw->White
	};
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);

	track = array[TRACK_PTS] of TrackPt;
	cars = array[CARS] of Car;
	game_init();
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 20);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	k := <-win.ctxt.kbd =>
		key(k);
	<-ticks =>
		simulate();
		redraw();
	}
}

game_init()
{
	build_track();
	for(i := 0; i < CARS; i++){
		d := track_len * real(i) / real(CARS);
		(idx, nil) := track_at_dist(d);
		tp := track[idx];
		sp := 0.0;
		if(i)
			sp = 1800.0 + 200.0 * real(i);
		cars[i] = Car(tp.x, tp.z, tp.ang, 0.0, sp, idx);
	}
	distance = 0.0;
	game_over = 0;
	won = 0;
	t0 = now();
	tf = 0.0;
}

build_track()
{
	cx := 320.0;
	cz := 240.0;
	d := 0.0;
	rx := real(TRACK_RX);
	rz := real(TRACK_RZ);
	for(i := 0; i < TRACK_PTS; i++){
		a := 2.0 * PI * real(i) / real(TRACK_PTS);
		px := cx + rx * math->cos(a);
		pz := cz + rz * math->sin(a);
		na := 2.0 * PI * real((i + 1) % TRACK_PTS) / real(TRACK_PTS);
		nx := cx + rx * math->cos(na);
		nz := cz + rz * math->sin(na);
		ang := math->atan2(nz - pz, nx - px);
		if(i > 0)
			d += seg_len(track[i-1].x, track[i-1].z, px, pz);
		track[i] = TrackPt(px, pz, ang, d);
	}
	track_len = d + seg_len(track[TRACK_PTS-1].x, track[TRACK_PTS-1].z, track[0].x, track[0].z);
}

key(k: int)
{
	if(game_over && k != '\n' && k != 'r' && k != 'R' &&
	   k != 16r1b && k != 'q' && k != 'Q')
		return;
	p := cars[0];
	case k {
	16r1b or 'q' or 'Q' =>
		if(have_tone)
			tone->stop();
		exit;
	'\n' or 'r' or 'R' =>
		game_init();
	Keyboard->Left or 'a' or 'A' =>
		p.steer -= PI / 60.0;
	Keyboard->Right or 'd' or 'D' =>
		p.steer += PI / 60.0;
	Keyboard->Up or 'w' or 'W' =>
		p.speed += 250.0;
	Keyboard->Down or 's' or 'S' =>
		p.speed -= 750.0;
	}
	if(p.speed < 0.0)
		p.speed = 0.0;
	if(p.steer < -PI/3.0)
		p.steer = -PI/3.0;
	if(p.steer > PI/3.0)
		p.steer = PI/3.0;
	cars[0] = p;
}

simulate()
{
	if(game_over)
		return;
	p := cars[0];
	p.ang += 0.08 * p.steer;
	p.x += 0.01 * p.speed * math->cos(p.ang - PI/2.0);
	p.z += 0.01 * p.speed * math->sin(p.ang - PI/2.0);
	on := on_track(p.x, p.z);
	if(!on)
		p.speed *= 0.98;
	cars[0] = p;
	if(on)
		distance += 0.01 * p.speed;
	for(j := 1; j < CARS; j++){
		c := cars[j];
		(idx, nil) := nearest_track(c.x, c.z);
		tp := track[idx];
		tang := tp.ang;
		c.x += 0.01 * c.speed * math->cos(tang - PI/2.0);
		c.z += 0.01 * c.speed * math->sin(tang - PI/2.0);
		(idx2, nil) := nearest_track(c.x, c.z);
		c.idx = idx2;
		c.ang = track[idx2].ang;
		cars[j] = c;
	}
	hit2 := real(CAR_LEN) * real(CAR_LEN);
	for(ci := 1; ci < CARS; ci++){
		dx := cars[ci].x - p.x;
		dz := cars[ci].z - p.z;
		if(dx*dx + dz*dz < hit2){
			game_over = 1;
			won = 0;
			if(have_tone)
				tone->beep(22, 400);
			break;
		}
	}
	if(!game_over && distance >= track_len){
		game_over = 1;
		won = 1;
		tf = now();
		if(tf - t0 < best_score){
			best_score = tf - t0;
			if(have_tone)
				tone->beep(88, 200);
		}
	}
	if(have_tone && !game_over && on){
		f := int(12.0 * math->log(p.speed/500.0 + 0.7) / math->log(2.0));
		if(f < 20) f = 20;
		if(f > 200) f = 200;
		if(sys->millisec() % 80 < 20)
			tone->beep(f, 30);
	}
}

on_track(x, z: real): int
{
	(nil, d) := nearest_track(x, z);
	if(d <= real(TRACK_W) / 2.0)
		return 1;
	return 0;
}

nearest_track(x, z: real): (int, real)
{
	best := 0;
	bd := 1e9;
	for(i := 0; i < TRACK_PTS; i++){
		tp := track[i];
		dx := x - tp.x;
		dz := z - tp.z;
		d := dx*dx + dz*dz;
		if(d < bd){
			bd = d;
			best = i;
		}
	}
	return (best, math->sqrt(bd));
}

track_at_dist(d: real): (int, real)
{
	while(d >= track_len)
		d -= track_len;
	while(d < 0.0)
		d += track_len;
	for(i := 0; i < TRACK_PTS; i++)
		if(track[i].dist >= d)
			return (i, 0.0);
	return (0, 0.0);
}

seg_len(x1, z1, x2, z2: real): real
{
	dx := x2 - x1;
	dz := z2 - z1;
	return math->sqrt(dx*dx + dz*dz);
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	img.draw(img.r, ink[7], nil, Point(0, 0));
	halfw := real(TRACK_W) / 2.0;
	for(ti := 0; ti < TRACK_PTS; ti++){
		j := (ti + 1) % TRACK_PTS;
		a := track[ti];
		b := track[j];
		for(side := -1; side <= 1; side += 2){
			ox := real side * halfw * math->sin(a.ang);
			oz := real(-side) * halfw * math->cos(a.ang);
			img.line(Point(o.x + int(a.x + ox), o.y + int(a.z + oz)),
				Point(o.x + int(b.x + ox), o.y + int(b.z + oz)),
				Draw->Endsquare, Draw->Endsquare, 1, ink[14], Point(0, 0));
		}
		mid := ink[4];
		if((ti & 1) != 0)
			mid = ink[15];
		img.line(Point(o.x + int a.x, o.y + int a.z),
			Point(o.x + int b.x, o.y + int b.z),
			Draw->Endsquare, Draw->Endsquare, 1, mid, Point(0, 0));
	}
	for(ci := 0; ci < CARS; ci++){
		c := cars[ci];
		col := ink[13];
		if(ci == 0)
			col = ink[11];
		draw_car(img, o, c, col);
	}
	pct := int(100.0 * distance / track_len);
	if(pct > 100) pct = 100;
	if(pct < 0) pct = 0;
	img.draw(Rect((o.x + 10, o.y + h - 14), (o.x + 10 + (w-40)*pct/100, o.y + h - 8)), ink[11], nil, Point(0, 0));
	elapsed := now() - t0;
	if(game_over && won)
		elapsed = tf - t0;
	tw := int(real(w - 40) * elapsed / (best_score + 0.01));
	if(tw > w - 40) tw = w - 40;
	img.draw(Rect((o.x + 20, o.y + h - 24), (o.x + 20 + tw, o.y + h - 18)), ink[14], nil, Point(0, 0));
	if(game_over && (sys->millisec()/400)%2 == 0){
		msg := ink[4];
		if(won)
			msg = ink[10];
		img.draw(Rect((o.x + w/2 - 70, o.y + h/2 - 12), (o.x + w/2 + 70, o.y + h/2 + 12)), msg, nil, Point(0, 0));
	}
	img.flush(Draw->Flushnow);
}

draw_car(img: ref Image, o: Point, c: Car, col: ref Image)
{
	ca := math->cos(c.ang);
	sa := math->sin(c.ang);
	half := real(CAR_LEN) / 2.0;
	pts := array[4] of Point;
	for(k := 0; k < 4; k++){
		lx := half * real((k & 1)*2 - 1);
		lz := 5.0 * real((k & 2) - 1);
		pts[k] = Point(o.x + int(c.x + lx*ca - lz*sa), o.y + int(c.z + lx*sa + lz*ca));
	}
	for(e := 0; e < 4; e++){
		n := (e + 1) % 4;
		img.line(pts[e], pts[n], Draw->Endsquare, Draw->Endsquare, 2, col, Point(0, 0));
	}
}
now(): real
{
	return real sys->millisec() / 1000.0;
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}

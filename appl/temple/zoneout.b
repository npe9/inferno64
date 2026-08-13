implement Zoneout;

# TempleOS Demo/Games/ZoneOut.HC — tank shooter in faux-3D
# GAP: no Sprite3YB tanks/shots / scrolling sky sprites — ellipses + bands
# GAP: no GrPrint HUD — corner bars
# GAP: SongTask music loop omitted

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

include "scorestore.m";
	scorestore: Scorestore;

Zoneout: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

THEM_NUM: con 10;
SCRN_SCALE: con 512;
TANK_HEIGHT: con 32;
PI: con 3.141592653589793;

Obj: adt {
	x, y, z, angle: real;
	hit: int;
};

Shot: adt {
	x, y, z, angle, t0: real;
};

win: ref Window;
ink: array of ref Image;
us: Obj;
them: array of Obj;
shots: list of ref Shot;
num_them := THEM_NUM;
game_t0, game_tf: real;
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
	scorestore = load Scorestore Scorestore->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS ZoneOut", Wmclient->Appl);
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
	if(scorestore != nil)
		best_score = scorestore->loadreal("zoneout", best_score);

	them = array[THEM_NUM] of Obj;
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
		animate();
		redraw();
	}
}

game_init()
{
	us = Obj(0.0, 0.0, 0.0, 0.0, 0);
	for(i := 0; i < THEM_NUM; i++)
		them[i] = Obj(
			10000.0*rnreal() - 5000.0, 0.0, 10000.0*rnreal() - 5000.0,
			2.0*PI*rnreal(), 0);
	shots = nil;
	num_them = THEM_NUM;
	game_tf = 0.0;
	game_t0 = now();
}

key(k: int)
{
	if(game_tf != 0.0 && k != '\n' && k != 'r' && k != 'R' &&
	   k != 16r1b && k != 'q' && k != 'Q')
		return;
	case k {
	16r1b or 'q' or 'Q' =>
		if(have_tone)
			tone->stop();
		exit;
	'\n' or 'r' or 'R' =>
		game_init();
	' ' =>
		fire();
	Keyboard->Left or 'a' or 'A' =>
		us.angle += PI / 256.0;
	Keyboard->Right or 'd' or 'D' =>
		us.angle -= PI / 256.0;
	Keyboard->Up or 'w' or 'W' =>
		move_us(us.angle);
	Keyboard->Down or 's' or 'S' =>
		move_us(us.angle + PI);
	}
}

move_us(dir: real)
{
	us.x += 0.1 * real SCRN_SCALE * math->cos(dir);
	us.z += 0.1 * real SCRN_SCALE * math->sin(dir);
}

fire()
{
	if(game_tf != 0.0)
		return;
	s := ref Shot(us.x, real TANK_HEIGHT, us.z, us.angle, now());
	shots = s :: shots;
	if(have_tone)
		tone->beep(74, 60);
}

animate()
{
	if(game_tf != 0.0)
		return;
	ts := now();
	for(i := 0; i < THEM_NUM; i++){
		t := them[i];
		t.x += real SCRN_SCALE / 32.0 * math->cos(t.angle);
		t.z += real SCRN_SCALE / 32.0 * math->sin(t.angle);
		t.angle += rnreal() / 100.0;
		them[i] = t;
	}
	hit_r2 := (SCRN_SCALE/2) * (SCRN_SCALE/2);
	newshots: list of ref Shot;
	for(sl := shots; sl != nil; sl = tl sl){
		sh := hd sl;
		if(ts - sh.t0 > 1.0)
			continue;
		sh.x += 0.25 * real SCRN_SCALE * math->cos(sh.angle);
		sh.z += 0.25 * real SCRN_SCALE * math->sin(sh.angle);
		for(i := 0; i < THEM_NUM; i++){
			t := them[i];
			if(t.hit)
				continue;
			dd := int((t.x - sh.x)*(t.x - sh.x) + (t.z - sh.z)*(t.z - sh.z));
			if(dd < hit_r2){
				t.hit = 1;
				them[i] = t;
				num_them--;
				if(num_them == 0){
					game_tf = ts;
					if(game_tf - game_t0 < best_score){
						best_score = game_tf - game_t0;
						if(scorestore != nil)
							scorestore->savereal("zoneout", best_score);
					}
					if(have_tone)
						tone->stop();
				}
			}
		}
		newshots = sh :: newshots;
	}
	shots = rev(newshots);
}

project(wx, wy, wz: real): (int, int, real)
{
	img := win.image;
	cx := 320; cy := 240;
	if(img != nil){
		cx = img.r.dx() / 2;
		cy = img.r.dy() / 2;
	}
	tx := wx - us.x;
	ty := wy - us.y;
	tz := wz - us.z;
	yaw := us.angle - PI/2.0;
	rx := tx*math->cos(yaw) - tz*math->sin(yaw);
	rz := tx*math->sin(yaw) + tz*math->cos(yaw);
	pitch := PI / 16.0;
	ry := ty*math->cos(pitch) - rz*math->sin(pitch);
	rz2 := ty*math->sin(pitch) + rz*math->cos(pitch);
	if(rz2 < 1.0)
		rz2 = 1.0;
	sx := int(real(SCRN_SCALE)/2.0 * rx / rz2);
	sy := int(real(SCRN_SCALE)/2.0 * (ry + real TANK_HEIGHT) / rz2);
	return (cx + sx, cy + sy, rz2);
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	w := img.r.dx();
	h := img.r.dy();
	o := img.r.min;
	cx := w / 2;
	cy := h / 2;

	# sky + ground bands (scrolling backdrop substitute)
	bg_off := int(640.0 * wrap2(us.angle) / (2.0*PI));
	for(b := -1; b <= 2; b++){
		bx := b*640 - bg_off;
		img.draw(Rect((o.x+bx, o.y), (o.x+bx+640, o.y+h/3)), ink[10], nil, Point(0, 0));
		img.draw(Rect((o.x+bx, o.y+h/3), (o.x+bx+640, o.y+h)), ink[2], nil, Point(0, 0));
	}

	hit_r2 := (SCRN_SCALE/2) * (SCRN_SCALE/2);
	for(i := 0; i < THEM_NUM; i++){
		t := them[i];
		ey := t.y;
		for(sl := shots; sl != nil; sl = tl sl){
			sh := hd sl;
			dd := int((t.x - sh.x)*(t.x - sh.x) + (t.z - sh.z)*(t.z - sh.z));
			if(dd < hit_r2)
				ey -= math->sqrt(real dd);
		}
		(sx, sy, zd) := project(t.x, ey, t.z);
		rad := int(18.0 / zd);
		if(rad < 3)
			rad = 3;
		col := ink[4];
		if(t.hit)
			col = ink[7];
		img.ellipse(Point(o.x+sx, o.y+sy), rad, rad, 0, col, Point(0, 0));
		if(!t.hit){
			(tx, ty, nil) := project(t.x, ey, t.z + 20.0);
			img.line(Point(o.x+sx, o.y+sy), Point(o.x+tx, o.y+ty),
				Draw->Enddisc, Draw->Enddisc, 1, ink[0], Point(0, 0));
		}
	}
	for(sl := shots; sl != nil; sl = tl sl){
		sh := hd sl;
		(sx, sy, zd) := project(sh.x, sh.y, sh.z);
		rad := int(6.0 / zd);
		if(rad < 2)
			rad = 2;
		img.ellipse(Point(o.x+sx, o.y+sy), rad, rad, 0, ink[14], Point(0, 0));
	}

	if(game_tf != 0.0 && (sys->millisec()/500)%2 == 0)
		img.draw(Rect((o.x+cx-70, o.y+cy-12), (o.x+cx+70, o.y+cy+12)), ink[4], nil, Point(0, 0));
	else{
		img.line(Point(o.x+cx-5, o.y+cy), Point(o.x+cx+5, o.y+cy),
			Draw->Endsquare, Draw->Endsquare, 1, ink[2], Point(0, 0));
		img.line(Point(o.x+cx, o.y+cy-5), Point(o.x+cx, o.y+cy+5),
			Draw->Endsquare, Draw->Endsquare, 1, ink[2], Point(0, 0));
	}

	tt := now();
	if(game_tf != 0.0)
		tt = game_tf;
	elapsed := tt - game_t0;
	# enemy/time/best bars
	enemy_w := (w - 40) * num_them / THEM_NUM;
	time_w := int(real(w - 40) * elapsed / (best_score + 0.01));
	if(time_w > w - 40)
		time_w = w - 40;
	if(time_w < 0)
		time_w = 0;
	best_w := int(real(w - 40) * best_score / (best_score + 1.0));
	if(best_w > w - 40)
		best_w = w - 40;
	if(best_w < 0)
		best_w = 0;
	img.draw(Rect((o.x+10, o.y+h-10), (o.x+10+enemy_w, o.y+h-6)), ink[4], nil, Point(0, 0));
	img.draw(Rect((o.x+20, o.y+h-18), (o.x+20+time_w, o.y+h-14)), ink[14], nil, Point(0, 0));
	img.draw(Rect((o.x+30, o.y+h-26), (o.x+30+best_w, o.y+h-22)), ink[11], nil, Point(0, 0));
	img.flush(Draw->Flushnow);
}

wrap2(a: real): real
{
	two := 2.0 * PI;
	while(a >= two)
		a -= two;
	while(a < 0.0)
		a += two;
	return a;
}

rev(l: list of ref Shot): list of ref Shot
{
	r: list of ref Shot;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

now(): real
{
	return real sys->millisec() / 1000.0;
}

rnreal(): real
{
	if(rand == nil)
		return real(sys->millisec() & 1023) / 1023.0;
	return real(rand->rand(1000)) / 1000.0;
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}

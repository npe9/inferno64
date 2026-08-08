implement Bigguns;

# TempleOS Demo/Games/BigGuns.HC — ODE artillery
# GAP: no map scroll widgets / GrFloodFill terrain / Sprite3ZB gun art
# left/right aim  space=fire  Enter=restart  q=quit

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

include "ode.m";
	ode: Ode;
	ODE, Mass: import ode;

include "tone.m";
	tone: Tone;

Bigguns: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

MAPW: con 1024;
MAPH: con 400;
DUST: con 256;
PI: con 3.141592653589793;

win: ref Window;
sim: ref ODE;
ink: array of ref Image;
elevs: array of int;
dustx, dusty: array of int;
gunx, guny: int;
gunang := 0.0;	# radians, 0=right, -PI=left, typically negative for up-left/right
recoil := 0;
wind := 0.0;
camx := 0;
have_tone := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	ode = load Ode Ode->PATH;
	tone = load Tone Tone->PATH;
	if(ode == nil){
		sys->fprint(sys->fildes(2), "bigguns: no ode\n");
		raise "fail:load";
	}
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	ode->init();
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS BigGuns", Wmclient->Appl);
	d := win.display;
	ink = array[16] of ref Image;
	cols := array[] of {
		Draw->Black, Draw->Blue, Draw->Green, Draw->Cyan,
		Draw->Red, Draw->Magenta, Draw->Darkyellow, Draw->Grey,
		int 16r87CEEBFF, Draw->Paleblue, Draw->Palegreen, int 16r8B4513FF,
		int 16rFF8888FF, int 16rFF88FFFF, Draw->Yellow, Draw->White
	};
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);

	elevs = array[MAPW] of int;
	dustx = array[DUST] of int;
	dusty = array[DUST] of int;
	reset();
	win.reshape(Rect((0, 0), (640, 480)));
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
		key(k);
	<-ticks =>
		if(recoil > 0)
			recoil--;
		step();
		manage();
		redraw();
	}
}

reset()
{
	sim = ode->new();
	sim.drag_v2 = 0.002;
	sim.drag_v3 = 0.0001;
	sim.accel_limit = 5e5;
	sim.h = 0.005;
	y := 0.7 * real MAPH;
	dy := 0.0;
	for(x := 0; x < MAPW; x++){
		s := 1.0;
		if(rn(2) == 0)
			s = -1.0;
		dy = clamp(dy + s * 0.4, -3.0, 3.0);
		y = clamp(y + dy, 0.3*real MAPH, real(MAPH-2));
		elevs[x] = int y;
	}
	gunx = 50 + rn(MAPW - 100);
	guny = elevs[gunx];
	for(x = gunx - 20; x <= gunx + 20; x++)
		if(x >= 0 && x < MAPW)
			elevs[x] = guny;
	gunang = -PI/4.0;
	recoil = 0;
	wind = real(rn(200) - 100) / 250.0;
	for(i := 0; i < DUST; i++){
		dustx[i] = rn(MAPW);
		dusty[i] = rn(MAPH);
	}
	camx = gunx - 320;
	if(camx < 0) camx = 0;
	if(camx > MAPW - 640) camx = MAPW - 640;
}

key(k: int)
{
	case k {
	16r1b or 'q' or 'Q' =>
		exit;
	'\n' =>
		reset();
	' ' =>
		fire();
	Keyboard->Left or 'a' or 'A' =>
		gunang -= 2.0*PI/180.0;
		if(gunang < -PI)
			gunang = -PI;
	Keyboard->Right or 'd' or 'D' =>
		gunang += 2.0*PI/180.0;
		if(gunang > 0.0)
			gunang = 0.0;
	',' =>
		camx -= 20;
		if(camx < 0) camx = 0;
	'.' =>
		camx += 20;
		if(camx > MAPW - 640) camx = MAPW - 640;
	}
}

fire()
{
	if(recoil > 0)
		return;
	c := math->cos(gunang);
	s := math->sin(gunang);
	m := ref Mass(
		real gunx + 27.0*c, real guny + 27.0*s, 0.0,
		600.0*c, 600.0*s, 0.0,
		0.0, 0.0, 0.0,
		10.0, 0.1, 0, 0, 2.0, 0
	);
	ode->addmass(sim, m);
	recoil = 12;
	if(have_tone)
		tone->beep(40 + rn(50), 80);
}

step()
{
	ode->clearforces(sim);
	for(l := sim.masses; l != nil; l = tl l){
		m := hd l;
		m.fy += 1000.0 * m.mass;	# gravity down (+y)
		m.fx += 25.0 * wind * m.mass;
	}
	ode->update(sim, 0.016);
}

manage()
{
	kill: list of ref Mass;
	for(l := sim.masses; l != nil; l = tl l){
		m := hd l;
		ix := int m.x;
		hit := 0;
		if(ix < 0 || ix >= MAPW)
			hit = 1;
		else if(int m.y >= elevs[ix])
			hit = 1;
		if(hit)
			kill = m :: kill;
	}
	for(k := kill; k != nil; k = tl k){
		m := hd k;
		ix := int m.x;
		for(i := ix - 4; i <= ix + 4; i++)
			if(i >= 0 && i < MAPW){
				d := i - ix;
				if(d < 0) d = -d;
				elevs[i] = clampi(elevs[i] + 10 - 2*d, 0, MAPH-2);
			}
		ode->remmass(sim, m);
		if(have_tone)
			tone->beep(20, 40);
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
	# sky
	img.draw(img.r, ink[8], nil, Point(0, 0));
	# terrain silhouette
	for(x := 0; x < w; x++){
		mx := camx + x;
		if(mx < 0 || mx >= MAPW)
			continue;
		ey := elevs[mx];
		if(ey < h)
			img.draw(Rect((o.x+x, o.y+ey), (o.x+x+1, o.y+h)), ink[11], nil, Point(0, 0));
		if(ey > 0 && ey < h)
			img.draw(Rect((o.x+x, o.y+ey), (o.x+x+1, o.y+ey+1)), ink[0], nil, Point(0, 0));
	}
	# dust
	wx := int(real(sys->millisec()) * wind / 50.0);
	for(i := 0; i < DUST; i++){
		dx := (dustx[i] + wx) % MAPW;
		if(dx < 0) dx += MAPW;
		dy := dusty[i];
		if(dy < elevs[dx]){
			sx := dx - camx;
			if(sx >= 0 && sx < w && dy < h)
				img.draw(Rect((o.x+sx, o.y+dy), (o.x+sx+1, o.y+dy+1)), ink[7], nil, Point(0, 0));
		}
	}
	# gun base
	gx := gunx - camx;
	gy := guny;
	if(gx >= -40 && gx < w + 40){
		img.fillellipse(Point(o.x+gx, o.y+gy), 8, 6, ink[0], Point(0, 0));
		# barrel
		c := math->cos(gunang);
		s := math->sin(gunang);
		bx := real gx - real recoil * c;
		by := real gy - real recoil * s;
		ex := bx + 30.0 * c;
		ey := by + 30.0 * s;
		img.line(Point(o.x+int bx, o.y+int by), Point(o.x+int ex, o.y+int ey),
			0, 0, 2, ink[0], Point(0, 0));
	}
	# shots
	for(l := sim.masses; l != nil; l = tl l){
		m := hd l;
		sx := int m.x - camx;
		sy := int m.y;
		if(sx >= 0 && sx < w && sy >= 0 && sy < h)
			img.fillellipse(Point(o.x+sx, o.y+sy), 2, 2, ink[0], Point(0, 0));
	}
	img.flush(Draw->Flushnow);
}

clamp(v, lo, hi: real): real
{
	if(v < lo) return lo;
	if(v > hi) return hi;
	return v;
}

clampi(v, lo, hi: int): int
{
	if(v < lo) return lo;
	if(v > hi) return hi;
	return v;
}

rn(n: int): int
{
	if(n <= 0) return 0;
	if(rand == nil) return sys->millisec() % n;
	return rand->rand(n);
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}

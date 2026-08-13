implement Rawhide;

# TempleOS Demo/Games/RawHide.HC — herd cattle into the upper-left corral
# mouse moves horse; Enter restart; q quit
#
# GAP: no cow/bull/horse sprites / river waterfall / SongTask music
# GAP: 800x600 map not 1000x1000; 48 animals not 100; ellipses not sprites
# GAP: no GrBlot map_dc / gate hinge animation — bar gate + scroll via keys/mouse
# GAP: PopUpOk help omitted

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

Rawhide: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

MAPW: con 800;
MAPH: con 600;
FENCEW: con 180;
FENCEH: con 130;
BORDER: con 8;
ANIMALS: con 48;
RIVER_DROPS: con 64;

Animal: adt {
	x, y, dx, dy: real;
	buddy: int;
	kind: int;
	dead: int;
};

win: ref Window;
ink: array of ref Image;
mapbuf: ref Image;
anim: array of Animal;
rx, rw: array of int;
wfdx: array of int;
wfdt: array of real;
wf_x, wf_y, wf_w: int;
scrollx, scrolly: int;
mx, my: int;
outside := ANIMALS;
gate_open := 0;
gate_t := 0.0;
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
	scorestore = load Scorestore Scorestore->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS RawHide", Wmclient->Appl);
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
		best_score = scorestore->loadreal("rawhide", best_score);

	rx = array[MAPH] of int;
	rw = array[MAPH] of int;
	wfdx = array[RIVER_DROPS] of int;
	wfdt = array[RIVER_DROPS] of real;
	anim = array[ANIMALS] of Animal;
	mapbuf = d.newimage(Rect((0, 0), (MAPW, MAPH)), Draw->RGB24, 0, Draw->Green);
	if(mapbuf == nil)
		raise "fail:map";

	game_init();
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 30);
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
			if(have_tone)
				tone->stop();
			exit;
		'\n' or 'r' or 'R' =>
			game_init();
		Keyboard->Left or 'a' or 'A' =>
			scrollx -= 24;
		Keyboard->Right or 'd' or 'D' =>
			scrollx += 24;
		Keyboard->Up or 'w' or 'W' =>
			scrolly -= 24;
		Keyboard->Down or 's' or 'S' =>
			scrolly += 24;
		}
	<-ticks =>
		simulate();
		redraw();
	}
}

game_init()
{
	build_map();
	for(i := 0; i < ANIMALS; i++){
		ax := 0.0;
		ay := 0.0;
		do {
			ax = real(BORDER + 40 + rn(MAPW - 2*BORDER - 80));
			ay = real(BORDER + 40 + rn(MAPH - 2*BORDER - 80));
		} while(!walkable(int ax, int ay));
		anim[i] = Animal(ax, ay, 0.0, 0.0, i, i & 1, 0);
		anim[i].buddy = buddy_pick(i);
	}
	mx = MAPW / 2;
	my = MAPH / 2;
	scrollx = mx - 320;
	scrolly = my - 240;
	clamp_scroll();
	outside = ANIMALS;
	gate_open = 0;
	gate_t = 0.0;
	t0 = now();
	tf = 0.0;
}

build_map()
{
	mapbuf.draw(mapbuf.r, ink[2], nil, Point(0, 0));
	wf_y = MAPH/2 - 20 + rn(MAPH/4);
	x := MAPW * 2 / 3;
	w := 18;
	dx := 0;
	for(y := BORDER; y < MAPH - BORDER; y++){
		if(y > wf_y - 8 && y < wf_y + 28){
			wf_w = w;
			wf_x = x - w/2;
		} else {
			dx = clampi(dx + rn(3) - 1, -2, 2);
			w = clampi(w + rn(3) - 1, 10, 28);
			x = clampi(x + dx, MAPW/4, MAPW - MAPW/4);
		}
		rx[y] = x;
		rw[y] = w;
		mapbuf.draw(Rect((x - w/2, y), (x + w/2, y + 1)), ink[1], nil, Point(0, 0));
		if(y < wf_y - 6 || y > wf_y + 26)
			mapbuf.draw(Rect((x - w/2 - 4, y), (x + w/2 + 4, y + 1)), ink[14], nil, Point(0, 0));
	}
	mapbuf.draw(Rect((wf_x, wf_y), (wf_x + wf_w, wf_y + 6)), ink[7], nil, Point(0, 0));
	for(fy := BORDER; fy < MAPH - BORDER; fy++)
		mapbuf.line(Point(FENCEW, fy), Point(FENCEW, fy), Draw->Endsquare, Draw->Endsquare, 1, ink[7], Point(0, 0));
	for(fx := 0; fx <= FENCEW; fx += 12)
		mapbuf.line(Point(fx, FENCEH), Point(fx + 8, FENCEH - 8), Draw->Endsquare, Draw->Endsquare, 1, ink[13], Point(0, 0));
	mapbuf.draw(Rect((0, 0), (FENCEW, FENCEH)), ink[10], nil, Point(0, 0));
	mapbuf.draw(Rect((0, 0), (MAPW, BORDER)), ink[4], nil, Point(0, 0));
	mapbuf.draw(Rect((0, MAPH - BORDER), (MAPW, MAPH)), ink[4], nil, Point(0, 0));
	mapbuf.draw(Rect((0, 0), (BORDER, MAPH)), ink[4], nil, Point(0, 0));
	mapbuf.draw(Rect((MAPW - BORDER, 0), (MAPW, MAPH)), ink[4], nil, Point(0, 0));
	for(i := 0; i < RIVER_DROPS; i++){
		wfdx[i] = wf_x + rn(wf_w);
		wfdt[i] = now() - rnreal() * 1.5;
	}
}

buddy_pick(i: int): int
{
	best := i;
	bscore := 1000000;
	for(b := 0; b < ANIMALS; b++){
		if(b == i)
			continue;
		sc := rn(512*512);
		dx := anim[b].x - anim[i].x;
		dy := anim[b].y - anim[i].y;
		sc += int(dx*dx + dy*dy);
		if(sc < bscore){
			bscore = sc;
			best = b;
		}
	}
	return best;
}

handleptr(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil)
		return;
	mx = p.xy.x - img.r.min.x + scrollx;
	my = p.xy.y - img.r.min.y + scrolly;
	clamp_scroll();
}

simulate()
{
	if(tf != 0.0)
		return;
	ts := now();
	if(mx < FENCEW && my < FENCEH)
		gate_t = ts;
	gate_open = 0;
	if(ts - gate_t < 6.0)
		gate_open = 1;
	out := 0;
	for(i := 0; i < ANIMALS; i++){
		a := anim[i];
		if(a.dead)
			continue;
		if(i == int(ts * 10.0) % ANIMALS)
			a.buddy = buddy_pick(i);
		b := anim[a.buddy];
		ddx := a.x - real(mx);
		ddy := a.y - real(my);
		dd := ddx*ddx + ddy*ddy;
		if(dd > 1.0){
			d := math->sqrt(dd);
			f := 800.0 / dd;
			a.dx += f * ddx / d;
			a.dy += f * ddy / d;
		}
		ddx = a.x - b.x;
		ddy = a.y - b.y;
		dd = ddx*ddx + ddy*ddy;
		if(dd > 1.0){
			d := math->sqrt(dd);
			s := math->pow(d, 1.25) - 40.0;
			f := -0.02 * s;
			a.dx += f * ddx / d;
			a.dy += f * ddy / d;
		}
		a.dx += 0.1 * (b.dx - a.dx);
		a.dy += 0.1 * (b.dy - a.dy);
		a.dx = 0.995 * clampf(a.dx + rnreal() - 0.5, -6.0, 6.0);
		a.dy = 0.995 * clampf(a.dy + rnreal() - 0.5, -6.0, 6.0);
		if(!walkable(int a.x, int a.y)){
			a.dx *= 0.5;
			a.dy *= 0.5;
		}
		nx := int(a.x + a.dx);
		ny := int(a.y + a.dy);
		if(walkable(nx, ny)){
			a.x += a.dx;
			a.y += a.dy;
		}
		if(a.x < real(BORDER) || a.x >= real(MAPW - BORDER))
			a.dx = -a.dx;
		if(a.y < real(BORDER) || a.y >= real(MAPH - BORDER))
			a.dy = -a.dy;
		if(int(a.x) >= FENCEW || int(a.y) >= FENCEH)
			out++;
		anim[i] = a;
	}
	outside = out;
	if(out == 0){
		tf = ts;
		if(tf - t0 < best_score){
			best_score = tf - t0;
			if(scorestore != nil)
				scorestore->savereal("rawhide", best_score);
			if(have_tone)
				tone->beep(86, 120);
		} else if(have_tone)
			tone->beep(72, 120);
	}
}

walkable(x, y: int): int
{
	if(x < BORDER || y < BORDER || x >= MAPW - BORDER || y >= MAPH - BORDER)
		return 0;
	if(x < FENCEW && y < FENCEH)
		return 1;
	if(x >= FENCEW - 2 && x <= FENCEW + 2 && y < FENCEH + 8)
		return gate_open;
	if((x - (wf_x + wf_w/2))*(x - (wf_x + wf_w/2)) + (y - (wf_y + 3))*(y - (wf_y + 3)) < 400)
		return 0;
	if(y >= BORDER && y < MAPH - BORDER){
		half := rw[y] / 2;
		if(x >= rx[y] - half && x <= rx[y] + half)
			return 0;
	}
	return 1;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	clamp_scroll();
	src := Rect((scrollx, scrolly), (scrollx + w, scrolly + h));
	img.draw(img.r, mapbuf, nil, src.min);
	ts := now();
	for(di := 0; di < RIVER_DROPS; di++){
		phase := ts - wfdt[di];
		while(phase >= 1.5)
			phase -= 1.5;
		while(phase < 0.0)
			phase += 1.5;
		dy := int(0.5 * 80.0 * math->pow(phase / 1.5, 2.0));
		img.draw(Rect((o.x + wfdx[di] - scrollx, o.y + wf_y + dy - scrolly),
			(o.x + wfdx[di] - scrollx + 1, o.y + wf_y + dy - scrolly + 1)), ink[15], nil, Point(0, 0));
	}
	frame := sys->millisec() / 200;
	for(ai := 0; ai < ANIMALS; ai++){
		a := anim[ai];
		if(a.dead)
			continue;
		sx := o.x + int a.x - scrollx;
		sy := o.y + int a.y - scrolly;
		if(sx < -20 || sy < -20 || sx > w + 20 || sy > h + 20)
			continue;
		col := ink[13];
		if(a.kind)
			col = ink[5];
		if((frame + ai) & 1)
			sx += 1;
		img.ellipse(Point(sx, sy), 8, 6, 0, col, Point(0, 0));
	}
	hx := o.x + mx - scrollx;
	hy := o.y + my - scrolly;
	img.ellipse(Point(hx, hy), 10, 8, 0, ink[14], Point(0, 0));
	if(!gate_open){
		gx := o.x + FENCEW - scrollx;
		img.line(Point(gx, o.y + FENCEH - scrolly), Point(gx, o.y + FENCEH - 30 - scrolly),
			Draw->Endsquare, Draw->Endsquare, 2, ink[0], Point(0, 0));
	}
	tt := now() - t0;
	if(tf != 0.0){
		tt = tf - t0;
		if((sys->millisec()/400)%2 == 0)
			img.draw(Rect((o.x + w/2 - 60, o.y + h/2 - 10), (o.x + w/2 + 60, o.y + h/2 + 10)), ink[4], nil, Point(0, 0));
	}
	bar_w := (w - 40) * outside / ANIMALS;
	img.draw(Rect((o.x + 10, o.y + 8), (o.x + 10 + bar_w, o.y + 14)), ink[4], nil, Point(0, 0));
	tw := int(real(w - 40) * tt / (best_score + 0.01));
	if(tw > w - 40) tw = w - 40;
	img.draw(Rect((o.x + 20, o.y + 18), (o.x + 20 + tw, o.y + 24)), ink[14], nil, Point(0, 0));
	img.flush(Draw->Flushnow);
}

clamp_scroll()
{
	img := win.image;
	w := 640; h := 480;
	if(img != nil){
		w = img.r.dx();
		h = img.r.dy();
	}
	if(scrollx < 0) scrollx = 0;
	if(scrolly < 0) scrolly = 0;
	if(scrollx > MAPW - w) scrollx = MAPW - w;
	if(scrolly > MAPH - h) scrolly = MAPH - h;
}

clampf(v, lo, hi: real): real
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

now(): real
{
	return real sys->millisec() / 1000.0;
}

rn(n: int): int
{
	if(rand == nil)
		return sys->millisec() % n;
	return rand->rand(n);
}

rnreal(): real
{
	return real(rn(1000)) / 1000.0;
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}

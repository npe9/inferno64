implement Wenceslas;

# TempleOS Demo/Games/Wenceslas.HC — Good King Wenceslas
# GAP: no 3D Sprite3/Mat4x4 king/peasant/house/tree sprites — circles + house rect
# GAP: no GrBlot snow tile — scrolling white dots; no PopUpOk carols
# GAP: no animate_task thread — single timer loop; SongTask approximated via tone->play

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

include "rand.m";
	rand: Rand;

include "tone.m";
	tone: Tone;

include "scorestore.m";
	scorestore: Scorestore;

Wenceslas: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

BORDER: con 5;
KING_STEP: con 6;
TREES_NUM: con 8;
PEASANTS_NUM: con 10;
MAX_STEPS: con 256;
MAX_KSTEPS: con 128;
SNOW_SZ: con 128;

Tree: adt {
	x, y: int;
	fire: int;
	fire_tick: int;
};

Peasant: adt {
	x, y: real;
	theta: real;
	stopped: int;
	door_t: real;
};

Step: adt {
	x, y: int;
	t0: real;
};

win: ref Window;
font: ref Font;
ink: array of ref Image;
have_tone := 0;
song_pause := 0;

trees: array of Tree;
peas: array of Peasant;
steps: array of Step;
ksteps: array of Step;
nsteps, nksteps: int;

king_x, king_y: int;
king_theta: real;
king_phase: int;
king_ms: int;
king_timeout: real;

snow_x, snow_y: int;
snow_acc: int;
snow_dots: array of Point;

animate_ms, animate_phase: int;
not_stopped: int;
t0, tf: real;
best_score: real;
blink_on: int;

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

	win = wmclient->window(ctxt, "TempleOS Wenceslas", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/lucida/unicode.8.font");
	ink = array[16] of ref Image;
	cols := array[] of {
		Draw->Black, Draw->Blue, Draw->Green, Draw->Cyan,
		Draw->Red, Draw->Magenta, Draw->Darkyellow, Draw->Grey,
		int 16r444444FF, Draw->Paleblue, Draw->Palegreen, Draw->Palebluegreen,
		int 16rFF8888FF, int 16rFF88FFFF, Draw->Yellow, Draw->White
	};
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);

	trees = array[TREES_NUM] of Tree;
	peas = array[PEASANTS_NUM] of Peasant;
	steps = array[MAX_STEPS] of Step;
	ksteps = array[MAX_KSTEPS] of Step;
	snow_dots = array[SNOW_SZ*SNOW_SZ/8] of Point;
	best_score = 9999.0;
	if(scorestore != nil)
		best_score = scorestore->loadreal("wenceslas", best_score);

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: nil);
	game_init();
	if(have_tone)
		spawn songloop();

	ticks := chan of int;
	spawn timer(ticks, 16);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!')
			redraw();
	k := <-win.ctxt.kbd =>
		case k {
		16r1b or 'q' or 'Q' =>
			if(have_tone)
				tone->stop();
			exit;
		'\n' or 'r' or 'R' =>
			game_init();
		' ' =>
			burn_trees();
		Keyboard->Right or 'd' or 'D' =>
			move_king(KING_STEP, 0, 0.0);
		Keyboard->Left or 'a' or 'A' =>
			move_king(-KING_STEP, 0, Math->Pi);
		Keyboard->Down or 's' or 'S' =>
			move_king(0, KING_STEP, -Math->Pi/2.0);
		Keyboard->Up or 'w' or 'W' =>
			move_king(0, -KING_STEP, Math->Pi/2.0);
		}
	<-ticks =>
		animate();
		redraw();
	}
}

game_init()
{
	img := win.image;
	w := 640; h := 480;
	if(img != nil){
		w = img.r.dx();
		h = img.r.dy();
	}
	snow_x = snow_y = 0;
	snow_acc = 0;
	nsteps = nksteps = 0;
	animate_ms = animate_phase = 0;
	king_ms = 0;
	king_phase = 0;
	king_timeout = 0.0;
	tf = 0.0;
	song_pause = 0;
	t0 = now();
	i: int;
	for(i = 0; i < len snow_dots; i++)
		snow_dots[i] = Point(rn(SNOW_SZ), rn(SNOW_SZ));
	for(i = 0; i < TREES_NUM; i++)
		trees[i] = Tree(rn(w - 2*BORDER) + BORDER, rn(h - 2*BORDER) + BORDER, 0, 0);
	for(i = 0; i < PEASANTS_NUM; i++)
		peas[i] = Peasant(
			real(rn(w - 2*BORDER) + BORDER),
			real(rn(h - 2*BORDER) + BORDER),
			2.0*Math->Pi*rnreal(), 0, 0.0);
	king_x = w/2;
	king_y = h/2;
	king_theta = -Math->Pi/2.0;
}

move_king(dx: int, dy: int, th: real)
{
	img := win.image;
	w := 640; h := 480;
	if(img != nil){
		w = img.r.dx();
		h = img.r.dy();
	}
	if(dx > 0 && king_x + dx < w - BORDER)
		king_x += dx;
	if(dx < 0 && king_x + dx >= BORDER)
		king_x += dx;
	if(dy > 0 && king_y + dy < h - BORDER)
		king_y += dy;
	if(dy < 0 && king_y + dy >= BORDER)
		king_y += dy;
	king_theta = th;
	king_ms = 0;
	king_phase = (king_phase + 2) & 2;
	king_timeout = now() + 0.5;
	add_kstep(king_x, king_y);
	add_step(king_x, king_y, th, king_phase & 2);
}

burn_trees()
{
	i: int;
	for(i = 0; i < TREES_NUM; i++){
		dx := real(king_x - trees[i].x);
		dy := real(king_y - trees[i].y);
		if(dx*dx + dy*dy < 10.0*10.0)
			trees[i].fire = 1;
	}
}

add_step(x: int, y: int, th: real, lr: int)
{
	if(nsteps >= MAX_STEPS)
		nsteps = MAX_STEPS - 1;
	s := steps[nsteps];
	s.x = x; s.y = y; s.t0 = now();
	steps[nsteps] = s;
	nsteps++;
	off1 := 3.5*math->sin(th);
	off2 := 3.5*math->cos(th);
	if(lr){
		plot_pair(x, y, th, -off1 + 2.0*math->cos(th), off2 + 2.0*math->sin(th));
		plot_pair(x, y, th, -off1 + 5.0*math->cos(th), off2 + 5.0*math->sin(th));
	}else{
		plot_pair(x, y, th, off1, -off2);
		plot_pair(x, y, th, off1 + 3.0*math->cos(th), -off2 + 3.0*math->sin(th));
	}
}

plot_pair(x: int, y: int, th: real, ax: real, ay: real)
{
	if(nsteps >= MAX_STEPS)
		return;
	s := steps[nsteps];
	s.x = x + int(ax*math->cos(th) - ay*math->sin(th));
	s.y = y + int(ax*math->sin(th) + ay*math->cos(th));
	s.t0 = now();
	steps[nsteps] = s;
	nsteps++;
}

add_kstep(x: int, y: int)
{
	if(nksteps >= MAX_KSTEPS)
		nksteps = MAX_KSTEPS - 1;
	s := ksteps[nksteps];
	s.x = x; s.y = y; s.t0 = now();
	ksteps[nksteps] = s;
	nksteps++;
}

animate()
{
	ts := now();
	img := win.image;
	w := 640; h := 480;
	if(img != nil){
		w = img.r.dx();
		h = img.r.dy();
	}
	cx := w/2; cy := h/2;

	# expire footsteps
	i := 0;
	while(i < nsteps){
		if(ts - steps[i].t0 > 5.0){
			j := nsteps - 1;
			steps[i] = steps[j];
			nsteps--;
		}else
			i++;
	}
	i = 0;
	while(i < nksteps){
		if(ts - ksteps[i].t0 > 3.0){
			j := nksteps - 1;
			ksteps[i] = ksteps[j];
			nksteps--;
		}else
			i++;
	}

	not_stopped = 0;
	for(pi := 0; pi < PEASANTS_NUM; pi++){
		p := peas[pi];
		if(p.stopped){
			if(p.door_t > 0.0 && ts > p.door_t + 1.0){
				p.x = -9999.0;
				p.y = -9999.0;
				p.door_t = 0.0;
			}
			peas[pi] = p;
			continue;
		}
		dx := p.x - real cx;
		dy := p.y - real cy;
		if(dx*dx + dy*dy < 20.0*20.0){
			p.stopped = 1;
			p.door_t = ts;
			peas[pi] = p;
			continue;
		}
		warmed := 0;
		for(ti := 0; ti < TREES_NUM; ti++){
			if(!trees[ti].fire)
				continue;
			dx = p.x - real trees[ti].x;
			dy = p.y - real trees[ti].y;
			if(dx*dx + dy*dy < 20.0*20.0){
				p.stopped = 1;
				warmed = 1;
				break;
			}
		}
		if(warmed){
			peas[pi] = p;
			continue;
		}
		p.theta = follow_theta(p.x, p.y);
		p.x += math->cos(p.theta) / 100.0;
		p.y += math->sin(p.theta) / 100.0;
		if(p.x < real(BORDER/2) || p.x >= real(w - BORDER/2) ||
		   p.y < real(BORDER/2) || p.y >= real(h - BORDER/2)){
			p.theta += Math->Pi;
			p.x += 3.0*math->cos(p.theta) / 100.0;
			p.y += 3.0*math->sin(p.theta) / 100.0;
		}
		if(animate_ms == 0 && (animate_phase & 1))
			add_step(int p.x, int p.y, p.theta, animate_phase & 2);
		not_stopped++;
		peas[pi] = p;
	}

	if(not_stopped == 0 && tf == 0.0){
		tf = ts;
		song_pause = 1;
		if(have_tone){
			tone->beep(86, 200);
			tone->beep(86, 200);
		}
		elapsed := tf - t0;
		if(elapsed < best_score){
			best_score = elapsed;
			if(scorestore != nil)
				scorestore->savereal("wenceslas", best_score);
		}
		song_pause = 0;
	}

	snow_x += rn(3) - 1;
	snow_y += 1 - (rn(4) & 1);
	if(snow_acc++ > 8){
		snow_acc = 0;
		snow_dots[rn(len snow_dots)] = Point(rn(SNOW_SZ), rn(SNOW_SZ));
	}

	for(ti := 0; ti < TREES_NUM; ti++){
		if(trees[ti].fire){
			trees[ti].fire_tick++;
			if((trees[ti].fire_tick & 1) == 0)
				trees[ti].fire = 1;
		}
	}

	if(animate_ms++ >= 250){
		animate_ms = 0;
		animate_phase = (animate_phase + 1) & 3;
	}
	if(ts < king_timeout){
		if(king_ms++ >= 250){
			king_ms = 0;
			king_phase |= 1;
		}
	}
	blink_on = (int(ts*2.0) & 1) != 0;
}

follow_theta(px, py: real): real
{
	best := 1e30;
	best_th := 0.0;
	for(i := 0; i < nksteps; i++){
		s := ksteps[i];
		dx := real(s.x) - px;
		dy := real(s.y) - py;
		d := dx*dx + dy*dy;
		if(d == 0.0 || d >= 15.0*15.0)
			continue;
		d += 1000.0 * (now() - s.t0) * (now() - s.t0);
		if(d < best){
			best = d;
			best_th = math->atan2(dy, dx);
		}
	}
	return best_th;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	w := img.r.dx();
	h := img.r.dy();
	o := img.r.min;
	ts := now();
	i: int;

	img.draw(img.r, ink[0], nil, Point(0, 0));

	# snow field
	for(y := snow_y % SNOW_SZ - SNOW_SZ; y < h; y += SNOW_SZ)
		for(x := snow_x % SNOW_SZ - SNOW_SZ; x < w; x += SNOW_SZ)
			for(i = 0; i < len snow_dots; i += 7){
				p := snow_dots[i];
				img.draw(Rect((o.x+x+p.x, o.y+y+p.y), (o.x+x+p.x+1, o.y+y+p.y+1)),
					ink[15], nil, Point(0, 0));
			}

	# trees behind house (y <= h/2)
	for(i = 0; i < TREES_NUM; i++)
		if(trees[i].y <= h/2)
			draw_tree(img, o, trees[i]);

	draw_house(img, o, w/2, h/2, ts);

	for(i = 0; i < TREES_NUM; i++)
		if(trees[i].y > h/2)
			draw_tree(img, o, trees[i]);

	for(i = 0; i < nsteps; i++){
		s := steps[i];
		col := ink[7];
		if(ts - s.t0 >= 2.0)
			col = ink[8];
		img.draw(Rect((o.x+s.x, o.y+s.y), (o.x+s.x+2, o.y+s.y+2)), col, nil, Point(0, 0));
	}

	for(i = 0; i < PEASANTS_NUM; i++){
		p := peas[i];
		if(p.x < -100.0)
			continue;
		draw_peasant(img, o, p);
	}
	draw_king(img, o, ts);

	if(font != nil){
		tt := ts - t0;
		if(tf > 0.0)
			tt = tf - t0;
		msg := sys->sprint("Freezing:%d Time:%3.2f Best:%3.2f", not_stopped, tt, best_score);
		img.text(Point(o.x+4, o.y+4), ink[10], Point(0, 0), font, msg);
		if(tf > 0.0 && blink_on)
			img.text(Point(o.x+w/2-56, o.y+h/2), ink[12], Point(0, 0), font, "Game Completed");
	}
	img.flush(Draw->Flushnow);
}

draw_house(img: ref Image, o: Point, hx: int, hy: int, ts: real)
{
	i: int;
	img.draw(Rect((o.x+hx-30, o.y+hy-20), (o.x+hx+30, o.y+hy+20)), ink[6], nil, Point(0, 0));
	img.line(Point(o.x+hx-34, o.y+hy-20), Point(o.x+hx, o.y+hy-44), 0, 0, 1, ink[13], Point(0, 0));
	img.line(Point(o.x+hx, o.y+hy-44), Point(o.x+hx+34, o.y+hy-20), 0, 0, 1, ink[13], Point(0, 0));
	door_open := 0;
	for(i = 0; i < PEASANTS_NUM; i++)
		if(peas[i].door_t > 0.0 && ts < peas[i].door_t + 1.0)
			door_open = 1;
	if(door_open)
		img.draw(Rect((o.x+hx-8, o.y+hy), (o.x+hx+8, o.y+hy+20)), ink[14], nil, Point(0, 0));
	else
		img.draw(Rect((o.x+hx-8, o.y+hy), (o.x+hx+8, o.y+hy+20)), ink[0], nil, Point(0, 0));
}

draw_tree(img: ref Image, o: Point, t: Tree)
{
	img.draw(Rect((o.x+t.x-2, o.y+t.y+4), (o.x+t.x+2, o.y+t.y+12)), ink[6], nil, Point(0, 0));
	col := ink[2];
	if(t.fire){
		if(t.fire_tick & 1)
			col = ink[12];
		else
			col = ink[4];
	}
	img.ellipse(Point(o.x+t.x, o.y+t.y), 8, 8, 0, col, Point(0, 0));
}

draw_peasant(img: ref Image, o: Point, p: Peasant)
{
	x := int p.x;
	y := int p.y;
	r := 5;
	if(!p.stopped && (animate_phase & 1))
		r = 4;
	img.ellipse(Point(o.x+x, o.y+y), r, r, 0, ink[1], Point(0, 0));
}

draw_king(img: ref Image, o: Point, ts: real)
{
	x := king_x;
	y := king_y;
	wob := 0;
	if(ts < king_timeout && (king_phase & 1))
		wob = 1;
	img.ellipse(Point(o.x+x, o.y+y-wob), 7, 7, 0, ink[14], Point(0, 0));
	img.line(Point(o.x+x-4, o.y+y-12-wob), Point(o.x+x, o.y+y-18-wob), 0, 0, 1, ink[14], Point(0, 0));
	img.line(Point(o.x+x, o.y+y-18-wob), Point(o.x+x+4, o.y+y-12-wob), 0, 0, 1, ink[14], Point(0, 0));
}

songloop()
{
	score := "5eCCCDCC4qGeAGAB5qCC5eCCCDCC4qGeAGAB5qCC5eGFEDEDqC4eAGAB5qCC";
	for(;;){
		if(!song_pause && have_tone)
			tone->play(score);
		sys->sleep(500);
	}
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

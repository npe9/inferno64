implement Titanium;

# TempleOS Apps/Titanium/Titanium.HC — vertical scrolling shooter
# GAP: no unit sprites / map layers / friendly-fire scoring — rects + ellipses
# GAP: no missile bitmaps
# arrows move  space fire  Enter restart  q quit

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

Titanium: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

BMAX: con 64;
EMAX: con 48;
BSPD: con 9;
ESPD: con 2;

Bullet: adt { x, y: int; dx, dy: int; live: int; };
Enemy: adt { x, y: int; live: int; kind: int; };

win: ref Window;
ink: array of ref Image;
bullets: array of Bullet;
enemies: array of Enemy;
px, py: int;
scroll: int;
score, best_score: int;
game_over: int;
fire_cd := 0;
spawn_cd := 0;
kdx, kdy: int;
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

	win = wmclient->window(ctxt, "TempleOS Titanium", Wmclient->Appl);
	d := win.display;
	ink = array[8] of ref Image;
	ink[0] = d.color(Draw->Black);
	ink[1] = d.color(Draw->Green);
	ink[2] = d.color(Draw->Cyan);
	ink[3] = d.color(Draw->Blue);
	ink[4] = d.color(Draw->Red);
	ink[5] = d.color(Draw->Yellow);
	ink[6] = d.color(Draw->White);
	ink[7] = d.color(int 16r444444FF);
	bullets = array[BMAX] of Bullet;
	enemies = array[EMAX] of Enemy;
	best_score = 0;
	if(scorestore != nil)
		best_score = scorestore->loadint("titanium", best_score);
	game_init();
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "keyup" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 33);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	k := <-win.ctxt.kbd =>
		keydown(k);
	<-ticks =>
		if(!game_over)
			animate();
		redraw();
	}
}

game_init()
{
	i: int;
	img := win.image;
	w := 640; h := 480;
	if(img != nil){
		w = img.r.dx();
		h = img.r.dy();
	}
	px = w/2; py = h - 40;
	scroll = 0;
	score = 0;
	game_over = 0;
	fire_cd = spawn_cd = 0;
	kdx = kdy = 0;
	for(i = 0; i < BMAX; i++)
		bullets[i].live = 0;
	for(i = 0; i < EMAX; i++)
		enemies[i].live = 0;
	for(i = 0; i < 8; i++)
		spawnenemy();
}

keydown(k: int)
{
	case k {
	16r1b or 'q' or 'Q' =>
		if(have_tone) tone->stop();
		exit;
	'\n' =>
		game_init();
	' ' =>
		fire();
	Keyboard->Left or 'a' or 'A' =>
		kdx = -1; kdy = 0;
	Keyboard->Right or 'd' or 'D' =>
		kdx = 1; kdy = 0;
	Keyboard->Up or 'w' or 'W' =>
		kdx = 0; kdy = -1;
	Keyboard->Down or 's' or 'S' =>
		kdx = 0; kdy = 1;
	Keyboard->Keyup | (Keyboard->Left & 16r7ff) or
	Keyboard->Keyup | 'a' or Keyboard->Keyup | 'A' =>
		if(kdx == -1) kdx = 0;
	Keyboard->Keyup | (Keyboard->Right & 16r7ff) or
	Keyboard->Keyup | 'd' or Keyboard->Keyup | 'D' =>
		if(kdx == 1) kdx = 0;
	Keyboard->Keyup | (Keyboard->Up & 16r7ff) or
	Keyboard->Keyup | 'w' or Keyboard->Keyup | 'W' =>
		if(kdy == -1) kdy = 0;
	Keyboard->Keyup | (Keyboard->Down & 16r7ff) or
	Keyboard->Keyup | 's' or Keyboard->Keyup | 'S' =>
		if(kdy == 1) kdy = 0;
	}
}

fire()
{
	i: int;
	if(game_over || fire_cd > 0)
		return;
	for(i = 0; i < BMAX; i++){
		if(!bullets[i].live){
			bullets[i] = Bullet(px, py-12, 0, -BSPD, 1);
			fire_cd = 4;
			if(have_tone)
				tone->beep(80, 20);
			break;
		}
	}
}

spawnenemy()
{
	i: int;
	for(i = 0; i < EMAX; i++){
		if(!enemies[i].live){
			enemies[i] = Enemy(rn(620)+10, -rn(120)-20, 1, rn(3));
			return;
		}
	}
}

animate()
{
	i, j: int;
	img := win.image;
	w := 640; h := 480;
	if(img != nil){
		w = img.r.dx();
		h = img.r.dy();
	}
	px += kdx * 6;
	py += kdy * 4;
	if(px < 16) px = 16;
	if(px > w-16) px = w-16;
	if(py < 24) py = 24;
	if(py > h-16) py = h-16;
	if(fire_cd > 0)
		fire_cd--;
	scroll += 1;
	if(spawn_cd <= 0){
		spawnenemy();
		spawn_cd = 18 - score/200;
		if(spawn_cd < 6)
			spawn_cd = 6;
	}else
		spawn_cd--;
	for(i = 0; i < BMAX; i++){
		if(!bullets[i].live)
			continue;
		bullets[i].x += bullets[i].dx;
		bullets[i].y += bullets[i].dy;
		if(bullets[i].y < -20 || bullets[i].x < -10 || bullets[i].x > w+10)
			bullets[i].live = 0;
	}
	for(i = 0; i < EMAX; i++){
		if(!enemies[i].live)
			continue;
		enemies[i].y += ESPD + enemies[i].kind;
		enemies[i].x += (px - enemies[i].x) / 80;
		if(enemies[i].y > h+30)
			enemies[i].live = 0;
	}
	for(i = 0; i < EMAX; i++){
		if(!enemies[i].live)
			continue;
		for(j = 0; j < BMAX; j++){
			if(!bullets[j].live)
				continue;
			dx := bullets[j].x - enemies[i].x;
			dy := bullets[j].y - enemies[i].y;
			if(dx*dx + dy*dy < 400){
				enemies[i].live = 0;
				bullets[j].live = 0;
				score += 10 + enemies[i].kind*5;
				if(have_tone)
					tone->beep(40 + rn(30), 30);
				break;
			}
		}
	}
	for(i = 0; i < EMAX; i++){
		if(!enemies[i].live)
			continue;
		dx := px - enemies[i].x;
		dy := py - enemies[i].y;
		if(dx*dx + dy*dy < 400){
			game_over = 1;
			if(score > best_score){
				best_score = score;
				if(scorestore != nil)
					scorestore->saveint("titanium", best_score);
			}
			if(have_tone)
				tone->beep(20, 200);
			break;
		}
	}
}

redraw()
{
	i: int;
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	img.draw(img.r, ink[0], nil, Point(0, 0));
	# scrolling stripes
	for(y := 0; y < h; y += 32){
		yy := (y + scroll) % 32;
		if(yy < 16)
			img.draw(Rect((o.x, o.y+y), (o.x+w, o.y+y+16)), ink[7], nil, Point(0, 0));
	}
	for(i = 0; i < EMAX; i++){
		if(!enemies[i].live)
			continue;
		e := enemies[i];
		col := ink[4];
		if(e.kind == 1)
			col = ink[5];
		if(e.kind == 2)
			col = ink[3];
		img.draw(Rect((o.x+e.x-10, o.y+e.y-8), (o.x+e.x+10, o.y+e.y+8)), col, nil, Point(0, 0));
	}
	for(i = 0; i < BMAX; i++){
		if(!bullets[i].live)
			continue;
		b := bullets[i];
		img.draw(Rect((o.x+b.x-1, o.y+b.y-6), (o.x+b.x+1, o.y+b.y+2)), ink[6], nil, Point(0, 0));
	}
	img.fillellipse(Point(o.x+px, o.y+py), 12, 8, ink[2], Point(0, 0));
	img.ellipse(Point(o.x+px, o.y+py), 12, 8, 0, ink[6], Point(0, 0));
	# HUD
	img.draw(Rect((o.x+8, o.y+8), (o.x+108, o.y+18)), ink[1], nil, Point(0, 0));
	bw := score;
	if(bw > 100) bw = 100;
	img.draw(Rect((o.x+8, o.y+8), (o.x+8+bw, o.y+18)), ink[5], nil, Point(0, 0));
	if(game_over){
		img.draw(Rect((o.x+w/2-80, o.y+h/2-20), (o.x+w/2+80, o.y+h/2+20)), ink[4], nil, Point(0, 0));
		img.draw(Rect((o.x+w/2-76, o.y+h/2-16), (o.x+w/2+76, o.y+h/2+16)), ink[0], nil, Point(0, 0));
	}
	img.flush(Draw->Flushnow);
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

implement Blackdiamond;

# TempleOS Demo/Games/BlackDiamond.HC — ski downhill, avoid obstacles
# GAP: Sprite3 depth + wolf animation + chair-lift wire → colored shapes
# GAP: collision sprite test → circle hit; RegWrite best score not persisted
# arrows move (wrap)  Enter restart  q quit

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

Blackdiamond: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

MAPHT: con 3000;
OBJN: con 64;
W: con 640;
H: con 480;

T_TREE: con 0;
T_ROCK: con 1;
T_BIG: con 2;
T_WOLF: con 3;
T_LIFT: con 4;

win: ref Window;
font: ref Font;
black, snow, tree, rock, bigrock, wolf, lift, man, red, green, white: ref Image;
have_tone := 0;
blink_on := 0;

obj_x, obj_y, obj_type: array of int;
obj_saved_x, obj_saved_y: array of int;
px, py, scrn_top: int;
penalty := 0;
best_score: int;
game_over := 0;
lift_idx := 0;
hit_flash := 0;

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
	if(rand != nil)
		rand->init(sys->millisec());
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS BlackDiamond", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/lucida/unicode.8.font");
	black = d.color(Draw->Black);
	snow = d.color(Draw->White);
	tree = d.color(int 16r228822FF);
	rock = d.color(int 16r888888FF);
	bigrock = d.color(int 16r555555FF);
	wolf = d.color(int 16r884422FF);
	lift = d.color(Draw->Red);
	man = d.color(int 16r2222FFFF);
	red = d.color(Draw->Red);
	green = d.color(Draw->Green);
	white = d.color(Draw->White);
	best_score = 9999;
	obj_x = array[OBJN] of int;
	obj_y = array[OBJN] of int;
	obj_type = array[OBJN] of int;
	obj_saved_x = array[OBJN] of int;
	obj_saved_y = array[OBJN] of int;
	layout_objects();
	game_init();
	win.reshape(Rect((0, 0), (W, H)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 33);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		case k {
		16r1b or 'q' or 'Q' =>
			if(have_tone) tone->stop();
			exit;
		'\n' or 'r' or 'R' or ' ' =>
			if(game_over)
				game_init();
		Keyboard->Right =>
			if(!game_over){
				px += 10;
				if(px >= W) px -= W;
			}
		Keyboard->Left =>
			if(!game_over){
				px -= 10;
				if(px < 0) px += W;
			}
		}
	<-ticks =>
		if(!game_over)
			step();
		if(hit_flash > 0)
			hit_flash--;
		blink_on = (sys->millisec() / 250) % 2;
		redraw();
	}
}

layout_objects()
{
	for(i := 0; i < OBJN; i++){
		obj_saved_y[i] = rn(MAPHT - 200) + 200;
		obj_saved_x[i] = rn(W);
		j := rn(256);
		if(j & 7)
			obj_type[i] = T_TREE;
		else if(j & 31)
			obj_type[i] = T_ROCK;
		else if(j & 63)
			obj_type[i] = T_BIG;
		else
			obj_type[i] = T_WOLF;
	}
	lift_idx = rn(OBJN);
	obj_type[lift_idx] = T_LIFT;
}

game_init()
{
	for(i := 0; i < OBJN; i++){
		obj_x[i] = obj_saved_x[i];
		obj_y[i] = obj_saved_y[i];
	}
	px = W / 2;
	py = 0;
	scrn_top = 0;
	penalty = 0;
	game_over = 0;
	hit_flash = 0;
}

step()
{
	py += 2;
	scrn_top++;
	if(scrn_top > py - H/2 && py - scrn_top < H)
		scrn_top = py - H/2;
	if(scrn_top < 0)
		scrn_top = 0;

	for(i := 0; i < OBJN; i++){
		if(obj_type[i] == T_WOLF && absi(px - obj_x[i]) > 3)
			obj_x[i] += 3 * sign(px - obj_x[i]);
	}

	if(check_hit()){
		penalty++;
		hit_flash = 8;
		if(have_tone)
			tone->beep(58, 40);
	}

	if(py >= MAPHT){
		game_over = 1;
		if(penalty <= best_score)
			best_score = penalty;
		if(have_tone)
			tone->beep(440, 200);
	}
}

check_hit(): int
{
	sy := py - scrn_top;
	for(i := 0; i < OBJN; i++){
		oy := obj_y[i] - scrn_top;
		if(oy < -40 || oy > H + 40)
			continue;
		if(obj_y[i] > py + 10)
			continue;
		r := 14;
		if(obj_type[i] == T_BIG)
			r = 22;
		if(obj_type[i] == T_LIFT)
			continue;
		if(absi(px - obj_x[i]) < r && absi(sy - oy) < r)
			return 1;
	}
	return 0;
}

draw_obj(img: ref Image, o: Point, i: int)
{
	x := obj_x[i];
	y := obj_y[i] - scrn_top;
	if(y < -60 || y > H + 60)
		return;
	col := tree;
	r := 12;
	case obj_type[i] {
	T_ROCK =>
		col = rock;
		r = 8;
	T_BIG =>
		col = bigrock;
		r = 16;
	T_WOLF =>
		col = wolf;
		r = 14;
	T_LIFT =>
		draw_lift(img, o, x, y);
		return;
	}
	img.fillellipse(Point(o.x+x, o.y+y), r, r, col, Point(0, 0));
	if(obj_type[i] == T_TREE){
		img.line(Point(o.x+x, o.y+y-r), Point(o.x+x, o.y+y-24), 0, 0, 0, tree, Point(0, 0));
		img.fillellipse(Point(o.x+x, o.y+y-26), 10, 14, tree, Point(0, 0));
	}
}

draw_lift(img: ref Image, o: Point, x, y: int)
{
	img.line(Point(o.x+x-20, o.y+y-80), Point(o.x+x+20, o.y+y-80), 0, 0, 0, lift, Point(0, 0));
	img.draw(Rect((o.x+x-6, o.y+y-70), (o.x+x+6, o.y+y-58)), lift, nil, Point(0, 0));
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, snow, nil, Point(0, 0));
	o := img.r.min;
	for(i := 0; i < OBJN; i++)
		if(obj_y[i] <= py + 20)
			draw_obj(img, o, i);
	sy := py - scrn_top;
	mcol := man;
	if(hit_flash > 0 && (hit_flash % 2) != 0)
		mcol = red;
	img.fillellipse(Point(o.x+px, o.y+sy), 8, 10, mcol, Point(0, 0));
	img.line(Point(o.x+px, o.y+sy+8), Point(o.x+px, o.y+sy+22), 0, 0, 0, mcol, Point(0, 0));
	for(j := 0; j < OBJN; j++)
		if(obj_y[j] > py)
			draw_obj(img, o, j);
	if(font != nil){
		msg := sys->sprint("Penalty:%d Best:%d", penalty, best_score);
		img.text(Point(o.x+4, o.y+4), green, Point(0, 0), font, msg);
		if(game_over && blink_on)
			img.text(Point(o.x+W/2-40, o.y+H/2), red, Point(0, 0), font, "Game Over");
	}
	img.flush(Draw->Flushnow);
}

sign(v: int): int
{
	if(v > 0) return 1;
	if(v < 0) return -1;
	return 0;
}

absi(v: int): int
{
	if(v < 0) return -v;
	return v;
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

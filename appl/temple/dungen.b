implement Dungen;

# TempleOS Demo/Games/DunGen.HC — dungeon crawl; kill all 10 monsters.
# The level is Terry's FIXED hand-drawn map: sprite <1> sampled every
# MAP_SCALE=4 pixels (Init()'s GrPeek loop); cell value = palette color
# index.  Color 1 (BLUE) draws blinking tile <7>/<8>, 2 (GREEN) tile <5>,
# 8 (DKGRAY) floor tile <6>; any other nonzero color a solid fill.  Only
# DKGRAY is walkable.  The view is drawn through Mat4x4RotX(60°) then
# RotZ(15°) (DCTransform: v' = Rz·Rx·v + centre) — tiles/sprites blit
# flat at transformed points, solid cells as transformed quads, wall-face
# sprites <9>/<10> on void cells whose lower/right neighbour is visible.
# Hold space: every arrow while held attacks (KEY_DOWN sets man_attack,
# KEY_UP clears it).
# GAP: MenuPush File/Play menu bar has no wm(1) equivalent.

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
include "grpalette.m";
	grpal: Grpalette;

Dungen: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

SCALE: con 24;		# SCRN_SCALE
SW: con 24;		# SCRN_WIDTH
SH: con 24;		# SCRN_HEIGHT
MONS: con 10;		# MONSTERS_NUM
LOSS: con 4;		# LOS_SCALE

win: ref Window;
font: ref Font;
ink: array of ref Image;		# the 16 TempleOS palette colors
spr, msk: array of ref Image;		# DunGen.HC bins 1..10
manf, manfm, atkf, atkfm, monf, monfm: ref Image;	# DCF_SYMMETRY mirrors
have_tone := 0;
noisegen := 0;

map: array of array of int;		# temple color index per cell
mapw, maph: int;
scrn_x, scrn_y: int;
man_x, man_y, man_dx, man_dy: int;
man_attack := 0;			# space held
attack_t0 := -1000000;			# ms of last Attack()
mon_x, mon_y, mon_dx, mon_dy, mon_dead: array of int;
monsters_left := 0;
t0, tf: int;				# ms; tf=0 while playing
best_score: real;
c15, s15: real;				# cos/sin 15°
vis: array of array of int;		# per-frame LOS cache, view+1 border

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	tone = load Tone Tone->PATH;
	scorestore = load Scorestore Scorestore->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	rad := Math->Pi * 15.0 / 180.0;
	c15 = math->cos(rad);
	s15 = math->sin(rad);

	win = wmclient->window(ctxt, "TempleOS DunGen", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	pal := grpal->values();
	ink = array[16] of ref Image;
	for(i := 0; i < 16; i++)
		ink[i] = d.color(pal[i]);
	spr = array[11] of ref Image;
	msk = array[11] of ref Image;
	for(i = 1; i <= 10; i++){
		spr[i] = d.open(sys->sprint("/icons/temple/dungen_%d.bit", i));
		msk[i] = d.open(sys->sprint("/icons/temple/dungen_%d.mask", i));
	}
	if(spr[1] == nil || msk[1] == nil){
		sys->fprint(sys->fildes(2), "dungen: cannot open /icons/temple/dungen_1.bit/.mask\n");
		exit;
	}
	manf = flipimage(d, spr[2]);
	manfm = flipimage(d, msk[2]);
	atkf = flipimage(d, spr[3]);
	atkfm = flipimage(d, msk[3]);
	monf = flipimage(d, spr[4]);
	monfm = flipimage(d, msk[4]);

	loadmap();

	best_score = 9999.0;
	if(scorestore != nil)
		best_score = scorestore->loadreal("dungen", best_score);
	game_init();
	win.reshape(Rect((0, 0), (640, 480)));	# WinMax on the 640x480 screen
	win.onscreen("place");
	win.startinput("kbd" :: "keyup" :: "ptr" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 16);
	mtick := chan of int;
	spawn timer(mtick, 1000);	# AnimateTask Sleep(1000)
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
		'\n' or 'r' or 'R' =>
			game_init();
		' ' =>
			man_attack = 1;
		Keyboard->Keyup | ' ' =>
			man_attack = 0;
		Keyboard->Right or 'd' or 'D' =>
			dir_key(1, 0);
		Keyboard->Left or 'a' or 'A' =>
			dir_key(-1, 0);
		Keyboard->Up or 'w' or 'W' =>
			dir_key(0, -1);
		Keyboard->Down or 's' or 'S' =>
			dir_key(0, 1);
		}
	<-mtick =>
		move_monsters();
	<-ticks =>
		redraw();
	}
}

# Sample the map out of sprite <1> exactly as Init() does: GrPeek every
# 4 px from the sprite's tight bounding box.  Our rasterized bbox is 2px
# looser than TempleOS SpriteExtents on this sprite, hence the (2,2)
# sample offset — verified: it puts the original start cell (0,4) on
# DKGRAY floor and yields a fully connected 34x26 floor, while offset
# (0,0)/(1,*) leave the start on void or disconnect corridors.
loadmap()
{
	r := spr[1].r;
	w := r.dx();
	h := r.dy();
	buf := array[w*h] of byte;
	spr[1].readpixels(r, buf);
	mrow := (w+7)/8;
	mbuf := array[mrow*h] of byte;
	msk[1].readpixels(r, mbuf);
	# inferno m8 cmap byte for each of the 16 TempleOS palette colors
	cmapb := array[] of {0, 36, 42, 44, 160, 162, 164, 170,
			85, 121, 127, 113, 245, 247, 253, 255};
	inv := array[256] of {* => 0};
	for(i := 0; i < 16; i++)
		inv[cmapb[i]] = i;
	mapw = (w-2)/4;
	maph = (h-2)/4;
	map = array[maph] of array of int;
	for(y := 0; y < maph; y++){
		map[y] = array[mapw] of int;
		for(x := 0; x < mapw; x++){
			px := 2 + 4*x;
			py := 2 + 4*y;
			if(((int mbuf[py*mrow + px/8] >> (7 - px%8)) & 1) == 0)
				map[y][x] = 0;
			else
				map[y][x] = inv[int buf[py*w + px]];
		}
	}
	vis = array[SH+1] of { * => array[SW+1] of { * => 0 } };
}

game_init()
{
	# the original's fixed start (see the map-edit comment in DunGen.HC)
	man_x = 0;
	man_y = 4;
	man_dx = 0;
	man_dy = 0;
	man_attack = 0;
	attack_t0 = -1000000;
	scrn_x = 0;
	scrn_y = 0;
	mon_x = array[MONS] of int;
	mon_y = array[MONS] of int;
	mon_dx = array[MONS] of {* => 0};
	mon_dy = array[MONS] of {* => 0};
	mon_dead = array[MONS] of {* => 0};
	for(i := 0; i < MONS; i++){
		do {
			mon_x[i] = 1 + rn(mapw-2);
			mon_y[i] = 1 + rn(maph-2);
		} while(map[mon_y[i]][mon_x[i]] == 0);
	}
	monsters_left = MONS;
	tf = 0;
	t0 = sys->millisec();
}

dir_key(dx, dy: int)
{
	if(man_attack){
		man_dx = dx;
		man_dy = dy;
		attack();
		return;
	}
	nx := man_x + dx;
	ny := man_y + dy;
	if(nx < 0 || nx >= mapw || ny < 0 || ny >= maph)
		return;
	if(map[ny][nx] != 8)	# only DKGRAY is walkable
		return;
	man_x = nx;
	man_y = ny;
	# half-screen scroll jumps, clamped as the original does per direction
	if(dx == 1 && man_x - scrn_x > SW/2 - 3){
		scrn_x += SW/2;
		if(scrn_x + SW/2 > mapw)
			scrn_x = mapw - SW/2;
	}
	if(dx == -1 && man_x - scrn_x < -SW/2 + 3){
		scrn_x -= SW/2;
		if(scrn_x - SW/2 < 0)
			scrn_x = SW/2;
	}
	if(dy == 1 && man_y - scrn_y > SH/2 - 3){
		scrn_y += SH/2;
		if(scrn_y + SH/2 > maph)
			scrn_y = maph - SH/2;
	}
	if(dy == -1 && man_y - scrn_y < -SH/2 + 3){
		scrn_y -= SH/2;
		if(scrn_y - SH/2 < 0)
			scrn_y = SH/2;
	}
}

attack()
{
	attack_t0 = sys->millisec();
	if(have_tone){
		noisegen++;
		spawn noise(noisegen);
	}
	for(i := 0; i < MONS; i++){
		if(mon_dead[i])
			continue;
		if(mon_x[i] == man_x + man_dx && mon_y[i] == man_y + man_dy){
			mon_dead[i] = 1;
			if(--monsters_left == 0){
				tf = sys->millisec();
				elapsed := real (tf - t0) / 1000.0;
				if(elapsed < best_score){
					best_score = elapsed;
					if(scorestore != nil)
						scorestore->savereal("dungen", best_score);
				}
			}
		}
	}
}

# Noise(100,53,74): 100ms of random tones between semitones (ona) 53..74,
# queued asynchronously; freq = 440*2^((ona-60)/12)
noise(gen: int)
{
	for(t := 0; t < 100; t += 20){
		if(gen != noisegen)
			return;
		ona := 53 + rn(22);
		tone->snd(int (440.0 * math->pow(2.0, real (ona-60) / 12.0)));
		sys->sleep(20);
	}
	if(gen == noisegen)
		tone->stop();
}

move_monsters()
{
	for(i := 0; i < MONS; i++){
		if(mon_dead[i])
			continue;
		dx := rn(3) - 1;
		dy := rn(3) - 1;
		x := mon_x[i] + dx;
		y := mon_y[i] + dy;
		# any nonzero cell will do, the player's included
		if(x >= 0 && x < mapw && y >= 0 && y < maph && map[y][x] != 0){
			mon_x[i] = x;
			mon_y[i] = y;
			mon_dx[i] = dx;
			mon_dy[i] = dy;
		}
	}
}

# LOS at LOS_SCALE=4 subsample with centre offsets, blocking on ZERO
# (void) cells only — colored feature cells pass, as in LOSPlot()
los(x1, y1, x2, y2: int): int
{
	px1 := x1*LOSS + LOSS/2;
	py1 := y1*LOSS + LOSS/2;
	px2 := x2*LOSS + LOSS/2;
	py2 := y2*LOSS + LOSS/2;
	dx := absi(px2 - px1);
	dy := absi(py2 - py1);
	sx := 1;
	if(px1 > px2) sx = -1;
	sy := 1;
	if(py1 > py2) sy = -1;
	err := dx - dy;
	x := px1;
	y := py1;
	for(;;){
		if(map[y/LOSS][x/LOSS] == 0)
			return 0;
		if(x == px2 && y == py2)
			return 1;
		e2 := 2 * err;
		if(e2 > -dy){
			err -= dy;
			x += sx;
		}
		if(e2 < dx){
			err += dx;
			y += sy;
		}
	}
}

# v' = Rz(15°)·Rx(60°)·v + centre; z is unused by Sprite3's blit.
# Rx(60°) with z=0 just scales y by cos 60° = 1/2.
trans(x, y: real, cx, cy: int): Point
{
	yr := y * 0.5;
	return Point(cx + int (x*c15 - yr*s15), cy + int (x*s15 + yr*c15));
}

blit(img: ref Image, p: Point, s, m: ref Image)
{
	if(s == nil)
		return;
	img.draw(s.r.addpt(p), s, m, s.r.min);
}

# tiles1/tiles2 by color index; Blink(5) picks between them
tileno(color, blnk: int): int
{
	case color {
	1 =>	if(blnk) return 7; return 8;
	2 =>	return 5;
	8 =>	return 6;
	}
	return 0;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	cx := o.x + img.r.dx()/2;
	cy := o.y + img.r.dy()/2;
	ms := sys->millisec();
	blnk5 := (ms/100) % 2;	# Blink(5): toggles at 10/s
	blnkb := (ms/200) % 2;	# Blink() default 2.5Hz: toggles at 5/s
	img.draw(img.r, ink[0], nil, Point(0, 0));

	# LOS cache over the view plus a one-cell border for the wall faces
	for(y := -SH/2; y <= SH/2; y++){
		yy := y + scrn_y;
		for(x := -SW/2; x <= SW/2; x++){
			xx := x + scrn_x;
			v := 0;
			if(xx >= 0 && xx < mapw && yy >= 0 && yy < maph &&
			   map[yy][xx] != 0 && los(xx, yy, man_x, man_y))
				v = 1;
			vis[y+SH/2][x+SW/2] = v;
		}
	}

	# pass 1: tiles and solid-color cells
	poly := array[4] of Point;
	for(y = -SH/2; y < SH/2; y++){
		yy := y + scrn_y;
		if(yy < 0 || yy >= maph)
			continue;
		for(x := -SW/2; x < SW/2; x++){
			xx := x + scrn_x;
			if(xx < 0 || xx >= mapw)
				continue;
			color := map[yy][xx];
			if(color == 0 || !vis[y+SH/2][x+SW/2])
				continue;
			t := tileno(color, blnk5);
			if(t != 0)
				blit(img, trans(real (x*SCALE), real (y*SCALE), cx, cy), spr[t], msk[t]);
			else {
				poly[0] = trans(real (x*SCALE), real (y*SCALE), cx, cy);
				poly[1] = trans(real ((x+1)*SCALE-1), real (y*SCALE), cx, cy);
				poly[2] = trans(real ((x+1)*SCALE), real ((y+1)*SCALE-1), cx, cy);
				poly[3] = trans(real (x*SCALE-1), real ((y+1)*SCALE-1), cx, cy);
				img.fillpoly(poly, ~0, ink[color & 15], Point(0, 0));
			}
		}
	}

	# pass 2: wall-face sprites <9>/<10> on void cells whose lower/right
	# neighbour is visible floor
	for(y = -SH/2; y < SH/2; y++){
		yy := y + scrn_y;
		if(yy < 0 || yy >= maph)
			continue;
		for(x := -SW/2; x < SW/2; x++){
			xx := x + scrn_x;
			if(xx < 0 || xx >= mapw)
				continue;
			if(map[yy][xx] != 0)
				continue;
			if(yy+1 < maph && vis[y+1+SH/2][x+SW/2])
				blit(img, trans(real (x*SCALE), real (y*SCALE), cx, cy), spr[9], msk[9]);
			if(xx+1 < mapw && vis[y+SH/2][x+1+SW/2])
				blit(img, trans(real (x*SCALE), real (y*SCALE), cx, cy), spr[10], msk[10]);
		}
	}

	# monsters, mirrored via DCF_SYMMETRY when walking left
	for(i := 0; i < MONS; i++){
		if(mon_dead[i] || !los(mon_x[i], mon_y[i], man_x, man_y))
			continue;
		p := trans(real ((mon_x[i]-scrn_x)*SCALE + SCALE/2),
			real ((mon_y[i]-scrn_y)*SCALE + SCALE/2), cx, cy);
		if(mon_dx[i] < 0)
			blit(img, p, monf, monfm);
		else
			blit(img, p, spr[4], msk[4]);
	}

	# player; attack lunge: Tri(t,0.2)*SCALE towards the blow with a
	# Saw(t,0.2)*SCALE rise unless striking downward
	x1 := real ((man_x-scrn_x)*SCALE + SCALE/2);
	y1 := real ((man_y-scrn_y)*SCALE + SCALE/2);
	dt := ms - attack_t0;
	attacking := dt >= 0 && dt < 200;
	if(attacking){
		tri: real;
		if(dt <= 100)
			tri = real dt / 100.0;
		else
			tri = real (200 - dt) / 100.0;
		x1 += tri * real SCALE * real man_dx;
		y1 += tri * real SCALE * real man_dy;
		if(man_dy != 1)
			y1 -= (real dt / 200.0) * real SCALE;
	}
	p := trans(x1, y1, cx, cy);
	if(attacking){
		if(man_dx < 0)
			blit(img, p, atkf, atkfm);
		else
			blit(img, p, spr[3], msk[3]);
	} else {
		if(man_dx < 0)
			blit(img, p, manf, manfm);
		else
			blit(img, p, spr[2], msk[2]);
	}

	# HUD: LTGREEN while playing, LTRED once completed, GrPrint at (0,0)
	if(font != nil){
		col := ink[10];
		tt := ms;
		if(tf){
			col = ink[12];
			tt = tf;
			if(blnkb)
				img.text(Point(cx - 8*14/2, cy - 8/2), col,
					Point(0, 0), font, "Game Completed");
		}
		msg := sys->sprint("Enemy:%d Time:%3.2f Best:%3.2f",
			monsters_left, real (tt - t0) / 1000.0, best_score);
		img.text(o, col, Point(0, 0), font, msg);
	}
	img.flush(Draw->Flushnow);
}

# horizontal mirror about the sprite origin (DCF_SYMMETRY|DCF_JUST_MIRROR
# with a vertical symmetry line through the anchor)
flipimage(d: ref Display, src: ref Image): ref Image
{
	if(src == nil)
		return nil;
	sw := src.r.dx();
	n := d.newimage(Rect((1-src.r.max.x, src.r.min.y), (1-src.r.min.x, src.r.max.y)),
		src.chans, 0, 0);
	if(n == nil)
		return nil;
	for(i := 0; i < sw; i++)
		n.draw(Rect((-(src.r.min.x+i), n.r.min.y), (-(src.r.min.x+i)+1, n.r.max.y)),
			src, nil, Point(src.r.min.x+i, src.r.min.y));
	return n;
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

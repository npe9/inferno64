implement Flattops;

# TempleOS Demo/Games/FlatTops.HC — carrier task-force RTS
#
# Timing: the original runs a 50Hz AnimateTask (Sleep(1000/ANIMATE_FREQ), i.e.
# 20ms) with period = 0.1*game_speed/50 per tick, so movement/combat advance
# by 0.1*game_speed per real second.  This port ticks at 20Hz (50ms) and uses
# period = 0.1*game_speed/20 per tick — the same per-second rates, and the
# same Rand < k*period combat/AI probabilities per second.  The original's
# ~30fps winmgr redraw is folded into the same 20Hz tick.
#
# GAP: no MenuPush File/Play menu bar; its actions are on keys already
#      (Enter restart, +/- speed, Esc quit)
# GAP: no Ctrl-Left grab screen scrolling (fixed 800x600 window instead of a
#      scrollable maximized task; the startup popup omits that line)
# GAP: MSG_MS_R_D_UP squadron return approximated as a 400ms/20px right
#      double-tap

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

include "rand.m";
	rand: Rand;

include "tone.m";
	tone: Tone;

Flattops: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

OT_CARRIER, OT_CRUISER, OT_FIGHTER: con iota;
OF_SHIP: con 1;
OF_ACTIVE: con 2;
OF_RETURN: con 4;

PLAYERS: con 2;
MAX_OBJ: con 80;
MAX_TORP: con 32;

ANIMFREQ: con 20;	# our tick rate, Hz (original ANIMATE_FREQ=50)
NOPOS: con 1e9;		# "no coordinate" sentinel (original F64_MAX)
NOHDG: con 1e9;		# "no heading" sentinel (original F64_MAX)

# ShipDamage/ShipFix fire bitmap, straight from the original
FIREW: con 56;
FIREH: con 16;
FIREB: con FIREW*FIREH;
FIREXSC: con 0.5;
FIREYSC: con 0.5;

NROT: con 48;		# precomputed Sprite3ZB rotation steps (7.5 degrees)

Obj: adt {
	used: int;
	player, otype, squadron, member: int;
	flags: int;
	x, y, theta, dtheta: real;
	speed, turn_rate: real;
	life, fuel, maxfuel, burn: real;
	ship_guns, ship_range, air_guns, air_range: real;
	torps, maxtorps: int;
	torp_range: real;
	host_idx: int;
	target_x, target_y: real;
	shooting: int;
	next_act: real;
	death_time: real;		# torpedo-in-flight hold (original ObjDel)
	fire: array of byte;		# FIREB bits, ships only
};

Torpedo: adt {
	used: int;
	x, y, theta, speed: real;
	timeout: real;
	target_idx: int;
};

Squadron: adt {
	action: int;
	player: int;
	host_idx: int;
	heading: real;
	dead_mask, total_mask: int;
};

SA_PARKED, SA_LAUNCH, SA_FLYING, SA_SETHDG, SA_RETURN, SA_DEAD: con iota;

# rotated-sprite set for one original DolDoc bin
Spr: adt {
	w, h, ox, oy: int;		# source dims, origin offset (r.min)
	pix: array of byte;		# m8 pixels
	opq: array of byte;		# 1 = opaque
	rad: int;
	rot: array of ref Image;	# CMAP8, one per NROT step
	rotm: array of ref Image;	# GREY1 masks
};

win: ref Window;
font: ref Font;
fonth := 8;
ink: array of ref Image;
have_tone := 0;
sndgen := 0;

# imgs[2][3]: bins 1,2,3 = player 1 carrier/cruiser/fighter; 4,5,6 = player 2
sprs: array of array of ref Spr;

objs: array of Obj;
torps: array of Torpedo;
sq: array of Squadron;
nsq, nobj: int;

game_speed: real;
num_alive: array of int = array[PLAYERS] of { * => 0 };
launch_t, return_t, sethdg_t: real;
launch_x1, launch_y1, launch_x2, launch_y2: real;
return_x1, return_y1, return_x2, return_y2: real;
sethdg_x1, sethdg_y1, sethdg_x2, sethdg_y2: real;
next_noise: real;
help_on := 1;

mx, my: int;
last_rb_t: int;
last_rb_x, last_rb_y: int;
ptr_lb, ptr_rb: int;

num_carriers: array of int = array[PLAYERS] of { 2, 3 };
num_cruisers: array of int = array[PLAYERS] of { 2, 3 };
planes_per_sq: array of int = array[PLAYERS] of { 6, 5 };
sq_per_carrier: array of int = array[PLAYERS] of { 2, 3 };

# fire_colors[16] = YELLOW,YELLOW,LTRED,YELLOW, BLACK,YELLOW,RED,YELLOW,
#                   YELLOW,BLACK,YELLOW,LTRED,  RED,YELLOW,DKGRAY,YELLOW
fire_colors: array of int = array[] of {
	14, 14, 12, 14, 0, 14, 4, 14,
	14, 0, 14, 12, 4, 14, 8, 14
};

# kernel gr_x_offsets/gr_y_offsets (Adam/Gr/GrMath.HC)
grxoff: array of int = array[] of { -1, 0, 1, -1, 1, -1, 0, 1 };
gryoff: array of int = array[] of { -1, -1, -1, 0, 0, 1, 1, 1 };

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

	win = wmclient->window(ctxt, "TempleOS FlatTops", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil){
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
		if(font != nil)
			fonth = font.height;
	}
	# the exact TempleOS 16-color palette, index = TempleOS color
	ink = array[16] of ref Image;
	cols := array[] of {
		int 16r000000FF, int 16r0000AAFF, int 16r00AA00FF, int 16r00AAAAFF,
		int 16rAA0000FF, int 16rAA00AAFF, int 16rAA5500FF, int 16rAAAAAAFF,
		int 16r555555FF, int 16r5555FFFF, int 16r55FF55FF, int 16r55FFFFFF,
		int 16rFF5555FF, int 16rFF55FFFF, int 16rFFFF55FF, int 16rFFFFFFFF
	};
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);

	loadsprites(d);

	objs = array[MAX_OBJ] of Obj;
	torps = array[MAX_TORP] of Torpedo;
	sq = array[32] of Squadron;

	win.reshape(Rect((0, 0), (800, 600)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	game_init();

	ticks := chan of int;
	spawn timer(ticks, 1000/ANIMFREQ);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		handleptr(p);
	k := <-win.ctxt.kbd =>
		if(help_on){
			help_on = 0;
			continue;
		}
		case k {
		16r1b or 'q' or 'Q' =>
			if(have_tone)
				tone->stop();
			exit;
		'\n' or 'r' or 'R' =>
			game_init();
		'+' or '=' =>
			game_speed *= 1.5;
		'-' or '_' =>
			game_speed /= 1.5;
		}
	<-ticks =>
		if(!help_on)
			sim_step();
		redraw();
	}
}

# --- sprites: the six original DolDoc bins, pre-rotated Sprite3ZB-style ---

loadsprites(d: ref Display)
{
	sprs = array[PLAYERS] of array of ref Spr;
	for(p := 0; p < PLAYERS; p++){
		sprs[p] = array[3] of ref Spr;
		for(t := 0; t < 3; t++)
			sprs[p][t] = loadspr(d, 1 + 3*p + t);
	}
}

loadspr(d: ref Display, n: int): ref Spr
{
	im := d.open(sys->sprint("/icons/temple/flattops_%d.bit", n));
	mk := d.open(sys->sprint("/icons/temple/flattops_%d.mask", n));
	if(im == nil || mk == nil)
		return nil;
	s := ref Spr;
	s.w = im.r.dx();
	s.h = im.r.dy();
	s.ox = im.r.min.x;
	s.oy = im.r.min.y;
	s.pix = array[s.w*s.h] of byte;
	if(im.readpixels(im.r, s.pix) < s.w*s.h)
		return nil;
	bpr := (s.w+7)/8;
	mb := array[bpr*s.h] of byte;
	if(mk.readpixels(mk.r, mb) < bpr*s.h)
		return nil;
	s.opq = array[s.w*s.h] of byte;
	for(j := 0; j < s.h; j++)
		for(i := 0; i < s.w; i++)
			s.opq[j*s.w+i] = (mb[j*bpr + i/8] >> (7-(i&7))) & byte 1;
	# bounding radius about the sprite origin
	md := 0.0;
	for(cy := 0; cy < 2; cy++)
		for(cx := 0; cx < 2; cx++){
			px := real(s.ox + cx*(s.w-1));
			py := real(s.oy + cy*(s.h-1));
			dd := math->sqrt(px*px + py*py);
			if(dd > md)
				md = dd;
		}
	s.rad = int md + 2;
	s.rot = array[NROT] of ref Image;
	s.rotm = array[NROT] of ref Image;
	for(k := 0; k < NROT; k++)
		if(buildrot(d, s, k) < 0)
			return nil;
	return s;
}

buildrot(d: ref Display, s: ref Spr, k: int): int
{
	a := real k * 2.0*Math->Pi / real NROT;
	ca := math->cos(a);
	sa := math->sin(a);
	side := 2*s.rad;
	bpr := (side+7)/8;
	dpix := array[side*side] of { * => byte 0 };
	dmsk := array[bpr*side] of { * => byte 0 };
	for(dy := 0; dy < side; dy++){
		ry := real(dy - s.rad);
		for(dx := 0; dx < side; dx++){
			rx := real(dx - s.rad);
			# inverse rotation, nearest-neighbour sample
			sx := int(rx*ca + ry*sa);
			sy := int(-rx*sa + ry*ca);
			i := sx - s.ox;
			j := sy - s.oy;
			if(i < 0 || i >= s.w || j < 0 || j >= s.h)
				continue;
			if(s.opq[j*s.w+i] == byte 0)
				continue;
			dpix[dy*side+dx] = s.pix[j*s.w+i];
			dmsk[dy*bpr + dx/8] |= byte(1 << (7-(dx&7)));
		}
	}
	r := Rect((-s.rad, -s.rad), (s.rad, s.rad));
	im := d.newimage(r, Draw->CMAP8, 0, Draw->Black);
	mk := d.newimage(r, Draw->GREY1, 0, Draw->Black);
	if(im == nil || mk == nil)
		return -1;
	im.writepixels(r, dpix);
	mk.writepixels(r, dmsk);
	s.rot[k] = im;
	s.rotm[k] = mk;
	return 0;
}

sprvariant(theta: real): int
{
	# Sprite3ZB(..., theta + pi/2)
	a := math->fmod(theta + Math->Pi/2.0, 2.0*Math->Pi);
	if(a < 0.0)
		a += 2.0*Math->Pi;
	return int(a * real NROT / (2.0*Math->Pi)) % NROT;
}

# --- game setup ---

game_init()
{
	i, player, ship, squadron, fighter: int;
	w := 800; h := 600;
	img := win.image;
	if(img != nil){
		w = img.r.dx();
		h = img.r.dy();
	}
	for(i = 0; i < MAX_OBJ; i++)
		objs[i].used = 0;
	for(i = 0; i < MAX_TORP; i++)
		torps[i].used = 0;
	nobj = 0;
	nsq = 0;
	game_speed = 1.0;
	launch_t = return_t = sethdg_t = 0.0;
	next_noise = 0.0;
	last_rb_t = 0;
	ptr_lb = ptr_rb = 0;

	for(player = 0; player < PLAYERS; player++){
		num_alive[player] = 0;
		for(ship = 0; ship < num_cruisers[player]; ship++){
			idx := add_obj();
			o := objs[idx];
			o.player = player;
			o.otype = OT_CRUISER;
			o.squadron = -1;
			o.member = ship;
			o.flags = OF_SHIP | OF_ACTIVE;
			o.x = 0.8*real(w)*(rnreal()-0.5) + real(w)/2.0;
			o.y = 0.8*real(h)*(rnreal()-0.5) + real(h)/2.0;
			o.theta = 2.0*Math->Pi*(rnreal()-0.5);
			o.speed = 35.0; o.turn_rate = 2.5;
			o.life = 100.0; o.fuel = 100000.0; o.maxfuel = 100000.0;
			o.burn = 100.0;
			o.ship_guns = 10000.0; o.ship_range = 30.0;
			o.air_guns = 5000.0; o.air_range = 30.0;
			o.torps = 0; o.maxtorps = 0; o.torp_range = 0.0;
			o.host_idx = -1;
			o.death_time = 0.0;
			o.fire = array[FIREB/8] of { * => byte 0 };
			objs[idx] = o;
			num_alive[player]++;
		}
		for(ship = 0; ship < num_carriers[player]; ship++){
			cidx := add_obj();
			c := objs[cidx];
			c.player = player;
			c.otype = OT_CARRIER;
			c.squadron = -1;
			c.member = ship;
			c.flags = OF_SHIP | OF_ACTIVE;
			c.x = 0.8*real(w)*(rnreal()-0.5) + real(w)/2.0;
			c.y = 0.8*real(h)*(rnreal()-0.5) + real(h)/2.0;
			c.theta = 2.0*Math->Pi*(rnreal()-0.5);
			c.speed = 28.0; c.turn_rate = 1.0;
			c.life = 100.0; c.fuel = 750000.0; c.maxfuel = 750000.0;
			c.burn = 500.0;
			c.ship_guns = 2000.0; c.ship_range = 30.0;
			c.air_guns = 5000.0; c.air_range = 20.0;
			c.torps = 0; c.maxtorps = 0; c.torp_range = 0.0;
			c.host_idx = -1;
			c.death_time = 0.0;
			c.fire = array[FIREB/8] of { * => byte 0 };
			objs[cidx] = c;
			num_alive[player]++;

			for(squadron = 0; squadron < sq_per_carrier[player]; squadron++){
				si := nsq++;
				s := sq[si];
				s.action = SA_PARKED;
				s.player = player;
				s.host_idx = cidx;
				s.heading = c.theta;
				s.dead_mask = 0;
				s.total_mask = (1 << planes_per_sq[player]) - 1;
				sq[si] = s;
				for(fighter = 0; fighter < planes_per_sq[player]; fighter++){
					idx := add_obj();
					o := objs[idx];
					o.player = player;
					o.otype = OT_FIGHTER;
					o.squadron = si;
					o.member = fighter;
					o.flags = 0;	# original fighters: not OF_SHIP
					o.x = c.x; o.y = c.y;
					o.theta = c.theta;
					o.speed = 300.0; o.turn_rate = 25.0;
					o.life = 100.0; o.fuel = 1000.0; o.maxfuel = 1000.0;
					o.burn = 1.0;
					o.air_guns = 35000.0; o.air_range = 8.0;
					o.ship_guns = 0.0; o.ship_range = 0.0;
					o.torps = 1; o.maxtorps = 1; o.torp_range = 20.0;
					o.host_idx = cidx;
					o.death_time = 0.0;
					o.fire = nil;
					objs[idx] = o;
					num_alive[player]++;
				}
			}
		}
	}
}

add_obj(): int
{
	i: int;
	for(i = 0; i < MAX_OBJ; i++)
		if(!objs[i].used){
			objs[i].used = 1;
			objs[i].dtheta = 0.0;
			objs[i].shooting = 0;
			objs[i].next_act = 0.0;
			return i;
		}
	return -1;
}

handleptr(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil)
		return;
	mx = p.xy.x - img.r.min.x;
	my = p.xy.y - img.r.min.y;
	lb := (p.buttons & 1) != 0;
	rb := (p.buttons & 2) != 0;
	if(help_on){
		if((lb && !ptr_lb) || (rb && !ptr_rb))
			help_on = 0;
		ptr_lb = lb;
		ptr_rb = rb;
		return;
	}
	if(lb && !ptr_lb)
		squadron_sethdg(0, real mx, real my, NOHDG);
	if(rb && !ptr_rb){
		nowms := sys->millisec();
		if(nowms - last_rb_t < 400 &&
		   (mx-last_rb_x)*(mx-last_rb_x) + (my-last_rb_y)*(my-last_rb_y) < 400)
			squadron_return(0, real mx, real my);
		else
			squadron_launch(0, real mx, real my);
		last_rb_t = nowms;
		last_rb_x = mx;
		last_rb_y = my;
	}
	ptr_lb = lb;
	ptr_rb = rb;
}

# ObjFind: nearest obj with (flags & fmask) == fval, matching type/player masks
obj_find(x, y: real, fmask, fval, typemask, playermask: int): int
{
	best := -1;
	bestd := 1e30;
	for(i := 0; i < MAX_OBJ; i++){
		o := objs[i];
		if(!o.used)
			continue;
		if((o.flags & fmask) != fval)
			continue;
		if(typemask >= 0 && ((1 << o.otype) & typemask) == 0)
			continue;
		if(playermask >= 0 && ((1 << o.player) & playermask) == 0)
			continue;
		dx := o.x - x;
		dy := o.y - y;
		d := dx*dx + dy*dy;
		if(d < bestd){
			bestd = d;
			best = i;
		}
	}
	return best;
}

obj_launch(player: int, squadron: int, host_idx: int, x: real, y: real, hdg: real): int
{
	ts := now();
	# original ObjLaunch: host defaults to the nearest active carrier of
	# this player (ObjFind's default mask: active, not returning)
	if(host_idx < 0)
		host_idx = obj_find(x, y, OF_ACTIVE|OF_RETURN, OF_ACTIVE,
			1<<OT_CARRIER, 1<<player);
	if(host_idx < 0)
		return -1;
	host := objs[host_idx];
	if(!host.used || !(host.flags & OF_ACTIVE) || ts <= host.next_act)
		return -1;
	if(hdg > 9e8)
		hdg = math->atan2(y - host.y, x - host.x);
	for(i := 0; i < MAX_OBJ; i++){
		o := objs[i];
		if(!o.used || o.host_idx != host_idx)
			continue;
		if(squadron >= 0 && o.squadron != squadron)
			continue;
		if(o.flags & OF_ACTIVE)
			continue;
		if(o.squadron >= 0){
			s := sq[o.squadron];
			if(s.action != SA_PARKED && s.action != SA_LAUNCH)
				continue;
		}
		if(o.fuel <= 0.0){
			# low on fuel: would get launched and captured
			if(o.squadron >= 0)
				sq[o.squadron].dead_mask |= 1 << o.member;
			continue;
		}
		o.flags = (o.flags & ~OF_RETURN) | OF_ACTIVE;
		o.theta = host.theta;
		if(x > 9e8 || y > 9e8 || (x-host.x)*(x-host.x)+(y-host.y)*(y-host.y) > 9.0)
			o.dtheta = wrap(hdg - o.theta, Math->Pi);
		else
			o.dtheta = 0.0;
		o.x = host.x;
		o.y = host.y;
		host.next_act = ts + 0.25/game_speed;
		objs[host_idx] = host;
		objs[i] = o;
		return i;
	}
	return -1;
}

squadron_launch(player: int, x: real, y: real)
{
	idx := obj_launch(player, -1, -1, x, y, NOHDG);
	if(idx < 0)
		return;
	o := objs[idx];
	if(player == 0){
		launch_x1 = o.x; launch_y1 = o.y;
		launch_x2 = real mx; launch_y2 = real my;
		launch_t = now() + 0.5;
	}
	if(o.squadron >= 0){
		s := sq[o.squadron];
		if(s.action == SA_PARKED){
			s.action = SA_LAUNCH;
			s.heading = o.theta + o.dtheta;
			sq[o.squadron] = s;
		}
	}
}

obj_return(player: int, x: real, y: real): int
{
	idx := obj_find(x, y, OF_ACTIVE, OF_ACTIVE, 1<<OT_FIGHTER, 1<<player);
	if(idx < 0)
		return -1;
	o := objs[idx];
	o.flags |= OF_RETURN;
	objs[idx] = o;
	return idx;
}

squadron_return(player: int, x: real, y: real)
{
	idx := obj_return(player, x, y);
	if(idx < 0)
		return;
	o := objs[idx];
	if(player == 0 && o.host_idx >= 0){
		h := objs[o.host_idx];
		return_x1 = o.x; return_y1 = o.y;
		return_x2 = h.x; return_y2 = h.y;
		return_t = now() + 0.5;
	}
	if(o.squadron >= 0){
		s := sq[o.squadron];
		if(s.action == SA_FLYING)
			s.action = SA_RETURN;
		sq[o.squadron] = s;
	}
}

obj_sethdg(player: int, x: real, y: real, hdg: real): int
{
	# original ObjFind default mask: active and not returning
	idx := obj_find(x, y, OF_ACTIVE|OF_RETURN, OF_ACTIVE, -1, 1<<player);
	if(idx < 0)
		return -1;
	o := objs[idx];
	if(hdg > 9e8)
		hdg = math->atan2(y - o.y, x - o.x);
	o.dtheta += wrap(hdg - (o.theta + o.dtheta), Math->Pi);
	objs[idx] = o;
	return idx;
}

squadron_sethdg(player: int, x: real, y: real, hdg: real)
{
	idx := obj_sethdg(player, x, y, hdg);
	if(idx < 0)
		return;
	o := objs[idx];
	if(player == 0){
		sethdg_x1 = o.x; sethdg_y1 = o.y;
		sethdg_x2 = real mx; sethdg_y2 = real my;
		sethdg_t = now() + 0.5;
	}
	if(o.squadron >= 0){
		s := sq[o.squadron];
		if(s.action == SA_FLYING){
			s.action = SA_SETHDG;
			s.heading = o.theta + o.dtheta;
			sq[o.squadron] = s;
		}
	}
}

squadron_actions()
{
	si, i, comp: int;
	for(si = 0; si < nsq; si++){
		s := sq[si];
		if(s.action == SA_DEAD)
			continue;
		comp = 0;
		case s.action {
		SA_LAUNCH =>
			obj_launch(s.player, si, s.host_idx, NOPOS, NOPOS, s.heading);
			for(i = 0; i < MAX_OBJ; i++){
				o := objs[i];
				if(!o.used || o.squadron != si)
					continue;
				if(o.flags & OF_ACTIVE)
					comp |= 1 << o.member;
			}
			if((comp | s.dead_mask) == s.total_mask)
				s.action = SA_FLYING;
		SA_FLYING =>
			for(i = 0; i < MAX_OBJ; i++){
				o := objs[i];
				if(!o.used || o.squadron != si)
					continue;
				if(!(o.flags & OF_ACTIVE))
					comp |= 1 << o.member;
			}
			if((comp | s.dead_mask) == s.total_mask)
				s.action = SA_PARKED;
		SA_SETHDG =>
			for(i = 0; i < MAX_OBJ; i++){
				o := objs[i];
				if(!o.used || o.squadron != si)
					continue;
				o.dtheta += wrap(s.heading - (o.theta + o.dtheta), Math->Pi);
				objs[i] = o;
			}
			s.action = SA_FLYING;
		SA_RETURN =>
			for(i = 0; i < MAX_OBJ; i++){
				o := objs[i];
				if(!o.used || o.squadron != si)
					continue;
				o.flags |= OF_RETURN;
				if(!(o.flags & OF_ACTIVE))
					comp |= 1 << o.member;
				objs[i] = o;
			}
			if((comp | s.dead_mask) == s.total_mask)
				s.action = SA_PARKED;
		}
		if(s.dead_mask == s.total_mask)
			s.action = SA_DEAD;
		sq[si] = s;
	}
}

sim_step()
{
	# original: period = 0.1*game_speed/ANIMATE_FREQ(=50) at 50Hz;
	# same per-second rate at our 20Hz tick
	period := 0.1 * game_speed / real ANIMFREQ;
	ts := now();
	i, ti: int;
	squadron_actions();

	# movement + fuel burn (original first loop)
	for(i = 0; i < MAX_OBJ; i++){
		o := objs[i];
		if(!o.used || !(o.flags & OF_ACTIVE) || o.fuel <= 0.0)
			continue;
		if(o.dtheta != 0.0){
			d := o.dtheta;
			limit := o.turn_rate * period;
			if(d > limit) d = limit;
			if(d < -limit) d = -limit;
			o.theta += d;
			o.dtheta -= d;
		}
		o.x += o.speed * math->cos(o.theta) * period * o.life / 100.0;
		o.y += o.speed * math->sin(o.theta) * period * o.life / 100.0;
		o.fuel -= o.speed * o.burn * period;
		objs[i] = o;
	}

	# torpedoes
	for(ti = 0; ti < MAX_TORP; ti++){
		t := torps[ti];
		if(!t.used)
			continue;
		if(ts > t.timeout){
			target := objs[t.target_idx];
			if(target.used && rnreal() < 0.333333){
				shipdamage(t.target_idx, 150.0 * rnreal() * rnreal());
				if(rnreal() < 0.333333)
					objs[t.target_idx].fuel *= 0.75*rnreal() + 0.25;
			}
			t.used = 0;
		}else{
			t.x += t.speed * math->cos(t.theta) * period;
			t.y += t.speed * math->sin(t.theta) * period;
		}
		torps[ti] = t;
	}

	# parked planes ride their carrier
	for(i = 0; i < MAX_OBJ; i++){
		o1 := objs[i];
		if(!o1.used || o1.host_idx < 0 || (o1.flags & OF_ACTIVE))
			continue;
		h := objs[o1.host_idx];
		o1.x = h.x; o1.y = h.y;
		objs[i] = o1;
	}

	# refuel/rearm, auto-return, carrier self-repair
	for(i = 0; i < MAX_OBJ; i++){
		o := objs[i];
		if(!o.used || !(o.flags & OF_ACTIVE))
			continue;
		if(o.host_idx >= 0){
			h := objs[o.host_idx];
			dx := o.x - h.x;
			dy := o.y - h.y;
			d := math->sqrt(dx*dx + dy*dy);
			if(d < 8.0 && o.maxfuel - o.fuel > 30.0){
				o.life = 100.0;
				if(h.fuel > 0.0){
					need := o.maxfuel - o.fuel;
					if(need > h.fuel)
						need = h.fuel;
					h.fuel -= need;
					o.fuel += need;
					objs[o.host_idx] = h;
				}
				o.torps = o.maxtorps;
				o.x = h.x; o.y = h.y;
				o.flags &= ~OF_ACTIVE;
			}else if(d > o.fuel - 250.0)
				o.flags |= OF_RETURN;
			if(o.flags & OF_RETURN)
				o.dtheta += wrap(math->atan2(h.y - o.y, h.x - o.x) - (o.theta + o.dtheta), Math->Pi);
		}else if(o.otype == OT_CARRIER)
			shipfixv(i, 2.5 * period);
		objs[i] = o;
	}

	ai_step(1, period);
	combat(period);

	for(i = 0; i < MAX_OBJ; i++){
		o := objs[i];
		if(!o.used)
			continue;
		if(o.otype == OT_FIGHTER &&
		   (o.life <= 0.0 || (o.flags & OF_ACTIVE) && o.fuel <= 0.0 ||
		    o.host_idx >= 0 && !(o.flags & OF_ACTIVE) && objs[o.host_idx].life <= 0.0))
			del_obj(i);
	}
	for(i = 0; i < MAX_OBJ; i++){
		o := objs[i];
		if(o.used && o.life <= 0.0)
			del_obj(i);
	}
}

del_obj(i: int)
{
	o := objs[i];
	if(now() < o.death_time){
		# torpedo still in flight: deactivate, keep until it resolves
		o.flags &= ~OF_ACTIVE;
		objs[i] = o;
		return;
	}
	if(o.squadron >= 0)
		sq[o.squadron].dead_mask |= 1 << o.member;
	num_alive[o.player]--;
	o.used = 0;
	objs[i] = o;
}

# --- fire bitmap (ShipDamage/ShipFix) ---

fbts(f: array of byte, i: int): int
{
	old := int((f[i>>3] >> (i&7)) & byte 1);
	f[i>>3] |= byte(1 << (i&7));
	return old;
}

fbtr(f: array of byte, i: int): int
{
	old := int((f[i>>3] >> (i&7)) & byte 1);
	f[i>>3] &= ~byte(1 << (i&7));
	return old;
}

fbt(f: array of byte, i: int): int
{
	return int((f[i>>3] >> (i&7)) & byte 1);
}

shipdamage(idx: int, d: real)
{
	o := objs[idx];
	o.life -= d;
	objs[idx] = o;
	f := o.fire;
	if(f == nil)
		return;
	x := rn(FIREW);
	y := rn(FIREH);
	while(d > 0.0){
		if(!fbts(f, y*FIREW + x))
			d -= 500.0 / real FIREB;
		else
			d -= 25.0 / real FIREB;
		k := rn(8);
		x += grxoff[k];
		y += gryoff[k];
		while(x >= FIREW)
			x -= FIREW;
		while(x < 0)
			x += FIREW;
		while(y >= FIREH)
			y -= FIREH;
		while(y < 0)
			y += FIREH;
	}
}

shipfixv(idx: int, d: real)
{
	o := objs[idx];
	o.life += d;
	if(o.life >= 100.0){
		o.life = 100.0;
		if(o.fire != nil)
			for(i := 0; i < FIREB/8; i++)
				o.fire[i] = byte 0;
		objs[idx] = o;
		return;
	}
	objs[idx] = o;
	f := o.fire;
	if(f == nil)
		return;
	while(d > 0.0)
		if(fbtr(f, rn(FIREB)))
			d -= 400.0 / real FIREB;
		else
			d -= 20.0 / real FIREB;
}

combat(period: real)
{
	ts := now();
	i: int;
	for(i = 0; i < MAX_OBJ; i++){
		if(!objs[i].used)
			continue;
		objs[i].shooting = 0;
		o := objs[i];
		if(!(o.flags & OF_ACTIVE))
			continue;
		# original targets ANY active enemy (fighters included)
		tidx := obj_find(o.x, o.y, OF_ACTIVE, OF_ACTIVE, -1, 1 << (o.player ^ 1));
		if(tidx < 0)
			continue;
		t := objs[tidx];
		dx := t.x - o.x;
		dy := t.y - o.y;
		d := math->sqrt(dx*dx + dy*dy);
		o.target_x = t.x;
		o.target_y = t.y;
		if(t.flags & OF_SHIP){
			if(o.torps > 0 && d < o.torp_range && rnreal() < 125.0*period){
				o.torps--;
				add_torp(o.x, o.y, d, tidx, math->atan2(dy, dx));
				sweep(2000, 86.0, 53.0);
			}else if(o.ship_guns > 0.0 && d < o.ship_range){
				o.shooting = 1;
				if(rnreal() < 125.0*period){
					shipdamage(tidx, o.ship_guns * rnreal() * period);
					if(rnreal() < 10.0*period)
						objs[tidx].fuel *= 0.75*rnreal() + 0.25;
				}
				if(ts > next_noise){
					noise(100, 29.0, 46.0);
					next_noise = ts + 0.1;
				}
			}
		}else if(o.air_guns > 0.0 && d < o.air_range){
			o.shooting = 1;
			if(rnreal() < 125.0*period){
				objs[tidx].life -= o.air_guns * rnreal() * period;
				if(rnreal() < 10.0*period)
					objs[tidx].fuel *= 0.75*rnreal() + 0.25;
			}
			if(ts > next_noise){
				noise(25, 62.0, 86.0);
				next_noise = ts + 0.025;
			}
		}
		objs[i] = o;
	}
}

add_torp(x: real, y: real, dist: real, target_idx: int, th: real)
{
	i: int;
	for(i = 0; i < MAX_TORP; i++){
		if(torps[i].used)
			continue;
		t := torps[i];
		t.used = 1;
		t.x = x; t.y = y; t.theta = th; t.speed = 100.0;
		t.timeout = now() + dist/(100.0*0.1*game_speed);
		t.target_idx = target_idx;
		objs[target_idx].death_time = t.timeout;
		torps[i] = t;
		return;
	}
}

ai_step(player: int, period: real)
{
	i: int;
	for(i = 0; i < MAX_OBJ; i++){
		o := objs[i];
		if(!o.used || o.player != player)
			continue;
		if(o.otype == OT_CARRIER && rnreal() < 5.0*period)
			squadron_launch(player, o.x, o.y);
		if((o.flags & OF_ACTIVE) && !(o.flags & OF_RETURN) &&
		   rnreal() < 10.0*period)
			squadron_sethdg(player, o.x, o.y, o.theta + Math->Pi/2.0*(rnreal()-0.5));
	}
}

# --- sound: Noise()/Sweep() over the tone device ---

ona2freq(ona: real): int
{
	# Kernel/KMisc.HC Ona2Freq: 440.0/32*2^(ona/12), i.e. ona 60 is 440Hz
	if(ona <= 0.0)
		return 0;
	return int(440.0/32.0 * math->pow(2.0, ona/12.0));
}

noise(ms: int, lo, hi: real)
{
	if(!have_tone)
		return;
	sndgen++;
	spawn noisetask(now() + real ms/1000.0, lo, hi, sndgen);
}

noisetask(deadline: real, lo, hi: real, gen: int)
{
	while(now() < deadline && gen == sndgen){
		f := ona2freq(lo + rnreal()*(hi-lo));
		if(f <= 0)
			f = 1;
		tone->snd(f);
		st := 3000.0 / real f;
		if(st < 1.0) st = 1.0;
		if(st > 50.0) st = 50.0;
		sys->sleep(int st);
	}
	if(gen == sndgen)
		tone->stop();
}

sweep(ms: int, ona1, ona2: real)
{
	if(!have_tone)
		return;
	sndgen++;
	spawn sweeptask(real ms/1000.0, ona1, ona2, sndgen);
}

sweeptask(dur: real, ona1, ona2: real, gen: int)
{
	t0 := now();
	while(gen == sndgen){
		t := (now() - t0) / dur;
		if(t >= 1.0)
			break;
		f := ona2freq((1.0-t)*ona1 + t*ona2);
		if(f <= 0)
			f = 1;
		tone->snd(f);
		st := 3000.0 / real f;
		if(st < 1.0) st = 1.0;
		if(st > 50.0) st = 50.0;
		sys->sleep(int st);
	}
	if(gen == sndgen)
		tone->stop();
}

# --- drawing ---

blink(): int
{
	# TempleOS Blink(2.5Hz): ToI64(tS*2*2.5)&1
	return int(now() * 5.0) & 1;
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

	# original play field: text_attr BLUE<<4 (blue background)
	img.draw(img.r, ink[1], nil, Point(0, 0));

	if(help_on){
		draw_help(img, o, w, h);
		img.flush(Draw->Flushnow);
		return;
	}

	bl := blink();

	# torpedoes: single white GrPlot pixel
	for(i = 0; i < MAX_TORP; i++){
		t := torps[i];
		if(!t.used)
			continue;
		plot(img, o.x + int t.x, o.y + int t.y, ink[15]);
	}

	for(i = 0; i < MAX_OBJ; i++){
		o1 := objs[i];
		if(!o1.used || !(o1.flags & OF_ACTIVE) || !(o1.flags & OF_SHIP))
			continue;
		draw_ship(img, o, o1, ts, bl);
	}
	for(i = 0; i < MAX_OBJ; i++){
		o1 := objs[i];
		if(!o1.used)
			continue;
		if((o1.flags & OF_ACTIVE) && !(o1.flags & OF_SHIP))
			draw_sprite(img, o, o1);
		if(o1.shooting)
			dotline(img, o.x+int o1.x, o.y+int o1.y,
				o.x+int o1.target_x, o.y+int o1.target_y, 3, ink[12]);
	}

	if(ts < launch_t)
		draw_arrow(img, o, launch_x1, launch_y1, launch_x2, launch_y2, ink[10]);
	if(ts < return_t)
		draw_arrow(img, o, return_x1, return_y1, return_x2, return_y2, ink[12]);
	if(ts < sethdg_t)
		draw_arrow(img, o, sethdg_x1, sethdg_y1, sethdg_x2, sethdg_y2, ink[14]);

	if(font != nil){
		img.text(Point(o.x, o.y), ink[14], Point(0, 0), font,
			sys->sprint("Game Speed: %5.2f", game_speed));
		img.text(Point(o.x, o.y+fonth), ink[11], Point(0, 0), font,
			sys->sprint("Player 1: %d", num_alive[0]));
		img.text(Point(o.x, o.y+2*fonth), ink[13], Point(0, 0), font,
			sys->sprint("Player 2: %d", num_alive[1]));
		if((num_alive[0] == 0 || num_alive[1] == 0) && bl){
			if(num_alive[1] == 0)
				img.text(Point(o.x + w/2 - 14*8/2, o.y + h/2 - fonth/2),
					ink[10], Point(0, 0), font, "Game Completed");
			else
				img.text(Point(o.x + w/2 - 9*8/2, o.y + h/2 - fonth/2),
					ink[12], Point(0, 0), font, "Game Over");
		}
	}
	img.flush(Draw->Flushnow);
}

plot(img: ref Image, x, y: int, col: ref Image)
{
	img.draw(Rect((x, y), (x+1, y+1)), col, nil, Point(0, 0));
}

# GrLine(...,step): plot every step-th pixel (dotted line)
dotline(img: ref Image, x1, y1, x2, y2, step: int, col: ref Image)
{
	dx := x2 - x1;
	dy := y2 - y1;
	adx := dx; if(adx < 0) adx = -adx;
	ady := dy; if(ady < 0) ady = -ady;
	n := adx;
	if(ady > n)
		n = ady;
	if(n == 0){
		plot(img, x1, y1, col);
		return;
	}
	for(i := 0; i <= n; i += step)
		plot(img, x1 + dx*i/n, y1 + dy*i/n, col);
}

draw_sprite(img: ref Image, o: Point, o1: Obj)
{
	sp: ref Spr;
	if(o1.player >= 0 && o1.player < PLAYERS && o1.otype >= 0 && o1.otype < 3)
		sp = sprs[o1.player][o1.otype];
	p := Point(o.x + int o1.x, o.y + int o1.y);
	if(sp != nil){
		k := sprvariant(o1.theta);
		v := sp.rot[k];
		img.draw(v.r.addpt(p), v, sp.rotm[k], v.r.min);
		return;
	}
	# fallback if sprite art failed to load
	size := 6;
	if(o1.flags & OF_SHIP){
		if(o1.otype == OT_CARRIER)
			size = 14;
		else
			size = 10;
	}
	body := ink[11];
	if(o1.player != 0)
		body = ink[13];
	draw_triangle(img, o, o1.x, o1.y, o1.theta, size, body, ink[15]);
}

draw_ship(img: ref Image, o: Point, ship: Obj, ts: real, bl: int)
{
	draw_sprite(img, o, ship);

	# burning-ship fire bitmap, jittered and rotated with the heading
	if(ship.fire != nil){
		ct := math->cos(ship.theta);
		st := math->sin(ship.theta);
		for(k := 0; k < FIREB; k++){
			if(!fbt(ship.fire, k))
				continue;
			fi := real(k % FIREW);
			fj := real(k / FIREW);
			ci := int(real(k+1) + 10.0*ts) & 15;
			ex := fi - real FIREW/2.0;
			ey := fj - real FIREH/2.0;
			px := ship.x + FIREXSC*(ex + math->fmod(11.0*ts+fi, 1.7))*ct -
				FIREYSC*(ey + math->fmod(12.0*ts+fj, 1.7))*st;
			py := ship.y + FIREYSC*(ey + math->fmod(19.0*ts+fj, 1.7))*ct +
				FIREXSC*(ex + math->fmod(13.0*ts+fi, 1.7))*st;
			plot(img, o.x + int px, o.y + int py, ink[fire_colors[ci]]);
		}
	}

	# health/fuel bars flash with Blink, as in the original
	if(bl){
		bx := int ship.x + 5;
		by := int ship.y;
		img.line(Point(o.x+bx, o.y+by), Point(o.x+bx+10, o.y+by), 0, 0, 1, ink[0], Point(0, 0));
		life := int ship.life;
		col: ref Image;
		if(life > 0){
			if(life < 33)
				col = ink[4];
			else if(life < 66)
				col = ink[14];
			else
				col = ink[2];
			img.line(Point(o.x+bx, o.y+by), Point(o.x+bx+life/10, o.y+by), 0, 0, 1, col, Point(0, 0));
		}
		img.line(Point(o.x+bx, o.y+by+2), Point(o.x+bx+10, o.y+by+2), 0, 0, 1, ink[0], Point(0, 0));
		fpct := int(ship.fuel * 100.0 / ship.maxfuel);
		if(fpct > 0){
			if(fpct < 33)
				col = ink[4];
			else if(fpct < 66)
				col = ink[14];
			else
				col = ink[2];
			img.line(Point(o.x+bx, o.y+by+2), Point(o.x+bx+fpct/10, o.y+by+2), 0, 0, 1, col, Point(0, 0));
		}
	}
}

draw_triangle(img: ref Image, o: Point, x: real, y: real, th: real, size: int, fill: ref Image, edge: ref Image)
{
	rs := real size;
	cx := int x;
	cy := int y;
	fx := cx + int(rs * math->cos(th));
	fy := cy + int(rs * math->sin(th));
	lx := cx + int(rs * 0.6 * math->cos(th + 2.4));
	ly := cy + int(rs * 0.6 * math->sin(th + 2.4));
	rx := cx + int(rs * 0.6 * math->cos(th - 2.4));
	ry := cy + int(rs * 0.6 * math->sin(th - 2.4));
	img.line(Point(o.x+fx, o.y+fy), Point(o.x+lx, o.y+ly), 0, 0, 1, edge, Point(0, 0));
	img.line(Point(o.x+lx, o.y+ly), Point(o.x+rx, o.y+ry), 0, 0, 1, edge, Point(0, 0));
	img.line(Point(o.x+rx, o.y+ry), Point(o.x+fx, o.y+fy), 0, 0, 1, edge, Point(0, 0));
	img.ellipse(Point(o.x+cx, o.y+cy), size/2, size/2, 0, fill, Point(0, 0));
}

draw_arrow(img: ref Image, o: Point, x1: real, y1: real, x2: real, y2: real, col: ref Image)
{
	img.line(Point(o.x+int x1, o.y+int y1), Point(o.x+int x2, o.y+int y2),
		Draw->Endarrow, Draw->Endarrow, 1, col, Point(0, 0));
}

# startup PopUpOk listing the mouse controls
draw_help(img: ref Image, o: Point, w, h: int)
{
	keys := array[] of {
		"{Left-Mouse}", "{Right-Mouse}", "{Right-Double-Mouse}"
	};
	descs := array[] of {
		"Change Course", "Launch Squadron", "Return Squadron"
	};
	pad := 12;
	kw := 0;
	dw := 0;
	for(i := 0; i < len keys; i++){
		if(8*len keys[i] > kw)
			kw = 8*len keys[i];
		if(8*len descs[i] > dw)
			dw = 8*len descs[i];
	}
	bw := pad + kw + 16 + dw + pad;
	bh := pad + (len keys)*(fonth+4) + 8 + fonth + 8 + pad;
	bx := o.x + (w - bw)/2;
	by := o.y + (h - bh)/2;
	img.draw(Rect((bx-2, by-2), (bx+bw+2, by+bh+2)), ink[0], nil, Point(0, 0));
	img.draw(Rect((bx, by), (bx+bw, by+bh)), ink[15], nil, Point(0, 0));
	if(font == nil)
		return;
	y := by + pad;
	for(i = 0; i < len keys; i++){
		img.text(Point(bx+pad, y), ink[2], Point(0, 0), font, keys[i]);
		img.text(Point(bx+pad+kw+16, y), ink[0], Point(0, 0), font, descs[i]);
		y += fonth + 4;
	}
	okx := bx + bw/2 - 2*8;
	oky := y + 8;
	img.draw(Rect((okx-4, oky-3), (okx+4*8-4, oky+fonth+3)), ink[7], nil, Point(0, 0));
	img.text(Point(okx, oky), ink[0], Point(0, 0), font, " OK ");
}

wrap(a, lim: real): real
{
	while(a > lim)
		a -= 2.0*Math->Pi;
	while(a < -lim)
		a += 2.0*Math->Pi;
	return a;
}

now(): real
{
	return real sys->millisec() / 1000.0;
}

rn(n: int): int
{
	if(n <= 0)
		return 0;
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

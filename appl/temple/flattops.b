implement Flattops;

# TempleOS Demo/Games/FlatTops.HC — carrier task-force RTS
# GAP: no Sprite3ZB ship sprites / fire bitmap damage — triangles + health bars
# GAP: no GrPrint HUD — font strings; squadron AI simplified; P2 auto-AI only
# GAP: no MSG scroll / WinInhibit mouse routing — wmclient ptr coords
# GAP: RMB double-click return — detect 400ms double-tap on fighter

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

Obj: adt {
	used: int;
	player, otype, squadron, member: int;
	flags: int;
	x, y, theta, dtheta: real;
	speed, turn_rate: real;
	life, fuel, maxfuel: real;
	ship_guns, ship_range, air_guns, air_range: real;
	torps, maxtorps: int;
	torp_range: real;
	host_idx: int;
	target_x, target_y: real;
	shooting: int;
	next_act: real;
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

win: ref Window;
font: ref Font;
ink: array of ref Image;
have_tone := 0;

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
blink_on: int;

mx, my: int;
last_rb_t: int;
last_rb_x, last_rb_y: int;
ptr_lb, ptr_rb: int;

num_carriers: array of int = array[PLAYERS] of { 2, 3 };
num_cruisers: array of int = array[PLAYERS] of { 2, 3 };
planes_per_sq: array of int = array[PLAYERS] of { 6, 5 };
sq_per_carrier: array of int = array[PLAYERS] of { 2, 3 };

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

	objs = array[MAX_OBJ] of Obj;
	torps = array[MAX_TORP] of Torpedo;
	sq = array[32] of Squadron;

	win.reshape(Rect((0, 0), (800, 600)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	game_init();

	ticks := chan of int;
	spawn timer(ticks, 50);
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
		'+' or '=' =>
			game_speed *= 1.5;
		'-' or '_' =>
			{
				game_speed /= 1.5;
				if(game_speed < 0.1)
					game_speed = 0.1;
			}
		}
	<-ticks =>
		sim_step();
		redraw();
	}
}

game_init()
{
	i, j, player, ship, squadron, fighter: int;
	w := 800; h := 600;
	img := win.image;
	o: Obj;
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
			o.flags = OF_SHIP | OF_ACTIVE;
			o.x = 0.8*real(w)*(rnreal()-0.5) + real(w)/2.0;
			o.y = 0.8*real(h)*(rnreal()-0.5) + real(h)/2.0;
			o.theta = 2.0*Math->Pi*(rnreal()-0.5);
			o.speed = 35.0; o.turn_rate = 2.5;
			o.life = 100.0; o.fuel = 100000.0; o.maxfuel = 100000.0;
			o.ship_guns = 10000.0; o.ship_range = 30.0;
			o.air_guns = 5000.0; o.air_range = 30.0;
			o.torps = 0; o.maxtorps = 0; o.torp_range = 0.0;
			o.host_idx = -1;
			objs[idx] = o;
			num_alive[player]++;
		}
		for(ship = 0; ship < num_carriers[player]; ship++){
			cidx := add_obj();
			c := objs[cidx];
			c.player = player;
			c.otype = OT_CARRIER;
			c.squadron = -1;
			c.flags = OF_SHIP | OF_ACTIVE;
			c.x = 0.8*real(w)*(rnreal()-0.5) + real(w)/2.0;
			c.y = 0.8*real(h)*(rnreal()-0.5) + real(h)/2.0;
			c.theta = 2.0*Math->Pi*(rnreal()-0.5);
			c.speed = 28.0; c.turn_rate = 1.0;
			c.life = 100.0; c.fuel = 750000.0; c.maxfuel = 750000.0;
			c.ship_guns = 2000.0; c.ship_range = 30.0;
			c.air_guns = 5000.0; c.air_range = 20.0;
			c.torps = 0; c.maxtorps = 0; c.torp_range = 0.0;
			c.host_idx = -1;
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
					o = objs[idx];
					o.player = player;
					o.otype = OT_FIGHTER;
					o.squadron = si;
					o.member = fighter;
					o.flags = OF_SHIP;
					o.x = c.x; o.y = c.y;
					o.theta = c.theta;
					o.speed = 300.0; o.turn_rate = 25.0;
					o.life = 100.0; o.fuel = 1000.0; o.maxfuel = 1000.0;
					o.air_guns = 35000.0; o.air_range = 8.0;
					o.ship_guns = 0.0; o.ship_range = 0.0;
					o.torps = 1; o.maxtorps = 1; o.torp_range = 20.0;
					o.host_idx = cidx;
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
	if(lb && !ptr_lb)
		squadron_sethdg(0, real mx, real my, -1.0);
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

obj_find(x, y: real, need_active, need_ship, typemask, playermask: int): int
{
	best := -1;
	bestd := 1e30;
	for(i := 0; i < MAX_OBJ; i++){
		o := objs[i];
		if(!o.used)
			continue;
		if(need_active && !(o.flags & OF_ACTIVE))
			continue;
		if(need_ship && !(o.flags & OF_SHIP))
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
	if(host_idx < 0)
		return -1;
	host := objs[host_idx];
	if(!(host.flags & OF_ACTIVE) || ts <= host.next_act)
		return -1;
	if(hdg < 0.0)
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
			if(o.squadron >= 0)
				sq[o.squadron].dead_mask |= 1 << o.member;
			continue;
		}
		o.flags = (o.flags & ~OF_RETURN) | OF_ACTIVE;
		o.theta = host.theta;
		if(x < 0.0 || y < 0.0 || (x-host.x)*(x-host.x)+(y-host.y)*(y-host.y) > 9.0)
			o.dtheta = wrap(hdg - o.theta, -Math->Pi);
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
	idx := obj_launch(player, -1, obj_find(x, y, 0, 1, 1<<OT_CARRIER, 1<<player), x, y, -1.0);
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
	idx := obj_find(x, y, 1, 0, 1<<OT_FIGHTER, 1<<player);
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
	idx := obj_find(x, y, 1, 0, -1, 1<<player);
	if(idx < 0)
		return -1;
	o := objs[idx];
	if(o.flags & OF_RETURN)
		return -1;
	if(hdg < 0.0)
		hdg = math->atan2(y - o.y, x - o.x);
	o.dtheta += wrap(hdg - (o.theta + o.dtheta), -Math->Pi);
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
			obj_launch(s.player, si, s.host_idx, -1.0, -1.0, s.heading);
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
				o.dtheta += wrap(s.heading - (o.theta + o.dtheta), -Math->Pi);
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
	period := 0.1 * game_speed;
	ts := now();
	i, ti, tidx: int;
	squadron_actions();

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
		o.fuel -= o.speed * period * 0.01;
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
				o.flags &= ~OF_RETURN;
			}else if(d > o.fuel - 250.0)
				o.flags |= OF_RETURN;
			if(o.flags & OF_RETURN)
				o.dtheta += wrap(math->atan2(h.y - o.y, h.x - o.x) - (o.theta + o.dtheta), -Math->Pi);
		}else if(o.otype == OT_CARRIER){
			o.life += 2.5 * period;
			if(o.life > 100.0)
				o.life = 100.0;
		}
		objs[i] = o;
	}

	for(i = 0; i < MAX_OBJ; i++){
		o1 := objs[i];
		if(!o1.used || o1.host_idx < 0 || (o1.flags & OF_ACTIVE))
			continue;
		h := objs[o1.host_idx];
		o1.x = h.x; o1.y = h.y;
		objs[i] = o1;
	}

	# torpedoes
	for(ti = 0; ti < MAX_TORP; ti++){
		t := torps[ti];
		if(!t.used)
			continue;
		if(ts > t.timeout){
			target := objs[t.target_idx];
			if(target.used && rn(3) == 0){
				target.life -= 150.0 * rnreal() * rnreal();
				if(rn(3) == 0)
					target.fuel *= 0.75*rnreal() + 0.25;
				objs[t.target_idx] = target;
			}
			t.used = 0;
		}else{
			t.x += t.speed * math->cos(t.theta) * period;
			t.y += t.speed * math->sin(t.theta) * period;
		}
		torps[ti] = t;
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
	blink_on = (sys->millisec()/500) & 1;
}

del_obj(i: int)
{
	o := objs[i];
	if(o.squadron >= 0)
		sq[o.squadron].dead_mask |= 1 << o.member;
	num_alive[o.player]--;
	o.used = 0;
	objs[i] = o;
}

combat(period: real)
{
	ts := now();
	i, tidx: int;
	for(i = 0; i < MAX_OBJ; i++){
		o := objs[i];
		if(!o.used || !(o.flags & OF_ACTIVE))
			continue;
		tidx := obj_find(o.x, o.y, 1, 1, -1, 1 << (o.player ^ 1));
		if(tidx < 0)
			continue;
		t := objs[tidx];
		dx := t.x - o.x;
		dy := t.y - o.y;
		d := math->sqrt(dx*dx + dy*dy);
		o.target_x = t.x;
		o.target_y = t.y;
		o.shooting = 0;
		if(t.flags & OF_SHIP){
			if(o.torps > 0 && d < o.torp_range && rn(1000) < int(125.0*period*1000.0)){
				o.torps--;
				add_torp(o.x, o.y, d, tidx, math->atan2(dy, dx));
				if(have_tone)
					tone->beep(86, 40);
			}else if(o.ship_guns > 0.0 && d < o.ship_range){
				o.shooting = 1;
				if(rn(1000) < int(125.0*period*1000.0)){
					t.life -= o.ship_guns * rnreal() * period;
					if(rn(1000) < int(10.0*period*1000.0))
						t.fuel *= 0.75*rnreal() + 0.25;
					objs[tidx] = t;
				}
				noise(100, 29, 46, ts);
			}
		}else if(o.air_guns > 0.0 && d < o.air_range){
			o.shooting = 1;
			if(rn(1000) < int(125.0*period*1000.0)){
				t.life -= o.air_guns * rnreal() * period;
				if(rn(1000) < int(10.0*period*1000.0))
					t.fuel *= 0.75*rnreal() + 0.25;
				objs[tidx] = t;
			}
			noise(25, 62, 86, ts);
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
		torps[i] = t;
		return;
	}
}

noise(lo: int, hi: int, dur: int, ts: real)
{
	if(!have_tone || ts <= next_noise)
		return;
	tone->beep(lo + rn(hi-lo), dur);
	next_noise = ts + 0.1;
}

ai_step(player: int, period: real)
{
	i: int;
	for(i = 0; i < MAX_OBJ; i++){
		o := objs[i];
		if(!o.used || o.player != player)
			continue;
		if(o.otype == OT_CARRIER && rn(1000) < int(5.0*period*1000.0))
			squadron_launch(player, o.x, o.y);
		if((o.flags & OF_ACTIVE) && !(o.flags & OF_RETURN) &&
		   rn(1000) < int(10.0*period*1000.0))
			obj_sethdg(player, o.x, o.y, o.theta + Math->Pi/2.0*(rnreal()-0.5));
	}
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

	for(i = 0; i < MAX_TORP; i++){
		t := torps[i];
		if(!t.used)
			continue;
		img.draw(Rect((o.x+int t.x, o.y+int t.y), (o.x+int t.x+2, o.y+int t.y+2)),
			ink[15], nil, Point(0, 0));
	}

	for(i = 0; i < MAX_OBJ; i++){
		o1 := objs[i];
		if(!o1.used || !(o1.flags & OF_ACTIVE) || !(o1.flags & OF_SHIP))
			continue;
		draw_ship(img, o, o1);
	}
	for(i = 0; i < MAX_OBJ; i++){
		o1 := objs[i];
		if(!o1.used || !(o1.flags & OF_ACTIVE) || (o1.flags & OF_SHIP))
			continue;
		draw_plane(img, o, o1);
	}
	for(i = 0; i < MAX_OBJ; i++){
		o1 := objs[i];
		if(!o1.used || !o1.shooting)
			continue;
		img.line(Point(o.x+int o1.x, o.y+int o1.y),
			Point(o.x+int o1.target_x, o.y+int o1.target_y),
			0, 0, 1, ink[12], Point(0, 0));
	}

	if(ts < launch_t)
		draw_arrow(img, o, launch_x1, launch_y1, launch_x2, launch_y2, ink[10]);
	if(ts < return_t)
		draw_arrow(img, o, return_x1, return_y1, return_x2, return_y2, ink[12]);
	if(ts < sethdg_t)
		draw_arrow(img, o, sethdg_x1, sethdg_y1, sethdg_x2, sethdg_y2, ink[14]);

	if(font != nil){
		img.text(Point(o.x+4, o.y+4), ink[14], Point(0, 0), font,
			sys->sprint("Speed:%5.2f", game_speed));
		img.text(Point(o.x+4, o.y+16), ink[11], Point(0, 0), font,
			sys->sprint("P1:%d", count_alive(0)));
		img.text(Point(o.x+4, o.y+28), ink[13], Point(0, 0), font,
			sys->sprint("P2:%d", count_alive(1)));
		if((count_alive(0) == 0 || count_alive(1) == 0) && blink_on){
			msg := "Game Over";
			col := ink[12];
			if(count_alive(1) == 0){
				msg = "You Win!";
				col = ink[10];
			}
			img.text(Point(o.x+w/2-40, o.y+h/2), col, Point(0, 0), font, msg);
		}
	}
	img.flush(Draw->Flushnow);
}

count_alive(player: int): int
{
	n := 0;
	i: int;
	for(i = 0; i < MAX_OBJ; i++){
		o := objs[i];
		if(o.used && o.player == player && o.life > 0.0)
			n++;
	}
	return n;
}

draw_ship(img: ref Image, o: Point, ship: Obj)
{
	body := ink[11];
	edge := ink[15];
	size: int;
	col: ref Image;
	if(ship.player != 0){
		body = ink[13];
		edge = ink[10];
	}
	if(ship.otype == OT_CARRIER)
		size = 14;
	else
		size = 10;
	draw_triangle(img, o, ship.x, ship.y, ship.theta, size, body, edge);
	if(ship.flags & OF_SHIP){
		bx := int ship.x + 5;
		by := int ship.y;
		img.line(Point(o.x+bx, o.y+by), Point(o.x+bx+10, o.y+by), 0, 0, 1, ink[0], Point(0, 0));
		life := int ship.life;
		if(life > 66)
			col = ink[2];
		else if(life > 33)
			col = ink[14];
		else
			col = ink[4];
		if(life > 0)
			img.line(Point(o.x+bx, o.y+by), Point(o.x+bx+life/10, o.y+by), 0, 0, 1, col, Point(0, 0));
		fpct := int(ship.fuel * 100.0 / ship.maxfuel);
		img.line(Point(o.x+bx, o.y+by+2), Point(o.x+bx+10, o.y+by+2), 0, 0, 1, ink[0], Point(0, 0));
		if(fpct > 0){
			if(fpct > 66)
				col = ink[2];
			else if(fpct > 33)
				col = ink[14];
			else
				col = ink[4];
			img.line(Point(o.x+bx, o.y+by+2), Point(o.x+bx+fpct/10, o.y+by+2), 0, 0, 1, col, Point(0, 0));
		}
	}
}

draw_plane(img: ref Image, o: Point, plane: Obj)
{
	col := ink[11];
	if(plane.player != 0)
		col = ink[13];
	if(plane.flags & OF_RETURN)
		col = ink[14];
	draw_triangle(img, o, plane.x, plane.y, plane.theta, 6, col, ink[15]);
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

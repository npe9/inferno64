implement Wenceslas;

# TempleOS Demo/Games/Wenceslas.HC — Good King Wenceslas.
#
# Light fires on the trees and lead the peasants to them, or to the house.
#
# The king and the peasants are the original's 3D men (Wenceslas.HC points
# at ::/Apps/GrModels for making them): SPT_MESH bins 1-3 and 4-6, cycled
# as king_imgs {2,1,2,3} and peasant_imgs {5,4,5,6} and vertex-interpolated
# between consecutive frames by SpriteInterpolate.  Sprite3Mat4x4B draws
# them with Mat4x4RotY(theta+pi/2) then Mat4x4RotX(pi/6) and no perspective,
# so this is an orthographic draw3d(2) pass with the z-buffer standing in
# for DCDepthBufAlloc; a scale(1,1,-1) hands draw3d the eye space where a
# smaller sprite z is nearer, as TempleOS has it.  The tree, its two
# burning frames, the house and the open door are bitmap bins 7-11.
#
# The field is WHITE because Wenceslas sets no $$BG$$ and a TempleOS task
# starts at WHITE<<4+BLUE (Kernel/KTask.HC).  That is what makes the rest
# of the palette work: the HUD is LTBLUE, footsteps are DKGRAY for their
# first two seconds and then LTGRAY, which is to say they fade into the
# snow, and the WHITE snow blitted with ROP_MONO shows only where it
# settles on the men, the trees and the house.
#
# Timing: AnimateTask is a Sleep(1) loop, so its constants are per
# millisecond — peasants walk Cos(theta)/100 per step (10 px/s), the
# animation phase advances every 250 steps, and a snow flake is added to
# the 128x128 tile every 8.  This ticks at 30ms and runs 30 of those steps
# per tick, redrawing once, which is the rate the original's window
# manager redraws at anyway.
#
# GAP: MenuPush File/Play menu bar; its entries are all on keys.
# GAP: the original opens with three PopUpOk pages, two of them the whole
#      carol.  Both carol pages are here; PopUpOk's own scrolling is not,
#      so each page is shown in full and any key moves on.

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

include "math/polyfill.m";
include "math/draw3d.m";
	draw3d: Draw3d;
	Vector: import Draw3d;
include "grpalette.m";
	grpal: Grpalette;
include "frameclock.m";
	fclock: Frameclock;

Wenceslas: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# The port's own simulation step, in milliseconds.  The frame clock
# runs at 60fps and this many milliseconds of simulation are run for
# each frame's worth of real time, so the picture is smooth and the
# simulation keeps the speed it was written for.
FCSTEP: con 30;
fcacc := 0;

BORDER: con 5;
KING_STEP: con 6;
TREES_NUM: con 8;
PEASANTS_NUM: con 10;
SNOW_TILE_SIZE: con 128;
MAX_STEPS: con 1024;
MAX_KSTEPS: con 256;
PI: con 3.141592653589793;

FW: con 8;			# TempleOS FONT_WIDTH
FH: con 8;			# TempleOS FONT_HEIGHT

BLACK, BLUE, GREEN, CYAN, RED, PURPLE, BROWN, LTGRAY: con iota;
DKGRAY, LTBLUE, LTGREEN, LTCYAN, LTRED, LTPURPLE, YELLOW, WHITE: con iota + 8;

Tri: adt { col, a, b, c: int; };
Mesh: adt { v: array of Vector; f: array of Tri; };

Tree: adt {
	x, y: int;
	fire: int;			# fire_frame_idx; 0 = not burning
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
d3c: ref Draw3d->Context;
font: ref Font;
ink: array of ref Image;
have_tone := 0;
song_mute := 0;

meshes: array of ref Mesh;	# bins 1..6, index 1..6
lerpm: ref Mesh;		# SpriteInterpolate scratch
treeimg, treemask: ref Image;
fireimg, firemask: array of ref Image;
houseimg, housemask: ref Image;
doorimg, doormask: ref Image;
peasextent: Rect;
treeextent: Rect;

snowimg, snowmask: ref Image;

trees: array of Tree;
peas: array of Peasant;
steps: array of Step;
ksteps: array of Step;
nsteps, nksteps: int;

king_x, king_y: int;
king_theta: real;
king_phase, king_ms: int;
king_timeout: real;

snow_x, snow_y: int;
new_snow_ms: int;

animate_ms, animate_phase: int;
not_stopped: int;
door_open_t0: real;
t0, tf: real;
best_score := 9999.0;

# the original's three PopUpOk pages
page := 0;

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
	fclock = load Frameclock Frameclock->PATH;
	fclock->init();
	# Prefer the protocol-backed provider: it hands geometry to the
	# device, and thence to Metal where the host has it, instead of
	# projecting and rasterizing in Limbo.  It falls back to its own
	# software paths by itself when the probe finds no device, so the
	# load below is only for the file being absent.
	draw3d = load Draw3d "/dis/math/draw3ddev.dis";
	if(draw3d == nil)
		draw3d = load Draw3d Draw3d->PATH;
	if(draw3d == nil){
		sys->fprint(sys->fildes(2), "wenceslas: no draw3d: %r\n");
		return;
	}
	draw3d->init();
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
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");

	# the exact TempleOS 16-color palette, index = TempleOS color
	ink = array[16] of ref Image;
	cols := grpal->values();
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);

	meshes = array[7] of ref Mesh;
	for(i = 1; i <= 6; i++)
		meshes[i] = loadmesh(sys->sprint("/icons/temple/wenceslas_%d.mesh", i));
	if(meshes[1] != nil)
		lerpm = ref Mesh(array[len meshes[1].v] of Vector, meshes[1].f);

	treeimg = d.open("/icons/temple/wenceslas_7.bit");
	treemask = d.open("/icons/temple/wenceslas_7.mask");
	fireimg = array[2] of ref Image;
	firemask = array[2] of ref Image;
	fireimg[0] = d.open("/icons/temple/wenceslas_8.bit");
	firemask[0] = d.open("/icons/temple/wenceslas_8.mask");
	fireimg[1] = d.open("/icons/temple/wenceslas_9.bit");
	firemask[1] = d.open("/icons/temple/wenceslas_9.mask");
	houseimg = d.open("/icons/temple/wenceslas_10.bit");
	housemask = d.open("/icons/temple/wenceslas_10.mask");
	doorimg = d.open("/icons/temple/wenceslas_11.bit");
	doormask = d.open("/icons/temple/wenceslas_11.mask");

	# Init()'s SpriteExtents of bins 7 and 12 keep the sprites inside the
	# border; bin 12 exists only to be measured.
	treeextent = Rect((0,0),(1,1));
	if(treeimg != nil)
		treeextent = treeimg.r;
	peasextent = Rect((0,0),(1,1));
	pe := d.open("/icons/temple/wenceslas_12.bit");
	if(pe != nil)
		peasextent = pe.r;

	snowimg = ink[WHITE];
	snowmask = d.newimage(Rect((0,0),(SNOW_TILE_SIZE,SNOW_TILE_SIZE)),
		Draw->GREY1, 0, 0);

	trees = array[TREES_NUM] of Tree;
	peas = array[PEASANTS_NUM] of Peasant;
	steps = array[MAX_STEPS] of Step;
	ksteps = array[MAX_KSTEPS] of Step;
	if(scorestore != nil)
		best_score = scorestore->loadreal("wenceslas", best_score);

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	game_init();
	if(have_tone)
		spawn songtask();

	# AnimateTask's Sleep(1), thirty steps to a 30ms tick, one redraw
	ticks := chan of int;
	spawn fclock->ticker(ticks, 60);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	pointerev := <-win.ctxt.ptr =>
		# The titlebar is drawn by this window and only sees a click
		# if the program hands it one: without this arm the move,
		# resize and menu buttons on the window do nothing at all.
		win.pointer(*pointerev);
	k := <-win.ctxt.kbd =>
		key(k);
	dtms := <-ticks =>
		fcacc += dtms;
		for(fcn := 0; fcacc >= FCSTEP && fcn < 4; fcn++){
			if(page >= 3)
				for(st := 0; st < 30; st++)
					animate();
			fcacc -= FCSTEP;
		}
		redraw();
	}
}

key(k: int)
{
	if(page < 3){
		if((k & Keyboard->Keyup) != Keyboard->Keyup){
			page++;
			if(page >= 3)
				t0 = now();
		}
		return;
	}
	case k {
	16r1b or 'q' or 'Q' =>
		if(have_tone)
			tone->stop();
		exit;
	'\n' =>
		game_init();
	' ' =>
		burn_trees();
	Keyboard->Right =>
		move_king(KING_STEP, 0, 0.0);
	Keyboard->Left =>
		move_king(-KING_STEP, 0, PI);
	Keyboard->Down =>
		move_king(0, KING_STEP, -PI/2.0);
	Keyboard->Up =>
		move_king(0, -KING_STEP, PI/2.0);
	}
}

winsize(): (int, int)
{
	img := win.image;
	if(img == nil)
		return (640, 480);
	return (img.r.dx(), img.r.dy());
}

game_init()
{
	(w, h) := winsize();
	snow_x = snow_y = 0;
	new_snow_ms = 0;
	if(snowmask != nil)
		snowmask.draw(snowmask.r, win.display.transparent, nil, Point(0,0));
	nsteps = nksteps = 0;

	# x = RandU16%(w-2*BORDER-(max_x-min_x+1))+BORDER-min_x, and likewise y
	i: int;
	for(i = 0; i < TREES_NUM; i++)
		trees[i] = Tree(place(w, treeextent.min.x, treeextent.dx()),
			place(h, treeextent.min.y, treeextent.dy()), 0);
	for(i = 0; i < PEASANTS_NUM; i++)
		peas[i] = Peasant(
			real place(w, peasextent.min.x, peasextent.dx()),
			real place(h, peasextent.min.y, peasextent.dy()),
			PI*2.0*rnreal(), 0, 0.0);

	animate_phase = 0;
	animate_ms = 0;
	king_phase = 0;
	king_ms = 0;
	king_timeout = 0.0;
	king_x = w/2;
	king_y = h/2;
	king_theta = -PI/2.0;
	door_open_t0 = 0.0;
	t0 = now();
	tf = 0.0;
	song_mute = 0;
}

place(span, mn, size: int): int
{
	room := span - 2*BORDER - size;
	if(room < 1)
		room = 1;
	return rn(room) + BORDER - mn;
}

move_king(dx, dy: int, th: real)
{
	(w, h) := winsize();
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
	step_new(real king_x, real king_y, king_theta, king_phase & 2, 1);
	king_timeout = now() + 0.5;
}

burn_trees()
{
	for(i := 0; i < TREES_NUM; i++){
		dx := real(king_x - trees[i].x);
		dy := real(king_y - trees[i].y);
		if(dx*dx + dy*dy < 10.0*10.0)
			trees[i].fire = 1;
	}
}

# StepNew: the king's own track goes on king_step_head as well, and either
# two left prints or two right prints go on the visible track.
step_new(x, y, th: real, left_right, king: int)
{
	ts := now();
	if(king && nksteps < MAX_KSTEPS)
		ksteps[nksteps++] = Step(int x, int y, ts);
	s := math->sin(th);
	c := math->cos(th);
	if(left_right){
		addstep(x - 3.5*s + 2.0*c, y + 3.5*c + 2.0*s, ts);
		addstep(x - 3.5*s + 5.0*c, y + 3.5*c + 5.0*s, ts);
	}else{
		addstep(x + 3.5*s, y - 3.5*c, ts);
		addstep(x + 3.5*s + 3.0*c, y - 3.5*c + 3.0*s, ts);
	}
}

addstep(x, y, ts: real)
{
	if(nsteps < MAX_STEPS)
		steps[nsteps++] = Step(int x, int y, ts);
}

# One AnimateTask iteration: the original's Sleep(1), so per millisecond.
animate()
{
	ts := now();
	(w, h) := winsize();

	i := 0;
	while(i < nsteps){
		if(ts - steps[i].t0 > 5.0)
			steps[i] = steps[--nsteps];
		else
			i++;
	}
	i = 0;
	while(i < nksteps){
		if(ts - ksteps[i].t0 > 3.0)
			ksteps[i] = ksteps[--nksteps];
		else
			i++;
	}

	not_stopped = 0;
	for(pi := 0; pi < PEASANTS_NUM; pi++){
		p := peas[pi];
		if(p.stopped){
			if(p.door_t != 0.0 && ts > p.door_t + 1.0){
				p.door_t = 0.0;
				p.x = p.y = -9999.0;
			}
			peas[pi] = p;
			continue;
		}
		dx := p.x - real(w/2);
		dy := p.y - real(h/2);
		if(dx*dx + dy*dy < 20.0*20.0){
			p.stopped = 1;
			p.door_t = door_open_t0 = ts;
			peas[pi] = p;
			continue;
		}
		for(ti := 0; ti < TREES_NUM; ti++)	# hang out by the fire
			if(trees[ti].fire){
				dx = p.x - real trees[ti].x;
				dy = p.y - real trees[ti].y;
				if(dx*dx + dy*dy < 20.0*20.0){
					p.stopped = 1;
					break;
				}
			}
		if(!p.stopped){
			p.theta = follow(p.x, p.y, p.theta, ts);
			p.x += math->cos(p.theta) / 100.0;
			p.y += math->sin(p.theta) / 100.0;
			if(!(real(BORDER/2) <= p.x && p.x < real(w - BORDER/2)) ||
			   !(real(BORDER/2) <= p.y && p.y < real(h - BORDER/2))){
				p.theta += PI;
				p.x += 3.0*math->cos(p.theta) / 100.0;
				p.y += 3.0*math->sin(p.theta) / 100.0;
			}
			if(animate_ms == 0 && (animate_phase & 1))
				step_new(p.x, p.y, p.theta, animate_phase & 2, 0);
			not_stopped++;
		}
		peas[pi] = p;
	}

	if(not_stopped == 0 && tf == 0.0){
		tf = ts;
		song_mute = 1;
		if(have_tone){
			tone->beep(ona2freq(86.0), 200);
			sys->sleep(100);
		}
		if(tf - t0 < best_score){
			best_score = tf - t0;
			if(scorestore != nil)
				scorestore->savereal("wenceslas", best_score);
			if(have_tone){
				tone->beep(ona2freq(86.0), 200);
				sys->sleep(100);
			}
		}
		song_mute = 0;
	}

	snow_x += rn(3) - 1;
	snow_y += 1 - sgn(rn(65536) & 3);
	if(new_snow_ms++ > 8){
		new_snow_ms = 0;
		plotsnow(rn(65536) & (SNOW_TILE_SIZE-1), rn(65536) & (SNOW_TILE_SIZE-1));
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
}

sgn(v: int): int
{
	if(v == 0)
		return 0;
	if(v < 0)
		return -1;
	return 1;
}

plotsnow(x, y: int)
{
	if(snowmask == nil)
		return;
	snowmask.draw(Rect((x, y), (x+1, y+1)), win.display.opaque, nil, Point(0,0));
}

# Follow(): steer toward the freshest of the king's footprints within 15
# pixels, the age counting 1000*seconds squared against the distance.
follow(px, py, th, ts: real): real
{
	best := 1e30;
	for(i := 0; i < nksteps; i++){
		s := ksteps[i];
		dx := real s.x - px;
		dy := real s.y - py;
		d := dx*dx + dy*dy;
		if(d == 0.0 || d >= 15.0*15.0)
			continue;
		d += 1000.0 * (ts - s.t0) * (ts - s.t0);
		if(d < best){
			best = d;
			th = math->atan2(dy, dx);
		}
	}
	return th;
}

# --- drawing ------------------------------------------------------------

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	ts := now();
	i: int;

	# WHITE<<4+BLUE: the field is the document background
	img.draw(img.r, ink[WHITE], nil, Point(0, 0));

	for(i = 0; i < TREES_NUM; i++)		# trees behind the house
		if(trees[i].y <= h/2)
			draw_tree(img, o, i);
	blit(img, houseimg, housemask, o.x + w/2, o.y + h/2);
	if(ts < door_open_t0 + 1.0)
		blit(img, doorimg, doormask, o.x + w/2, o.y + h/2);
	for(i = 0; i < TREES_NUM; i++)		# trees in front of it
		if(trees[i].y > h/2)
			draw_tree(img, o, i);

	# GrPlot3 with thick 4: DKGRAY for two seconds, then LTGRAY, which on
	# the white field is the print fading into the snow.
	for(i = 0; i < nsteps; i++){
		s := steps[i];
		col := ink[DKGRAY];
		if(ts - s.t0 >= 2.0)
			col = ink[LTGRAY];
		img.draw(Rect((o.x+s.x-2, o.y+s.y-2), (o.x+s.x+2, o.y+s.y+2)),
			col, nil, Point(0, 0));
	}

	if(page >= 3){
		setup3d(img);
		for(i = 0; i < PEASANTS_NUM; i++){
			p := peas[i];
			if(p.x < -100.0)
				continue;
			if(p.stopped)
				draw_man(meshes[5], nil, 0.0, p.x, p.y, p.theta);
			else
				draw_man(meshes[framespeas(animate_phase)],
					meshes[framespeas(animate_phase+1)],
					real animate_ms / 250.0,
					p.x, p.y, p.theta);
		}
		if(ts > king_timeout)
			draw_man(meshes[2], nil, 0.0,
				real king_x, real king_y, king_theta);
		else
			draw_man(meshes[framesking(king_phase)],
				meshes[framesking(king_phase+1)],
				real king_ms / 250.0,
				real king_x, real king_y, king_theta);
	}

	# ROP_MONO|WHITE snow tile, over everything
	if(snowmask != nil)
		for(y := mod(snow_y, SNOW_TILE_SIZE) - SNOW_TILE_SIZE; y <= h; y += SNOW_TILE_SIZE)
			for(x := mod(snow_x, SNOW_TILE_SIZE) - SNOW_TILE_SIZE; x <= w; x += SNOW_TILE_SIZE)
				img.draw(Rect((o.x+x, o.y+y),
					(o.x+x+SNOW_TILE_SIZE, o.y+y+SNOW_TILE_SIZE)),
					snowimg, snowmask, Point(0, 0));

	tt := ts;
	if(tf != 0.0){
		if(blink())
			img.text(Point(o.x+w/2-(FW*14)/2, o.y+h/2+FH), ink[LTRED],
				Point(0, 0), font, "Game Completed");
		tt = tf;
	}
	if(font != nil)
		img.text(Point(o.x, o.y), ink[LTBLUE], Point(0, 0), font,
			sys->sprint("Freezing Peasants:%d Time:%3.2f Best:%3.2f",
				not_stopped, tt-t0, best_score));
	if(page < 3)
		popup(img, o, w, h);
	img.flush(Draw->Flushnow);
}

# king_imgs[4]={2,1,2,3}, peasant_imgs[4]={5,4,5,6}
framesking(p: int): int
{
	return (array[] of {2, 1, 2, 3})[p & 3];
}

framespeas(p: int): int
{
	return (array[] of {5, 4, 5, 6})[p & 3];
}

mod(a, m: int): int
{
	r := a % m;
	if(r < 0)
		r += m;
	return r;
}

draw_tree(img: ref Image, o: Point, i: int)
{
	t := trees[i];
	if(t.fire){
		# fire_frame_idx++ &1 in DrawIt: the flame alternates every frame
		trees[i].fire = t.fire + 1;
		blit(img, fireimg[t.fire & 1], firemask[t.fire & 1], o.x+t.x, o.y+t.y);
	}else
		blit(img, treeimg, treemask, o.x+t.x, o.y+t.y);
}

blit(img, src, mask: ref Image, x, y: int)
{
	if(src == nil)
		return;
	img.draw(src.r.addpt(Point(x, y)), src, mask, src.r.min);
}

# Sprite3Mat4x4B with Mat4x4RotY(theta+pi/2) then Mat4x4RotX(pi/6): the
# mesh is rotated and dropped at the screen point with no perspective, the
# depth buffer sorting it.  See setup3d for the orthographic projection.
draw_man(m, m2: ref Mesh, t, x, y, theta: real)
{
	if(m == nil)
		return;
	if(m2 != nil && lerpm != nil && len m2.v == len m.v){
		for(i := 0; i < len m.v; i++){
			a := m.v[i];
			b := m2.v[i];
			lerpm.v[i] = Vector(a.x + t*(b.x-a.x), a.y + t*(b.y-a.y),
				a.z + t*(b.z-a.z));
		}
		lerpm.f = m.f;
		m = lerpm;
	}
	(w, h) := winsize();
	draw3d->mode(Draw3d->MODEL);
	draw3d->identity();
	draw3d->scale(1.0, 1.0, -1.0);
	draw3d->translate(x - real(w/2), y - real(h/2), 0.0);
	draw3d->rotatex(180.0/6.0);
	draw3d->rotatey((theta + PI/2.0)*180.0/PI);
	tri := array[3] of Vector;
	nv := len m.v;
	for(i := 0; i < len m.f; i++){
		f := m.f[i];
		if(f.a >= nv || f.b >= nv || f.c >= nv)
			continue;
		tri[0] = m.v[f.a];
		tri[1] = m.v[f.b];
		tri[2] = m.v[f.c];
		draw3d->setcolour(d3c, ink[f.col & 15]);
		draw3d->fillpoly3(d3c, tri, Vector(0.0, 0.0, 0.0), 1.0);
	}
}

# The men are drawn without perspective, so the projection is orthographic:
# one world unit is one pixel, and the viewport's own scaling is divided
# back out.  clipbehind stays off — an orthographic sprite straddles z=0 by
# design — and the model matrix's scale(1,1,-1) makes a smaller sprite z
# nearer, which is the sense TempleOS's depth buffer uses.
setup3d(img: ref Image)
{
	if(d3c == nil)
		d3c = draw3d->context(img);
	else
		draw3d->resize(d3c, img);
	draw3d->viewport(d3c, img.r.min.x, img.r.min.y, img.r.max.x, img.r.max.y);
	draw3d->setz(d3c, 1);
	draw3d->clearz(d3c);
	draw3d->setzclip(d3c, 0);
	draw3d->mode(Draw3d->PROJ);
	p := draw3d->newmatrix();
	p[0][0] = 1.0 / d3c.mx;
	p[1][1] = 1.0 / d3c.my;
	p[2][2] = 1.0;
	p[3][3] = 1.0;
	draw3d->loadmatrix(p);
}

# The original's PopUpOk pages: the carol, then how to play.
popup(img: ref Image, o: Point, w, h: int)
{
	if(font == nil)
		return;
	lines := popuptext(page);
	pad := 10;
	tw := 0;
	for(i := 0; i < len lines; i++){
		lw := font.width(lines[i]);
		if(lw > tw)
			tw = lw;
	}
	bw := tw + 2*pad;
	bh := (len lines + 2)*(font.height+1) + 2*pad;
	bx := o.x + (w - bw)/2;
	by := o.y + (h - bh)/2;
	if(by < o.y)
		by = o.y;
	img.draw(Rect((bx-2, by-2), (bx+bw+2, by+bh+2)), ink[BLACK], nil, Point(0,0));
	img.draw(Rect((bx, by), (bx+bw, by+bh)), ink[WHITE], nil, Point(0,0));
	y := by + pad;
	for(i = 0; i < len lines; i++){
		col := ink[BLACK];
		if(page == 2 && i == 0)
			col = ink[PURPLE];
		img.text(Point(bx+pad, y), col, Point(0, 0), font, lines[i]);
		y += font.height + 1;
	}
	img.text(Point(bx+pad, y + font.height), ink[BLUE], Point(0, 0), font,
		"any key");
}

popuptext(n: int): array of string
{
	case n {
	0 =>
		return array[] of {
		"Good King Wenceslas looked out",
		"On the feast of Stephen",
		"When the snow lay round about",
		"Deep and crisp and even",
		"Brightly shone the moon that night",
		"Though the frost was cruel",
		"When a poor man came in sight",
		"Gath'ring winter fuel",
		"",
		"\"Hither, page, and stand by me",
		"If thou know'st it, telling",
		"Yonder peasant, who is he?",
		"Where and what his dwelling?\"",
		"\"Sire, he lives a good league hence",
		"Underneath the mountain",
		"Right against the forest fence",
		"By Saint Agnes' fountain.\"",
		"",
		"\"Bring me flesh and bring me wine",
		"Bring me pine logs hither",
		"Thou and I will see him dine",
		"When we bear him thither.\"",
		"Page and monarch forth they went",
		"Forth they went together",
		"Through the rude wind's wild lament",
		"And the bitter weather",
		};
	1 =>
		return array[] of {
		"\"Sire, the night is darker now",
		"And the wind blows stronger",
		"Fails my heart, I know not how,",
		"I can go no longer.\"",
		"\"Mark my footsteps, my good page",
		"Tread thou in them boldly",
		"Thou shalt find the winter's rage",
		"Freeze thy blood less coldly.\"",
		"",
		"In his master's steps he trod",
		"Where the snow lay dinted",
		"Heat was in the very sod",
		"Which the Saint had printed",
		"Therefore, Christian men, be sure",
		"Wealth or rank possessing",
		"Ye who now will bless the poor",
		"Shall yourselves find blessing",
		};
	}
	return array[] of {
	"Winceslas Game",
	"",
	"Start fires by pressing <SPACE>",
	"on trees. (Yule logs)",
	"",
	"Lead peasants to fires.",
	};
}

# --- meshes -------------------------------------------------------------

loadmesh(path: string): ref Mesh
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[65536] of byte;
	n := 0;
	for(;;){
		r := sys->read(fd, buf[n:], len buf - n);
		if(r <= 0)
			break;
		n += r;
		if(n == len buf)
			break;
	}
	if(n <= 0)
		return nil;
	(nil, lines) := sys->tokenize(string buf[0:n], "\n");
	if(lines == nil)
		return nil;
	(nil, h) := sys->tokenize(hd lines, " \t");
	if(len h != 3 || hd h != "mesh")
		return nil;
	nv := int hd tl h;
	nf := int hd tl tl h;
	m := ref Mesh(array[nv] of Vector, array[nf] of Tri);
	vi := 0;
	fi := 0;
	for(lines = tl lines; lines != nil; lines = tl lines){
		(nil, t) := sys->tokenize(hd lines, " \t\r");
		if(t == nil)
			continue;
		if(hd t == "v" && len t == 4 && vi < nv){
			t = tl t;
			x := real int hd t; t = tl t;
			y := real int hd t; t = tl t;
			m.v[vi++] = Vector(x, y, real int hd t);
		}else if(hd t == "f" && len t == 5 && fi < nf){
			t = tl t;
			c := int hd t; t = tl t;
			a := int hd t; t = tl t;
			b := int hd t; t = tl t;
			m.f[fi++] = Tri(c, a, b, int hd t);
		}
	}
	if(vi != nv || fi != nf)
		return nil;
	return m;
}

# --- odds and ends ------------------------------------------------------

# Kernel/KMisc.HC Ona2Freq: 440.0/32*2^(ona/12), so ona 60 is 440Hz
ona2freq(ona: real): int
{
	return int(440.0/32.0 * math->pow(2.0, ona/12.0));
}

blink(): int
{
	return int(now() * 5.0) & 1;
}

songtask()
{
	# SongTask's three looped Play() strings
	for(;;){
		if(song_mute){
			sys->sleep(100);
			continue;
		}
		tone->play("5eCCCDCC4qGeAGAB5qCC");
		tone->play("5eCCCDCC4qGeAGAB5qCC");
		tone->play("5eGFEDEDqC4eAGAB5qCC");
	}
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
	return real(rand->rand(1000000)) / 1000000.0;
}


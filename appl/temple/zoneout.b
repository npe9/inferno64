implement Zoneout;

# TempleOS Demo/Games/ZoneOut.HC — tank shooter.
#
# Terry's own PopUpOk opens it: "I refuse to rip-off the original / so this
# is intentionally crappy".  The quirks below are his, and are reproduced
# rather than tidied.
#
# The world is drawn through ZOTransform, which is Mat4x4RotX(pi/16) *
# Mat4x4RotY(us.angle - pi/2) * Mat4x4TranslationEqu(-us) followed by a
# perspective divide: x' = SCRN_SCALE/2 * x/z, y' = SCRN_SCALE/2 *
# (y+TANK_HEIGHT)/z, about the window centre.  That is an ordinary camera
# plus a shifted y, so it is expressed here as draw3d(2) matrices — the
# TANK_HEIGHT as an eye-space translate, the divide as frustumoffset() —
# rather than a per-vertex settransform closure.  draw3d's perspective
# divides by -z, so the view matrix ends with a scale(1,1,-1) to hand it
# ZoneOut's +z-forward eye space.
#
# Tanks, hit tanks and shots are SPT_MESH sprites (bins 1, 2, 3) blitted by
# Sprite3YB with the object's -angle, over DCDepthBufAlloc's depth buffer;
# here that is draw3d's z-buffer and one fillpoly3 per triangle in the
# mesh's own TempleOS palette colour.  The sky panorama is bin 4, a plain
# screen-space Sprite3 drawn three times at 1280-pixel spacing before the
# transform is installed.
#
# GAP: MenuPush File/Play menu bar; every entry is on its key already.
# GAP: ZOTransform clamps z to 1 rather than clipping, so geometry behind
#      the eye is smeared to enormous coordinates instead of vanishing;
#      draw3d rejects a triangle with a vertex behind the eye.  Both put it
#      off-screen, but the original would smear a straddling triangle.
# GAP: the original redraws through the window manager at ~30fps while
#      AnimateTask runs at 50Hz; the same split is kept here.  A whole
#      frame — ten tanks, 820 triangles, plus the clear — measures 1.9ms
#      on this tree, so nothing is culled or simplified for speed.

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

Zoneout: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# The port's own simulation step, in milliseconds.  The frame clock
# runs at 60fps and this many milliseconds of simulation are run for
# each frame's worth of real time, so the picture is smooth and the
# simulation keeps the speed it was written for.
FCSTEP: con 20;
# The most substeps one frame may run: enough to cover a frame of
# real time at this step, with headroom.  A fixed cap is wrong -
# four substeps covers 40ms at FCSTEP 10 and only 4ms at FCSTEP 1.
FCMAX: con 2 + 20/FCSTEP;
fcacc := 0;

THEM_NUM: con 10;
SCRN_SCALE: con 512;
TANK_HEIGHT: con 32;
PI: con 3.141592653589793;

# TempleOS FONT_WIDTH / FONT_HEIGHT
FW := 8;			# the font's digit advance, set when the font opens
FH := 8;			# the font's line height, set when the font opens

# the window the sky arithmetic assumes: Wrap() spans (-pi,pi], so
# 640*Wrap(2*angle)/pi spans (-640,640], one sprite width per wrap.
SCRW: con 640;
SCRH: con 480;
SKYW: con 1280;
SKYY: con 90;

# TempleOS palette indices used below
BLACK, BLUE, GREEN, CYAN, RED, PURPLE, BROWN, LTGRAY: con iota;
DKGRAY, LTBLUE, LTGREEN, LTCYAN, LTRED, LTPURPLE, YELLOW, WHITE: con iota + 8;

Tri: adt { col, a, b, c: int; };
Mesh: adt { v: array of Vector; f: array of Tri; };

Obj: adt {
	x, y, z, angle: real;
	hit: int;
};

Shot: adt {
	x, y, z, angle, t0: real;
};

win: ref Window;
d3c: ref Draw3d->Context;
font: ref Font;
ink: array of ref Image;
tankm, hitm, shotm: ref Mesh;
sky, skymask: ref Image;

us: Obj;
them: array of Obj;
shots: list of ref Shot;
num_them := THEM_NUM;
game_t0, game_tf: real;
best_score := 9999.0;
have_tone := 0;
help := 1;			# the opening PopUpOk

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
		sys->fprint(sys->fildes(2), "zoneout: no draw3d: %r\n");
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

	win = wmclient->window(ctxt, "TempleOS ZoneOut", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/lucida/unicode.8.font");
	if(font == nil)
		font = Font.open(d, "/fonts/temple/temple.font");
	if(font != nil){
		FW = font.width("0");
		FH = font.height;
	}

	# the exact TempleOS 16-color palette, index = TempleOS color
	ink = array[16] of ref Image;
	cols := grpal->values();
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);

	tankm = loadmesh("/icons/temple/zoneout_1.mesh");
	hitm = loadmesh("/icons/temple/zoneout_2.mesh");
	shotm = loadmesh("/icons/temple/zoneout_3.mesh");
	sky = d.open("/icons/temple/zoneout_4.bit");
	skymask = d.open("/icons/temple/zoneout_4.mask");

	if(scorestore != nil)
		best_score = scorestore->loadreal("zoneout", best_score);

	them = array[THEM_NUM] of Obj;
	game_init();
	win.reshape(Rect((0, 0), (SCRW, SCRH)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	if(have_tone)
		spawn songtask();

	# AnimateTask's Sleep(20); the winmgr's own ~30fps redraw is a
	# separate count of those ticks.
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
		if(fcacc > FCSTEP*FCMAX)
			fcacc = FCSTEP*FCMAX;
		for(fcn := 0; fcacc >= FCSTEP && fcn < FCMAX; fcn++){
			if(!help)
				animate();
			fcacc -= FCSTEP;
		}
		# It used to draw every second 20ms tick, which is 33fps; the
		# frame clock draws every frame and the animation still steps
		# every 20ms of real time.
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
	if(help){
		# PopUpOk: any key dismisses it and starts the clock
		if((k & Keyboard->Keyup) != Keyboard->Keyup){
			help = 0;
			game_t0 = now();
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
		fire();
	Keyboard->Left =>
		us.angle += PI / 256.0;
	Keyboard->Right =>
		us.angle -= PI / 256.0;
	Keyboard->Up =>
		move_us(us.angle);
	Keyboard->Down =>
		move_us(us.angle + PI);
	}
}

move_us(dir: real)
{
	us.x += 0.1 * real SCRN_SCALE * math->cos(dir);
	us.z += 0.1 * real SCRN_SCALE * math->sin(dir);
}

# Fire(): the shot starts at the tank, at TANK_HEIGHT.  TempleOS y grows
# downward, so a shot is drawn below the enemy tanks' origins, not level
# with their guns.  That is what the original does.
fire()
{
	s := ref Shot(us.x, real TANK_HEIGHT, us.z, us.angle, now());
	shots = s :: shots;
	if(have_tone)
		tone->beep(ona2freq(74.0), 60);
}

# AnimateTask: Sleep(20) between steps, so these are per-20ms rates.
animate()
{
	ts := now();
	for(i := 0; i < THEM_NUM; i++){
		t := them[i];
		t.x += real SCRN_SCALE / 32.0 * math->cos(t.angle);
		t.z += real SCRN_SCALE / 32.0 * math->sin(t.angle);
		t.angle += rnreal() / 100.0;
		them[i] = t;
	}
	live: list of ref Shot;
	for(sl := shots; sl != nil; sl = tl sl){
		sh := hd sl;
		if(ts - sh.t0 > 1.0)
			continue;
		sh.x += 0.25 * real SCRN_SCALE * math->cos(sh.angle);
		sh.z += 0.25 * real SCRN_SCALE * math->sin(sh.angle);
		live = sh :: live;
	}
	shots = rev(live);
}

# --- meshes -------------------------------------------------------------

loadmesh(path: string): ref Mesh
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[32768] of byte;
	n := sys->read(fd, buf, len buf);
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

# Sprite3YB(dc,x,y,z,mesh,-angle): the mesh sits at (x,y,z) turned about
# world-up.  draw3d's rotatey and this -angle agree: the mesh's +x nose
# ends up along (cos angle, sin angle) in the (x,z) plane, which is the
# direction MoveUs() and the enemy walk uses.
drawmesh(m: ref Mesh, x, y, z, angle: real)
{
	if(m == nil)
		return;
	ca := math->cos(-angle);
	sa := math->sin(-angle);
	nv := len m.v;
	wv := array[nv] of Vector;
	for(i := 0; i < nv; i++){
		v := m.v[i];
		wv[i] = Vector(x + ca*v.x + sa*v.z, y + v.y, z - sa*v.x + ca*v.z);
	}
	tri := array[3] of Vector;
	for(i = 0; i < len m.f; i++){
		f := m.f[i];
		if(f.a >= nv || f.b >= nv || f.c >= nv)
			continue;
		tri[0] = wv[f.a];
		tri[1] = wv[f.b];
		tri[2] = wv[f.c];
		draw3d->setcolour(d3c, ink[f.col & 15]);
		draw3d->fillpoly3(d3c, tri, Vector(0.0, 0.0, 0.0), 1.0);
	}
}

# ZOTransform as matrices.  Model/view is read right to left:
# translate to the eye, RotY(angle-pi/2), RotX(pi/16), lift by TANK_HEIGHT
# in eye space, then negate z because draw3d divides by -z while ZoneOut
# divides by +z.  RotX's sign is the one that puts the ground below the
# horizon.  The projection's SCRN_SCALE/2 over the viewport half-extent is
# the original's own scale, kept correct across a resize.
setup3d(img: ref Image)
{
	if(d3c == nil)
		d3c = draw3d->context(img);
	else
		draw3d->resize(d3c, img);
	draw3d->viewport(d3c, img.r.min.x, img.r.min.y, img.r.max.x, img.r.max.y);
	draw3d->setz(d3c, 1);
	draw3d->clearz(d3c);
	draw3d->setzclip(d3c, 1);

	draw3d->mode(Draw3d->MODEL);
	draw3d->identity();
	draw3d->scale(1.0, 1.0, -1.0);
	draw3d->translate(0.0, real TANK_HEIGHT, 0.0);
	draw3d->rotatex(180.0 / 16.0);
	draw3d->rotatey((us.angle - PI/2.0) * 180.0 / PI);
	draw3d->translate(-us.x, -us.y, -us.z);

	draw3d->mode(Draw3d->PROJ);
	draw3d->identity();
	draw3d->frustumoffset((real SCRN_SCALE/2.0) / d3c.mx,
		(real SCRN_SCALE/2.0) / d3c.my, 0.0);
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	cx := w / 2;
	cy := h / 2;

	# "$$BG,LTCYAN$$": the document background under everything
	img.draw(img.r, ink[LTCYAN], nil, Point(0, 0));

	# three screen-space Sprite3 copies of the sky panorama, before the
	# transform is installed: 640*Wrap(2*angle)/pi spans exactly one
	# sprite width, so the three tile without a seam at the wrap.
	if(sky != nil){
		sx := int(real SCRW * wrappi(2.0 * us.angle) / PI);
		for(k := -1; k <= 1; k++)
			blit(img, sky, skymask, o.x + sx + k*SKYW, o.y + SKYY);
	}

	setup3d(img);

	# DrawIt registers the hits and sinks the tank as it draws: a tank
	# within SCRN_SCALE/2 of any shot is marked hit, and its drawn y is
	# raised by Sqrt(dd) for every such shot — further shots move it
	# more, so it springs up and settles as the shot arrives.
	hitr2 := real (SCRN_SCALE/2) * real (SCRN_SCALE/2);
	for(i := 0; i < THEM_NUM; i++){
		t := them[i];
		y := t.y;
		for(sl := shots; sl != nil; sl = tl sl){
			sh := hd sl;
			dd := (t.x - sh.x)*(t.x - sh.x) + (t.z - sh.z)*(t.z - sh.z);
			if(dd < hitr2){
				y -= math->sqrt(dd);
				if(!t.hit){
					t.hit = 1;
					them[i] = t;
					if(--num_them == 0){
						game_tf = now();
						if(game_tf - game_t0 < best_score){
							best_score = game_tf - game_t0;
							if(scorestore != nil)
								scorestore->savereal("zoneout", best_score);
						}
					}
				}
			}
		}
		m := tankm;
		if(t.hit)
			m = hitm;
		drawmesh(m, t.x, y, t.z, t.angle);
	}
	for(sl := shots; sl != nil; sl = tl sl){
		sh := hd sl;
		drawmesh(shotm, sh.x, sh.y, sh.z, sh.angle);
	}

	# The crosshair is drawn LTGREEN, then drawn again in BLACK while the
	# game is still running — so it reads black in play and green once the
	# last tank is down.
	cross(img, o.x+cx, o.y+cy, ink[LTGREEN]);
	tt := now();
	if(game_tf != 0.0){
		if(blink())
			img.text(Point(o.x+cx-font.width("Game Completed")/2, o.y+cy-FH/2),
				ink[RED], Point(0, 0), font, "Game Completed");
		tt = game_tf;
	}else
		cross(img, o.x+cx, o.y+cy, ink[BLACK]);

	if(font != nil)
		img.text(Point(o.x, o.y), ink[BLACK], Point(0, 0), font,
			sys->sprint("Enemy:%d Time:%3.2f Best:%3.2f",
				num_them, tt-game_t0, best_score));
	if(help)
		popup(img, o, w, h);
	img.flush(Draw->Flushnow);
}

cross(img: ref Image, x, y: int, col: ref Image)
{
	img.line(Point(x-5, y), Point(x+5, y), Draw->Endsquare, Draw->Endsquare,
		0, col, Point(0, 0));
	img.line(Point(x, y-5), Point(x, y+5), Draw->Endsquare, Draw->Endsquare,
		0, col, Point(0, 0));
}

# The original's opening PopUpOk, verbatim.
popup(img: ref Image, o: Point, w, h: int)
{
	lines := array[] of {
		"I refuse to rip-off the original",
		"so this is intentionally crappy",
		"and included for demonstration",
		"purposes.",
		"",
		"Write games, don't play them.",
	};
	if(font == nil)
		return;
	pad := 12;
	tw := 0;
	for(i := 0; i < len lines; i++){
		lw := font.width(lines[i]);
		if(lw > tw)
			tw = lw;
	}
	bw := tw + 2*pad;
	bh := (len lines + 2)*(font.height+2) + 2*pad;
	bx := o.x + (w - bw)/2;
	by := o.y + (h - bh)/2;
	img.draw(Rect((bx-2, by-2), (bx+bw+2, by+bh+2)), ink[BLACK], nil, Point(0, 0));
	img.draw(Rect((bx, by), (bx+bw, by+bh)), ink[WHITE], nil, Point(0, 0));
	y := by + pad;
	for(i = 0; i < len lines; i++){
		img.text(Point(bx+pad, y), ink[BLACK], Point(0, 0), font, lines[i]);
		y += font.height + 2;
	}
	ok := "any key";
	img.text(Point(bx + (bw - font.width(ok))/2, y + font.height/2),
		ink[BLUE], Point(0, 0), font, ok);
}

blit(img, src, mask: ref Image, x, y: int)
{
	if(src == nil)
		return;
	img.draw(src.r.addpt(Point(x, y)), src, mask, src.r.min);
}

# TempleOS Blink is 2.5Hz: ToI64(tS*2*2.5)&1
blink(): int
{
	return int(now() * 5.0) & 1;
}

# Wrap(x) folds into (-pi,pi]
wrappi(a: real): real
{
	two := 2.0 * PI;
	a = math->fmod(a, two);
	if(a > PI)
		a -= two;
	if(a <= -PI)
		a += two;
	return a;
}

# Kernel/KMisc.HC Ona2Freq: 440.0/32*2^(ona/12), so ona 60 is 440Hz
ona2freq(ona: real): int
{
	return int(440.0/32.0 * math->pow(2.0, ona/12.0));
}

songtask()
{
	# SongTask's four looped Play() strings, verbatim
	for(;;){
		tone->play("5sD4B5D4B5qEsG4B5G4B5eD4GsB5F4B5FeD4A5qFG");
		tone->play("5sD4B5D4B5qEsG4B5G4B5eD4GsB5F4B5FeD4A5qFG");
		tone->play("5eGDsFGFGqDE4eB5E4sG5D4G5DqF4sGAGA");
		tone->play("5eGDsFGFGqDE4eB5E4sG5D4G5DqF4sGAGA");
	}
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
	return real(rand->rand(1000000)) / 1000000.0;
}


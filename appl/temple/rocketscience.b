implement Rocketscience;

# TempleOS Demo/Games/RocketScience.HC — guided ODE rocket vs plane
# GAP: MenuPush menu bar absent (all its entries are on keys: Esc/q exit,
#      Enter restart, any key launches); ode(2) integrates the masses at
#      h=2ms, not the original's 1e-6s adaptive step; the ROP_COLLISION
#      framebuffer test is approximated by rocket-mask/plane-mask overlap
#      (same >100 pixel threshold); Noise() is a one-voice approximation.
# any key = blast off · Enter = restart (re-asks anti-spin) · Esc/q quit

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

include "math/polyfill.m";
include "math/draw3d.m";
	draw3d: Draw3d;

include "ode.m";
	ode: Ode;
	ODE, Mass, Spring: import ode;

include "tone.m";
	tone: Tone;

include "rand.m";
	rand: Rand;
include "grpalette.m";
	grpal: Grpalette;
include "frameclock.m";
	fclock: Frameclock;

Rocketscience: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

THRUST: con 1000.0;
RH: con 40.0;
PI: con 3.141592653589793;

# The TempleOS 16-color palette.
TBLACK, TBLUE, TGREEN, TCYAN, TRED, TPURPLE, TBROWN, TLTGRAY,
TDKGRAY, TLTBLUE, TLTGREEN, TLTCYAN, TLTRED, TLTPURPLE, TYELLOW, TWHITE: con iota;
palrgba: array of int;

Mprompt, Marmed, Mfly: con iota;

win: ref Window;
font: ref Font;
ink: array of ref Image;
planespr, planemask: ref Image;		# sprite <1>
planehitspr, planehitmask: ref Image;	# sprite <2>
rocketspr, rocketmask: ref Image;	# sprite <3> (nose points +x)
groundspr, groundmask: ref Image;	# sprite <4>
rbits, pbits: array of byte;		# mask pixels for the collision count
rbpl, pbpl, rdepth, pdepth: int;
bg: ref Image;				# DCAlias stand-in: sky + persistent smoke
sim: ref ODE;
m1, m2, m3: ref Mass;	# bottom, top, plane
mode := Mprompt;
blastoff := 0;
planehit := 0;
nozzle := 0.0;
nozzle_v := 0.0;
antispin := 1.0;
dbg := 0.0;
tx, ty: real;
have_tone := 0;
groundy := 456;
vals: array of real;	# PopUpRangeF64Exp(0.1, 10.001, sqrt(10)) choices
sel := 0;
frames := 0;
sndon := 0;
noise_until := 0;
lastb := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	palrgba = grpal->values();
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	# The device provider, for sprite2d: it sends the rotation or the
	# scale to the GPU as a textured quad instead of resampling it in
	# interpreted Limbo, and falls back to the same C resampler in
	# devdraw.c when the destination is not one the GPU can draw into.
	# 220x220 at 30 degrees measured 2725us a sprite through the Limbo
	# path and 65us through this one, end to end.  It degrades on its
	# own when there is no device, so the second load is only for the
	# .dis file being absent.
	draw3d = load Draw3d "/dis/math/draw3ddev.dis";
	if(draw3d == nil)
		draw3d = load Draw3d Draw3d->PATH;
	ode = load Ode Ode->PATH;
	tone = load Tone Tone->PATH;
	rand = load Rand Rand->PATH;
	fclock = load Frameclock Frameclock->PATH;
	fclock->init();
	if(ode == nil){
		sys->fprint(sys->fildes(2), "rocketscience: no ode\n");
		raise "fail:load";
	}
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	ode->init();
	if(draw3d != nil)
		draw3d->init();
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS RocketScience", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/lucida/unicode.8.font");
	if(font == nil)
		font = Font.open(d, "*default*");
	ink = array[16] of ref Image;
	for(i := 0; i < 16; i++)
		ink[i] = d.color(palrgba[i]);

	planespr = d.open("/icons/temple/rocketscience_1.bit");
	planemask = d.open("/icons/temple/rocketscience_1.mask");
	planehitspr = d.open("/icons/temple/rocketscience_2.bit");
	planehitmask = d.open("/icons/temple/rocketscience_2.mask");
	rocketspr = d.open("/icons/temple/rocketscience_3.bit");
	rocketmask = d.open("/icons/temple/rocketscience_3.mask");
	groundspr = d.open("/icons/temple/rocketscience_4.bit");
	groundmask = d.open("/icons/temple/rocketscience_4.mask");
	(rbits, rbpl, rdepth) = readmask(rocketmask);
	(pbits, pbpl, pdepth) = readmask(planemask);

	# PopUpRangeF64Exp(0.1, 10.001, Sqrt(10)): exp-spaced menu choices
	n := 0;
	tmp := array[16] of real;
	f := math->sqrt(10.0);
	for(x := 0.1; x <= 10.001; x *= f)
		tmp[n++] = x;
	vals = tmp[0:n];

	reset();
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn fclock->ticker(ticks, 60);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		if(mode == Mprompt && (p.buttons & 1) && !(lastb & 1)){
			ei := entryat(p.xy);
			if(ei >= 0){
				sel = ei;
				accept();
			}
		}
		lastb = p.buttons;
	k := <-win.ctxt.kbd =>
		dokey(k);
	<-ticks =>
		step();
		redraw();
	}
}

dokey(k: int)
{
	if(k == 'q' || k == 'Q'){
		quit();
		exit;
	}
	case mode {
	Mprompt =>
		# PopUpMenu: arrows move the cursor, Enter (or a click) chooses;
		# the original's do-while re-asks until a valid choice, so Esc
		# does not leave the prompt.
		case k {
		Keyboard->Up or 'k' =>
			if(sel > 0)
				sel--;
		Keyboard->Down or 'j' =>
			if(sel < len vals - 1)
				sel++;
		'\n' or ' ' =>
			accept();
		}
	Marmed =>
		# GetKey: ANY key blasts off (Esc exits via the File menu binding)
		if(k == 16r1b){
			quit();
			exit;
		}
		blastoff = 1;
		mode = Mfly;
	Mfly =>
		case k {
		16r1b =>
			quit();
			exit;
		'\n' =>
			enterprompt();
		}
	}
}

quit()
{
	if(have_tone)
		tone->stop();
}

# Init(): blast_off=FALSE, plane_hit=FALSE, DocClear (smoke gone),
# then the anti-spin popup; the old masses coast until a choice is made.
enterprompt()
{
	blastoff = 0;
	planehit = 0;
	noise_until = 0;
	if(sndon && have_tone){
		tone->stop();
		sndon = 0;
	}
	if(bg != nil)
		bg.draw(bg.r, ink[TLTCYAN], nil, Point(0, 0));
	mode = Mprompt;
}

accept()
{
	antispin = vals[sel];
	reset();
	mode = Marmed;
}

reset()
{
	sim = ode->new();
	sim.drag_v2 = 0.002;
	sim.drag_v3 = 0.00001;
	sim.accel_limit = 5000.0;
	sim.h = 0.002;
	blastoff = 0;
	planehit = 0;
	nozzle = 0.0;
	nozzle_v = 0.0;
	# TempleOS y-up; we use y-down screen, so invert gravity/thrust signs carefully.
	# Keep physics in screen coords: +y down. Rocket points "up" = -y.
	m1 = ref Mass(0.0, 0.0, 0.0, 0.0,0.0,0.0, 0.0,0.0,0.0, 1.0, 1.0, 0, 0, 4.0, 0);
	m2 = ref Mass(0.0, -RH, 0.0, 0.0,0.0,0.0, 0.0,0.0,0.0, 1.0, 1.0, 0, 0, 4.0, 0);
	m3 = ref Mass(-300.0, -400.0, 0.0, 50.0,0.0,0.0, 0.0,0.0,0.0, 1.0, 1.0, 0, 0, 8.0, 0);
	ode->addmass(sim, m1);
	ode->addmass(sim, m2);
	ode->addmass(sim, m3);
	s := ref Spring(m1, m2, 10000.0, RH, 0.0, 0.0, 0, 0, 0);
	ode->addspring(sim, s);
	if(bg != nil)
		bg.draw(bg.r, ink[TLTCYAN], nil, Point(0, 0));
}

wrapang(a: real): real
{
	while(a >= PI) a -= 2.0*PI;
	while(a < -PI) a += 2.0*PI;
	return a;
}

clamp(v, lo, hi: real): real
{
	if(v < lo) return lo;
	if(v > hi) return hi;
	return v;
}

step()
{
	ode->clearforces(sim);
	# heading from bottom to top
	dx := m2.x - m1.x;
	dy := m2.y - m1.y;
	th := math->atan2(dy, dx);
	# body unit
	blen := math->sqrt(dx*dx + dy*dy);
	if(blen < 0.001) blen = 0.001;
	bx := dx / blen;
	by := dy / blen;
	# antispin damping of angular rate
	dth := antispin * (m2.vy*bx - m2.vx*by - m1.vy*bx + m1.vx*by) / RH;
	# aim at plane projected impact
	ptx := m3.x - m2.x;
	pty := m3.y - m2.y;
	d := math->sqrt(ptx*ptx + pty*pty);
	if(d < 0.001) d = 0.001;
	ux := ptx / d;
	uy := pty / d;
	v := (m2.vx*ux + m2.vy*uy) - (m3.vx*ux + m3.vy*uy);
	a := THRUST / (m1.mass + m2.mass);
	disc := v*v + 2.0*a*d;
	tcol := 0.0;
	if(disc > 0.0)
		tcol = (-v + math->sqrt(disc)) / a;
	dbg = tcol;
	# predicted plane pos
	predx := m3.x + m3.vx * tcol;
	predy := m3.y + m3.vy * tcol;
	aimx := predx - m2.x;
	aimy := predy - m2.y;
	tx = predx; ty = predy;
	thead := math->atan2(aimy, aimx);
	terr := wrapang(th - thead);
	want := clamp(50.0*dth + 750.0*terr, -PI/8.0, PI/8.0);
	# Nozzle servo: the original carries this pair as extra ODE state
	# integrated at h=1e-6 with the masses.  The servo is stiff
	# (omega ~ 100 rad/s), so a single 16ms Euler step oscillates;
	# sub-step at 0.5ms to keep explicit Euler stable and smooth.
	# One 16ms tick stands for 16 of the original's Sleep(1) 1ms ticks,
	# so real-time rates are preserved.
	for(i := 0; i < 32; i++){
		accn := clamp(10000.0*(want - nozzle), -1000.0, 1000.0) - 10.0*nozzle_v;
		nozzle_v += accn * 0.0005;
		nozzle += nozzle_v * 0.0005;
	}

	if(blastoff){
		ang := th + nozzle;
		m1.fx += THRUST * math->cos(ang);
		m1.fy += THRUST * math->sin(ang);
		# gravity (+y down): in TempleOS was -25 on DyDt with y-up → +25 here
		m1.fy += 25.0 * m1.mass;
		m2.fy += 25.0 * m2.mass;
	}
	ode->update(sim, 0.016);
}

w2s(x, y: real): Point
{
	img := win.image;
	cx := 320;
	cy := groundy;
	if(img != nil)
		cx = img.r.dx()/2;
	return Point(cx + int x, cy + int y);
}

readmask(m: ref Image): (array of byte, int, int)
{
	if(m == nil)
		return (nil, 0, 0);
	w := m.r.dx();
	h := m.r.dy();
	bpl := (w * m.depth + 7) / 8;
	b := array[bpl * h] of byte;
	if(m.readpixels(m.r, b) < 0)
		return (nil, 0, 0);
	return (b, bpl, m.depth);
}

maskbit(bits: array of byte, bpl, depth, u, v: int): int
{
	if(depth == 1)
		return (int bits[v*bpl + (u>>3)] & (16r80 >> (u&7))) != 0;
	return bits[v*bpl + u] != byte 0;
}

# ROP_COLLISION stand-in: count rotated-rocket-mask pixels that land on
# plane-mask pixels (the original counts non-LTCYAN pixels under the
# rocket sprite; the plane is what is there to hit).  Same threshold
# (>100) as the original.  Coordinates are window-relative (no origin).
collide(prc, p3: Point, cs, sn: real): int
{
	if(rbits == nil || pbits == nil || rocketmask == nil || planemask == nil)
		return -1;
	# quick reject: sprite half-diagonals are ~25 and ~29
	ddx := prc.x - p3.x;
	ddy := prc.y - p3.y;
	if(ddx*ddx + ddy*ddy > 60*60)
		return 0;
	riw := rocketmask.r.dx();
	rih := rocketmask.r.dy();
	pw := planemask.r.dx();
	ph := planemask.r.dy();
	pmin := planemask.r.min;
	hx := real(riw-1) / 2.0;
	hy := real(rih-1) / 2.0;
	cnt := 0;
	for(v := 0; v < rih; v++)
		for(u := 0; u < riw; u++){
			if(!maskbit(rbits, rbpl, rdepth, u, v))
				continue;
			lx := real u - hx;
			ly := real v - hy;
			sx := prc.x + int (lx*cs - ly*sn);
			sy := prc.y + int (lx*sn + ly*cs);
			pu := sx - (p3.x + pmin.x);
			pv := sy - (p3.y + pmin.y);
			if(pu < 0 || pu >= pw || pv < 0 || pv >= ph)
				continue;
			if(maskbit(pbits, pbpl, pdepth, pu, pv))
				cnt++;
		}
	return cnt;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	# GROUND_Y = GR_HEIGHT - 3*FONT_HEIGHT
	groundy = h - 24;
	frames++;
	d := win.display;
	if(bg == nil || bg.r.dx() != w || bg.r.dy() != h){
		chans := d.image.chans;
		bg = d.newimage(Rect((0, 0), (w, h)), chans, 0, palrgba[TLTCYAN]);
	}

	th := math->atan2(m2.y-m1.y, m2.x-m1.x);
	# nozzle exhaust point, 10 units behind the base
	nx := m1.x - 10.0*math->cos(th+nozzle);
	ny := m1.y - 10.0*math->sin(th+nozzle);

	# Persistent smoke onto the DCAlias stand-in: the original plots 10
	# random white/gray/black pixels per 30fps DrawIt; at ~60fps we plot
	# 5 to keep the same rate.
	if(blastoff && bg != nil && rand != nil){
		for(i := 0; i < 5; i++){
			c := TWHITE;
			case rand->rand(4) {
			1 =>	c = TLTGRAY;
			2 =>	c = TDKGRAY;
			3 =>	c = TBLACK;
			}
			p := w2s(nx + real(rand->rand(12)-6), ny + real(rand->rand(12)-6));
			bg.draw(Rect(p, p.add(Point(1, 1))), ink[c], nil, Point(0, 0));
		}
	}
	if(bg != nil)
		img.draw(img.r, bg, nil, bg.r.min);
	else
		img.draw(img.r, ink[TLTCYAN], nil, Point(0, 0));

	p1 := w2s(m1.x, m1.y).add(o);
	p2 := w2s(m2.x, m2.y).add(o);
	p3 := w2s(m3.x, m3.y).add(o);
	pt := w2s(tx, ty).add(o);
	prc := Point((p1.x+p2.x)/2, (p1.y+p2.y)/2);

	# flame fan: 6 alternating yellow/red lines from the base arc to the
	# nozzle point; the original alternates on winmgr.updates (~30fps),
	# we alternate on frames>>1 for the same flicker rate
	if(blastoff){
		pn := w2s(nx, ny).add(o);
		for(i := 0; i < 6; i++){
			col := ink[TRED];
			if((i ^ (frames>>1)) & 1)
				col = ink[TYELLOW];
			fa := w2s(m1.x + real i*math->cos(th-PI/2.0),
				m1.y + real i*math->sin(th-PI/2.0)).add(o);
			fb := w2s(m1.x + real i*math->cos(th+PI/2.0),
				m1.y + real i*math->sin(th+PI/2.0)).add(o);
			img.line(fa, pn, 0, 0, 0, col, Point(0, 0));
			img.line(fb, pn, 0, 0, 0, col, Point(0, 0));
		}
	}

	# plane: sprite <1>, or damaged sprite <2> once hit
	spr := planespr;
	msk := planemask;
	if(planehit){
		spr = planehitspr;
		msk = planehitmask;
	}
	if(spr != nil)
		img.draw(spr.r.addpt(p3), spr, msk, spr.r.min);
	else{
		col := ink[TBLUE];
		if(planehit)
			col = ink[TRED];
		img.fillellipse(p3, 10, 4, col, Point(0, 0));
	}

	# collision test (the original does it here in DrawIt)
	if(blastoff && !planehit){
		cs := math->cos(th);
		sn := math->sin(th);
		cnt := collide(prc.sub(o), p3.sub(o), cs, sn);
		hit := 0;
		if(cnt < 0){
			# no masks: fall back to a center-distance test
			ddx := prc.x - p3.x;
			ddy := prc.y - p3.y;
			hit = ddx*ddx + ddy*ddy < 25*25;
		}else
			hit = cnt > 100;
		if(hit){
			planehit = 1;
			# Noise(1000, 62, 81): explosion
			noise_until = sys->millisec() + 1000;
		}
	}

	# ground strip, sprite <4> at (0, GROUND_Y)
	if(groundspr != nil)
		img.draw(groundspr.r.addpt(Point(o.x, o.y+groundy)),
			groundspr, groundmask, groundspr.r.min);
	else
		img.draw(Rect((o.x, o.y+groundy), (o.x+w, o.y+h)), ink[TGREEN], nil, Point(0, 0));

	# rocket, sprite <3> rotated by the body angle (art nose points +x;
	# sprite2d's positive degrees rotate clockwise in y-down screen space)
	if(rocketspr != nil && draw3d != nil)
		draw3d->sprite2d(img, prc, rocketspr, rocketmask,
			rocketspr.r.dx(), rocketspr.r.dy(), th*180.0/PI, 0);
	else{
		img.line(p1, p2, 0, 0, 2, ink[TBLACK], Point(0, 0));
		img.fillellipse(p1, 3, 3, ink[TBLACK], Point(0, 0));
		img.fillellipse(p2, 3, 3, ink[TRED], Point(0, 0));
	}

	img.ellipse(pt, 5, 5, 0, ink[TRED], Point(0, 0));
	img.ellipse(p3, 5, 5, 0, ink[TBLUE], Point(0, 0));

	# GrPrint(dc, 0, FONT_HEIGHT, "%12.6f", my_dbg)
	if(font != nil)
		img.text(o.add(Point(0, 8)), ink[TBLACK], Point(0, 0), font,
			sys->sprint("%12.6f", dbg));

	if(mode == Mprompt)
		drawprompt(img);

	sound();
	img.flush(Draw->Flushnow);
}

# "Anti-spin Coefficient" PopUpRangeF64Exp menu
promptbox(img: ref Image): Rect
{
	bw := 8*21 + 16;
	bh := 8*7 + 16;
	bx := img.r.min.x + (img.r.dx()-bw)/2;
	by := img.r.min.y + (img.r.dy()-bh)/2;
	return Rect((bx, by), (bx+bw, by+bh));
}

entryrect(r: Rect, j: int): Rect
{
	y := r.min.y + 8 + 16 + j*8;
	return Rect((r.min.x+8, y), (r.max.x-8, y+8));
}

entryat(p: Point): int
{
	img := win.image;
	if(img == nil)
		return -1;
	r := promptbox(img);
	for(j := 0; j < len vals; j++)
		if(entryrect(r, j).contains(p))
			return j;
	return -1;
}

drawprompt(img: ref Image)
{
	if(font == nil)
		return;
	r := promptbox(img);
	img.draw(r, ink[TWHITE], nil, Point(0, 0));
	img.border(r, 1, ink[TBLACK], Point(0, 0));
	img.text(r.min.add(Point(8, 8)), ink[TBLACK], Point(0, 0), font,
		"Anti-spin Coefficient");
	for(j := 0; j < len vals; j++){
		er := entryrect(r, j);
		col := TLTBLUE;
		if(j == sel){
			img.draw(er, ink[TLTBLUE], nil, Point(0, 0));
			col = TWHITE;
		}
		img.text(er.min, ink[col], Point(0, 0), font,
			sys->sprint("%9.4f", vals[j]));
	}
}

sound()
{
	if(!have_tone)
		return;
	if(noise_until != 0){
		if(sys->millisec() < noise_until){
			# Noise(1000,62,81): random pitch in the semitone band,
			# freq = 440*2^((ona-60)/12)
			ona := 62 + rand->rand(20);
			tone->snd(int (440.0 * math->pow(2.0, real(ona-60)/12.0)));
			sndon = -1;
			return;
		}
		noise_until = 0;
		tone->stop();
		sndon = 0;
	}
	if(blastoff && !planehit){
		# Snd(22): 440*2^((22-60)/12) ≈ 48.9 Hz, held while airborne
		if(sndon != 1){
			tone->snd(49);
			sndon = 1;
		}
	}else if(sndon){
		tone->stop();
		sndon = 0;
	}
}


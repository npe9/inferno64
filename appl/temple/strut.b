implement Strut;

# TempleOS Apps/Strut — ODE ship editor / thrusters.
# Faithful rebuild: opening help screen, cycling CCtrlBttn mode buttons
# (main Edit/Play centered at top; Mass/Spring/Connector/Thruster/Move at
# left while editing), original mass sprites (BI=1 first mass, BI=2 others)
# and the Sprite3ZB thruster nozzle (BI=3), mirrored random thruster flames,
# action-key digit labels, 8192-star parallax starfield, press-and-hold
# damping, and the animated 20-step zoom-to-cursor.
#
# Timing: the original integrates the CMathODE continuously in real time
# (h=1e-4) and winmgr refreshes at ~30fps.  Here one 16ms tick advances the
# ODE by 0.016s of wall time and redraws.  sim.h is 5e-4 rather than the
# original 1e-4: measured on this tree, RK4 at h=1e-4 costs 10.6ms/tick at
# 48 masses (overruns the 16ms budget with redraw); 5e-4 stays under 2.5ms
# and is numerically tight for these spring stiffnesses.  App forces
# (collisions, thrust) are computed once per tick, not per derivative
# evaluation as the original does.
#
# GAP: no TempleOS pull-down menu bar (File/Edit/Play/View); every menu
#   action is on its key or a mode button.  Shift-Esc (Abort) == Esc.
# GAP: Noise(250,18,46) is approximated by a single random-pitch beep in
#   the same semitone range rather than true white noise.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Font, Point, Rect: import draw;

include "math.m";
	math: Math;

include "tk.m";

include "keyboard.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "ode.m";
	ode: Ode;
	ODE, Mass, Spring: import ode;

include "tone.m";
	tone: Tone;

include "rand.m";
	rand: Rand;
include "grpalette.m";
	grpal: Grpalette;

Strut: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

RADIUS: con 7;
STARSNUM: con 8192;
ZOOMSTEPS: con 20;
MMD_EDIT, MMD_PLAY: con iota;
EMD_MASS, EMD_SPRING, EMD_CONNECTOR, EMD_THRUSTER, EMD_MOVE: con iota;

SSpring: adt {
	s:	ref Spring;
	typ:	int;	# EMD_*
	key:	int;	# '0'..'9'
};

win: ref Window;
sim: ref ODE;
ink: array of ref Image;
font: ref Font;
sprites, masks: array of ref Image;	# [1]=first mass, [2]=mass, [3]=nozzle
springs: list of ref SSpring;
mainmode := MMD_EDIT;
editmode := EMD_MASS;
nextkey := '1';
zoom := 1.0;
scrollx := 0.0;
scrolly := 0.0;
m0: ref Mass;		# first placed mass: camera follow, center, BI=1 sprite
sel: ref Mass;
down := 0;
down2 := 0;
consumed := 0;		# button-1 press landed on a mode button
mx, my: int;
held := array[10] of { * => 0 };
have_tone := 0;
help := 1;
lastnoise := -1000;
starsx := array[STARSNUM] of int;
starsy := array[STARSNUM] of int;
zoomch: chan of real;

# CCtrlBttn state texts and colors (palette indices), from Strut.HC
mainnames := array[] of {"Edit", "Play"};
maincols := array[] of {12, 10};		# LTRED, LTGREEN
editnames := array[] of {"Mass", "Spring", "Connector", "Thruster", "Move"};
editcols := array[] of {7, 11, 3, 14, 9};	# LTGRAY LTCYAN CYAN YELLOW LTBLUE

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	ode = load Ode Ode->PATH;
	tone = load Tone Tone->PATH;
	rand = load Rand Rand->PATH;
	if(ode == nil){
		sys->fprint(sys->fildes(2), "strut: no ode\n");
		raise "fail:load";
	}
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	ode->init();
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS Strut", Wmclient->Appl);
	d := win.display;
	ink = array[16] of ref Image;
	# the exact TempleOS 16-color palette, index = TempleOS color
	cols := grpal->values();
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "*default*");
	sprites = array[4] of ref Image;
	masks = array[4] of ref Image;
	for(i = 1; i <= 3; i++){
		sprites[i] = d.open(sys->sprint("/icons/temple/strut_%d.bit", i));
		masks[i] = d.open(sys->sprint("/icons/temple/strut_%d.mask", i));
	}

	reset();
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "keyup" :: "ptr" :: nil);

	zoomch = chan of real;
	ticks := chan of int;
	spawn timer(ticks, 16);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		ptr(p);
	k := <-win.ctxt.kbd =>
		key(k);
	f := <-zoomch =>
		# one step of the original's 20-step Zoom() task: keep the
		# world point under the mouse fixed while the scale changes
		(wx, wy) := s2w(real mx, real my);
		zoom *= f;
		if(zoom > 50.0) zoom = 50.0;
		if(zoom < 0.02) zoom = 0.02;
		scrollx = real mx - wx*zoom;
		scrolly = real my - wy*zoom;
		redraw();
	<-ticks =>
		if(mainmode == MMD_PLAY)
			breakconnectors();
		if(!sim.paused)
			step();
		redraw();
	}
}

reset()
{
	sim = ode->new();
	sim.accel_limit = 5000.0;
	sim.drag_v2 = 0.000002;
	sim.drag_v3 = 0.0000001;
	sim.h = 0.0005;		# see timing note in the header
	ode->pause(sim, 1);
	springs = nil;
	sel = nil;
	m0 = nil;
	zoom = 1.0;
	scrollx = scrolly = 0.0;
	nextkey = '1';
	# the original's Init(): 8192 stars fixed in world coords
	for(i := 0; i < STARSNUM; i++){
		starsx[i] = rn(8192) - 4096;
		starsy[i] = rn(8192) - 4096;
	}
}

# CCtrlBttn geometry: width 80, height 2 (BTTN_BORDER*4) + FONT_HEIGHT = 16.
# Main-mode button centered as (GR_WIDTH-4*FONT_WIDTH-16)>>1, y=FONT_HEIGHT+4;
# edit-mode button at (0, 5*FONT_HEIGHT+4).
mainbttnr(img: ref Image): Rect
{
	x := (img.r.dx() - 4*8 - 16) / 2;
	return Rect((x, 12), (x+80, 28));
}

editbttnr(): Rect
{
	return Rect((0, 44), (80, 60));
}

toggleplay()
{
	mainmode ^= 1;
	ode->pause(sim, mainmode == MMD_EDIT);
	if(mainmode == MMD_PLAY){
		sim.drag_v2 = 0.000002;
		sim.drag_v3 = 0.0000001;
	}
}

ptr(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil)
		return;
	sx := p.xy.x - img.r.min.x;
	sy := p.xy.y - img.r.min.y;
	mx = sx; my = sy;
	(wx, wy) := s2w(real sx, real sy);

	if(help)
		return;

	if(p.buttons & 2){
		if(!down2 && mainmode == MMD_EDIT)
			editmode = (editmode + 1) % 5;
		down2 = 1;
	}else
		down2 = 0;

	if(p.buttons & 1){
		if(!down){
			down = 1;
			consumed = 0;
			pt := Point(sx, sy);
			if(mainbttnr(img).contains(pt)){
				consumed = 1;
				toggleplay();
				return;
			}
			if(mainmode == MMD_EDIT && editbttnr().contains(pt)){
				consumed = 1;
				editmode = (editmode + 1) % 5;
				return;
			}
			if(mainmode != MMD_EDIT)
				return;
			case editmode {
			EMD_MASS =>
				placemass(wx, wy);
			EMD_SPRING or EMD_CONNECTOR or EMD_THRUSTER or EMD_MOVE =>
				sel = ode->massfind(sim, wx, wy, 0.0);
			}
		}else if(!consumed && mainmode == MMD_EDIT &&
		    editmode == EMD_MOVE && sel != nil){
			sel.x = wx; sel.y = wy; sel.vx = sel.vy = 0.0;
			nullsprings();
		}
	}else{
		if(down && !consumed && mainmode == MMD_EDIT && sel != nil &&
		   (editmode == EMD_SPRING || editmode == EMD_CONNECTOR || editmode == EMD_THRUSTER)){
			m2 := ode->massfind(sim, wx, wy, 0.0);
			if(m2 != nil && m2 != sel)
				placespring(sel, m2, editmode);
		}
		down = 0;
		consumed = 0;
		sel = nil;
	}
}

# original S2W/W2S: screen = world*zoom + task scroll; DrawIt re-centers
# the scroll on the first mass each frame when one exists
s2w(sx, sy: real): (real, real)
{
	return ((sx - scrollx)/zoom, (sy - scrolly)/zoom);
}

w2s(wx, wy: real): Point
{
	return Point(int(wx*zoom + scrollx), int(wy*zoom + scrolly));
}

placemass(x, y: real)
{
	m := ref Mass(x, y, 0.0, 0.0,0.0,0.0, 0.0,0.0,0.0, 1.0, 100.0, 0, 0, real RADIUS, 2);
	if(m0 == nil){
		m0 = m;		# first mass gets the distinct BI=1 sprite
		m.userdata = 1;
	}
	ode->addmass(sim, m);
}

placespring(a, b: ref Mass, typ: int)
{
	d := dist(a, b);
	if(d < 1.0)
		d = 1.0;
	c := 2500000.0 / (d*d);
	if(typ == EMD_THRUSTER)
		c = 0.0;
	s := ref Spring(a, b, c, d, 0.0, 0.0, 0, 0, 0);
	ode->addspring(sim, s);
	springs = ref SSpring(s, typ, nextkey) :: springs;
}

dist(a, b: ref Mass): real
{
	dx := a.x-b.x; dy := a.y-b.y;
	return math->sqrt(dx*dx+dy*dy);
}

nullsprings()
{
	for(l := springs; l != nil; l = tl l){
		ss := hd l;
		ss.s.restlen = dist(ss.s.end1, ss.s.end2);
	}
}

key(k: int)
{
	if(help){
		# PressAKey: any key-down dismisses the instruction screen
		if((k & Keyboard->Keyup) != Keyboard->Keyup)
			help = 0;
		return;
	}
	case k {
	16r1b or 'q' or 'Q' =>
		exit;
	' ' =>
		toggleplay();
	'\n' =>
		if(mainmode == MMD_EDIT)	# Restart is an Edit-menu action
			reset();
	'm' =>
		if(mainmode == MMD_EDIT) editmode = EMD_MASS;
	's' =>
		if(mainmode == MMD_EDIT) editmode = EMD_SPRING;
	'n' =>
		if(mainmode == MMD_EDIT) editmode = EMD_CONNECTOR;
	't' =>
		if(mainmode == MMD_EDIT) editmode = EMD_THRUSTER;
	'v' =>
		if(mainmode == MMD_EDIT) editmode = EMD_MOVE;
	'c' =>
		centermasses();
	'd' =>
		# press-and-hold damping; in edit it also un-pauses the ODE
		# so the ship settles while held
		if(mainmode == MMD_EDIT)
			ode->pause(sim, 0);
		sim.drag_v2 = 0.002;
		sim.drag_v3 = 0.0001;
	Keyboard->Keyup | 'd' =>
		if(mainmode == MMD_EDIT)
			ode->pause(sim, 1);
		sim.drag_v2 = 0.000002;
		sim.drag_v3 = 0.0000001;
	'z' =>
		spawn zoomer(2.0);
	'Z' =>
		spawn zoomer(0.5);
	'0' to '9' =>
		held[k-'0'] = 1;
		if(mainmode == MMD_EDIT)
			nextkey = k;
		else{
			# Noise(250,18,46), rate-limited to one per 0.25s.
			# SE_NOISE picks ona = Rand%(ona2-ona1) + ona1, i.e.
			# 18..45; Ona2Freq is 440/32*2^(ona/12), so ona 60
			# is 440Hz (a 39..185Hz rumble here).
			now := sys->millisec();
			if(have_tone && now > lastnoise+250){
				ona := 18 + rn(28);
				freq := int(440.0 * math->pow(2.0, real(ona-60)/12.0));
				tone->beep(freq, 250);
				lastnoise = now;
			}
		}
	(Keyboard->Keyup | '0') to (Keyboard->Keyup | '9') =>
		held[(k & 16r7ff)-'0'] = 0;
	}
}

# the original's Zoom() task: 20 steps of d^(1/20), 10ms apart
zoomer(d: real)
{
	f := math->exp(math->log(d) / real ZOOMSTEPS);
	for(i := 0; i < ZOOMSTEPS; i++){
		sys->sleep(10);
		zoomch <-= f;
	}
}

centermasses()
{
	if(m0 == nil)
		return;
	ox := m0.x; oy := m0.y;
	for(l := sim.masses; l != nil; l = tl l){
		m := hd l;
		m.x -= ox; m.y -= oy;
	}
}

breakconnectors()
{
	nl: list of ref SSpring;
	for(l := springs; l != nil; l = tl l){
		ss := hd l;
		if(ss.typ == EMD_CONNECTOR && ss.key >= '0' && ss.key <= '9' &&
		   held[ss.key-'0']){
			ode->remspring(sim, ss.s);
		}else
			nl = ss :: nl;
	}
	springs = nl;
}

step()
{
	ode->clearforces(sim);
	# soft collisions: force = 10*((2R)^2 - dd)^4 (MyDerivative)
	for(l1 := sim.masses; l1 != nil; l1 = tl l1){
		m1 := hd l1;
		for(l2 := tl l1; l2 != nil; l2 = tl l2){
			m2 := hd l2;
			dx := m2.x - m1.x;
			dy := m2.y - m1.y;
			dd := dx*dx + dy*dy;
			rr := real(2*RADIUS);
			if(dd <= rr*rr){
				d := math->sqrt(dd) + 0.0001;
				gap := rr*rr - dd;
				g2 := gap*gap;
				force := 10.0 * g2*g2;
				s := force / d;
				m2.fx += dx*s; m2.fy += dy*s;
				m1.fx -= dx*s; m1.fy -= dy*s;
			}
		}
	}
	# thrusters fire only during play (MyDerivative checks MMD_PLAY)
	if(mainmode == MMD_PLAY){
		for(l := springs; l != nil; l = tl l){
			ss := hd l;
			if(ss.typ == EMD_THRUSTER && ss.key >= '0' && ss.key <= '9' &&
			   held[ss.key-'0']){
				dx := ss.s.end2.x - ss.s.end1.x;
				dy := ss.s.end2.y - ss.s.end1.y;
				d := math->sqrt(dx*dx + dy*dy);
				if(d > 0.0){
					ss.s.end1.fx += 2000.0 * dx / d;
					ss.s.end1.fy += 2000.0 * dy / d;
				}
			}
		}
	}
	ode->update(sim, 0.016);
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	if(help){
		drawhelp(img);
		return;
	}
	# camera: DrawIt re-centers the scroll on the first mass each frame
	if(m0 != nil){
		scrollx = real(img.r.dx()/2) - m0.x*zoom;
		scrolly = real(img.r.dy()/2) - m0.y*zoom;
	}
	bg := ink[8];		# DKGRAY doc background in edit
	if(mainmode == MMD_PLAY)
		bg = ink[0];
	img.draw(img.r, bg, nil, Point(0, 0));
	o := img.r.min;
	w := img.r.dx(); h := img.r.dy();

	if(mainmode == MMD_PLAY){
		# 8192 stars fixed in world space: stable, parallax with zoom
		for(i := 0; i < STARSNUM; i++){
			p := w2s(real starsx[i], real starsy[i]);
			if(p.x >= 0 && p.x < w && p.y >= 0 && p.y < h)
				img.draw(Rect((o.x+p.x, o.y+p.y), (o.x+p.x+1, o.y+p.y+1)),
					ink[15], nil, Point(0, 0));
		}
	}

	# pending action key at text cell (11,7) in connector/thruster modes
	if(mainmode == MMD_EDIT && font != nil){
		if(editmode == EMD_CONNECTOR)
			img.text(Point(o.x+88, o.y+56), ink[3], Point(0, 0), font,
				sys->sprint("%c", nextkey));
		else if(editmode == EMD_THRUSTER)
			img.text(Point(o.x+88, o.y+56), ink[14], Point(0, 0), font,
				sys->sprint("%c", nextkey));
	}

	# springs LTCYAN, connectors CYAN; thrusters draw no line
	for(l := springs; l != nil; l = tl l){
		ss := hd l;
		if(ss.typ != EMD_SPRING && ss.typ != EMD_CONNECTOR)
			continue;
		p1 := w2s(ss.s.end1.x, ss.s.end1.y).add(o);
		p2 := w2s(ss.s.end2.x, ss.s.end2.y).add(o);
		col := ink[11];
		if(ss.typ == EMD_CONNECTOR)
			col = ink[3];
		img.line(p1, p2, 0, 0, 0, col, Point(0, 0));
	}

	# masses: BI=1 sprite for the first, BI=2 for the rest
	for(lm := sim.masses; lm != nil; lm = tl lm){
		m := hd lm;
		p := w2s(m.x, m.y).add(o);
		si := m.userdata;
		if(si >= 1 && si <= 3 && sprites[si] != nil){
			spr := sprites[si];
			img.draw(spr.r.addpt(p), spr, masks[si], spr.r.min);
		}else{
			r := int(real RADIUS * zoom);
			if(r < 2) r = 2;
			img.fillellipse(p, r, r, ink[7], Point(0, 0));
			img.ellipse(p, r, r, 0, ink[15], Point(0, 0));
		}
	}

	# thrusters: flames while held, nozzle sprite, action-key digits
	for(l = springs; l != nil; l = tl l){
		ss := hd l;
		x1 := ss.s.end1.x; y1 := ss.s.end1.y;
		x2 := ss.s.end2.x; y2 := ss.s.end2.y;
		if(ss.typ == EMD_THRUSTER){
			th := 0.0;
			if(x2 != x1 || y2 != y1)
				th = math->atan2(y2-y1, x2-x1);
			ct := math->cos(th); st := math->sin(th);
			if(ss.key >= '0' && ss.key <= '9' && held[ss.key-'0']){
				# 8 random flame line pairs, mirrored about the
				# nozzle axis (DCF_SYMMETRY)
				for(i := 0; i < 8; i++){
					d := 20.0*frand() + 6.0;
					col := ink[14];		# YELLOW
					if(d < 10.0)
						col = ink[1];	# BLUE
					else if(d < 16.0)
						col = ink[9];	# LTBLUE
					a := w2s(x1 - 3.0*ct, y1 - 3.0*st).add(o);
					b := w2s(x1 - 2.0*d*ct, y1 - 2.0*d*st).add(o);
					e1 := w2s(x1 - d*ct + 0.5*d*st, y1 - d*st - 0.5*d*ct).add(o);
					e2 := w2s(x1 - d*ct - 0.5*d*st, y1 - d*st + 0.5*d*ct).add(o);
					img.line(a, e1, 0, 0, 0, col, Point(0, 0));
					img.line(b, e1, 0, 0, 0, col, Point(0, 0));
					img.line(a, e2, 0, 0, 0, col, Point(0, 0));
					img.line(b, e2, 0, 0, 0, col, Point(0, 0));
				}
			}
			# Sprite3ZB nozzle at end1
			if(sprites[3] != nil){
				p := w2s(x1, y1).add(o);
				spr := sprites[3];
				img.draw(spr.r.addpt(p), spr, masks[3], spr.r.min);
			}
			if(zoom > 0.5 && font != nil){
				p := w2s((x1*7.0+x2)/8.0, (y1*7.0+y2)/8.0).add(o);
				img.text(p, ink[14], Point(0, 0), font,
					sys->sprint("%c", ss.key));
			}
		}else if(ss.typ == EMD_CONNECTOR && zoom > 0.5 && font != nil){
			p := w2s((x1*7.0+x2)/8.0, (y1*7.0+y2)/8.0).add(o);
			img.text(p, ink[3], Point(0, 0), font,
				sys->sprint("%c", ss.key));
		}
	}

	# mode buttons on top (winmgr draws ctrls over the doc)
	drawbttn(img, mainbttnr(img), mainnames, maincols, mainmode);
	if(mainmode == MMD_EDIT)
		drawbttn(img, editbttnr(), editnames, editcols, editmode);
	img.flush(Draw->Flushnow);
}

# DrawCtrlBttn: black frame, inner rect in the state's color, state text
# centered in the complementary color (color ^ WHITE)
drawbttn(img: ref Image, r: Rect, names: array of string, cols: array of int, state: int)
{
	o := img.r.min;
	rr := r.addpt(o);
	img.draw(rr, ink[0], nil, Point(0, 0));
	inner := Rect((rr.min.x+2, rr.min.y+2), (rr.max.x-2, rr.max.y-2));
	img.draw(inner, ink[cols[state]], nil, Point(0, 0));
	if(font == nil)
		return;
	s := names[state];
	tx := (r.min.x + r.max.x - (len s)*8) / 2;
	ty := (r.min.y + r.max.y - 8) / 2;
	img.text(Point(o.x+tx, o.y+ty), ink[cols[state]^15], Point(0, 0), font, s);
}

# the Strut() opening instruction screen: black text on the default white
# doc, the centered purple banner, green key highlights, then PressAKey
drawhelp(img: ref Image)
{
	img.draw(img.r, ink[15], nil, Point(0, 0));
	if(font == nil){
		img.flush(Draw->Flushnow);
		return;
	}
	w := img.r.dx();

	banner := "Build a ship.";
	tx := (w - (len banner)*8) / 2;
	txtat(img, tx/8, 1, 5, banner);	# PURPLE, $TX+CX$ centered

	c := txtat(img, 0, 3, 0, "Sel mass mode.");
	txtat(img, 16, 3, 0, "Left-click to place masses.");
	c = txtat(img, 0, 4, 0, "Sel spring mode.");
	txtat(img, 24, 4, 0, "Left-drag to make members.");
	c = txtat(img, 0, 5, 0, "Sel thruster mode.");
	txtat(img, 24, 5, 0, "Press a digit, 0-9.Drag to make thruster.");
	c = txtat(img, 0, 6, 0, "Sel connector mode.");
	txtat(img, 24, 6, 0, "Press a digit, 0-9.Drag to make breakable connector.");

	c = txtat(img, 0, 8, 0, "Press ");
	c = txtat(img, c, 8, 2, "<SPACE>");
	txtat(img, c, 8, 0, " to run the game.Press digits to operate thrusters and break");
	txtat(img, 0, 9, 0, "connectors.");

	c = txtat(img, 0, 11, 0, "Press ");
	c = txtat(img, c, 11, 2, "<z>");
	c = txtat(img, c, 11, 0, " or ");
	c = txtat(img, c, 11, 2, "<SHIFT-Z>");
	txtat(img, c, 11, 0, " to zoom in/out.");
	img.flush(Draw->Flushnow);
}

# draw s at 8x8 text cell (col,row) in palette color ci; returns next col
txtat(img: ref Image, col, row, ci: int, s: string): int
{
	o := img.r.min;
	img.text(Point(o.x + col*8, o.y + row*8), ink[ci], Point(0, 0), font, s);
	return col + len s;
}

frand(): real
{
	return real rn(65536) / 65536.0;
}

rn(n: int): int
{
	if(n <= 0) return 0;
	if(rand == nil) return sys->millisec() % n;
	return rand->rand(n);
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}

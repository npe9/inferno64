implement Blackdiamond;

# TempleOS Demo/Games/BlackDiamond.HC — ski downhill, avoid obstacles.
#
# Original timing: main loop Sleep(1ms jiffies)*10 per tick (y+=2, scrn_top++,
# keys), winmgr calls DrawIt at ~30fps (near-pass draw, ROP_COLLISION test,
# Snd/penalty, wolf movement, main pass, chair-lift wire, HUD).  Here the same
# structure: a 10ms game tick, redraw (with everything DrawIt did) every 3rd
# tick (~30fps).  The scroll catch-up and space-rewind animations run at the
# original's 2px/ms and 4px/ms rates via 1ms substeps.
#
# GAP: no TempleOS menu bar (every entry has its key equivalent; Shift-Esc
# Abort behaves like Esc Exit, as in the original where both reach bd_done).

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
include "frameclock.m";
	fclock: Frameclock;

Blackdiamond: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# The port's own simulation step, in milliseconds.  The frame clock
# runs at 60fps and this many milliseconds of simulation are run for
# each frame's worth of real time, so the picture is smooth and the
# simulation keeps the speed it was written for.
FCSTEP: con 10;
# The most substeps one frame may run: enough to cover a frame of
# real time at this step, with headroom.  A fixed cap is wrong -
# four substeps covers 40ms at FCSTEP 10 and only 4ms at FCSTEP 1.
FCMAX: con 2 + 20/FCSTEP;
fcacc := 0;

MAPHT: con 3000;	# MAP_HEIGHT
OBJN: con 128;		# OBJS_NUM
W: con 640;
H: con 480;

T_TREE: con 0;
T_ROCK: con 1;		# T_LITTLE_ROCK
T_BIG: con 2;		# T_BIG_ROCK
T_WOLF: con 3;
T_LIFT: con 4;		# T_CHAIR_LIFT

# DrawRunningWolf's private DC: bottom rows clip so the wolf sinks into snow
DCW: con 48;		# DC_WOLF_WIDTH
DCH: con 38;		# DC_WOLF_HEIGHT
ANCH: con 32;		# 0.85*DC_WOLF_HEIGHT, the sprite anchor row in the DC

WIREHT: con 595;	# WIRE_HEIGHT
WIREW: con 121;		# WIRE_WIDTH
WIREDIP: con 800;	# WIRE_DIP
PULLY: con 13;		# PULLY_WIDTH
WYMIN: con -64;		# prerendered wire strip, y range relative to wire anchor
WYMAX: con 120;

SND58: con 392;		# Snd(58): 440*2^((58-60)/12) Hz, held while colliding
SNDBEEP: con 800;	# Beep() chirp, as in keepaway.b/tothefront.b

NB: con 17;		# rocking-angle buckets over [-0.4,0.4] rad
NV: con 4*NB;		# (frame 6/7) x (mirrored or not) x angle bucket

win: ref Window;
disp: ref Display;
font: ref Font;
black, white, red: ref Image;
have_tone := 0;
snd_on := 0;

sprites := array[10] of ref Image;	# by TempleOS bin number 1..9
masks := array[10] of ref Image;
covs := array[10] of array of byte;	# mask coverage for pixel collision
binum := array[] of {3, 4, 5, 6, 9};	# imgs[]: obj type -> bin number

# wolf frames 6/7 (+2: mirrored) as pixel buffers for Sprite3ZB-style rotation
wrect := array[4] of Rect;
wpix := array[4] of array of byte;
wcov := array[4] of array of byte;
# cache of rotated variants
wvimg := array[NV] of ref Image;
wvmask := array[NV] of ref Image;
wvrect := array[NV] of Rect;
wvcov := array[NV] of array of byte;
wvdone := array[NV] of int;
wfr := 0;	# this frame's wolf sprite (0 = bin 6, 1 = bin 7)
wb := NB/2;	# this frame's rocking-angle bucket

wiremask: ref Image;	# prerendered chair-lift cable (mask; drawn with black)

obj_x, obj_y, obj_type: array of int;
obj_saved_x, obj_saved_y: array of int;
px, py, scrn_top: int;
penalty := 0;
best_score: int;
game_over := 0;
lift_idx := 0;
frame := 0;

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
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS BlackDiamond", Wmclient->Appl);
	disp = win.display;
	font = Font.open(disp, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(disp, "/fonts/lucida/unicode.8.font");
	black = disp.color(Draw->Black);
	white = disp.color(Draw->White);
	red = disp.color(grpal->value(Grpalette->RED));	# TempleOS RED
	for(n := 1; n <= 9; n++){
		sprites[n] = disp.open(sys->sprint("/icons/temple/blackdiamond_%d.bit", n));
		masks[n] = disp.open(sys->sprint("/icons/temple/blackdiamond_%d.mask", n));
	}
	# coverage buffers for the ROP_COLLISION-equivalent overlap test
	covs[1] = getcov(sprites[1], masks[1]);
	covs[3] = getcov(sprites[3], masks[3]);
	covs[4] = getcov(sprites[4], masks[4]);
	covs[5] = getcov(sprites[5], masks[5]);
	covs[6] = getcov(sprites[6], masks[6]);
	covs[9] = getcov(sprites[9], masks[9]);
	loadwolves();
	best_score = 9999;
	if(scorestore != nil)
		best_score = scorestore->loadint("blackdiamond", best_score);
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
	redraw();

	ticks := chan of int;
	spawn fclock->ticker(ticks, 60);
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
		'\n' =>
			# New: a fresh random course, any time
			layout_objects();
			game_init();
		' ' or 'r' or 'R' =>
			rewind();
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
		Keyboard->Up =>
			if(!game_over)
				py -= 10;
		Keyboard->Down =>
			if(!game_over)
				py += 10;
		}
	dtms := <-ticks =>
		fcacc += dtms;
		if(fcacc > FCSTEP*FCMAX)
			fcacc = FCSTEP*FCMAX;
		for(fcn := 0; fcacc >= FCSTEP && fcn < FCMAX; fcn++){
			if(!game_over)
				step();
			frame++;
			fcacc -= FCSTEP;
		}
		# It used to draw every third 10ms tick, which is the 30fps the
		# original's winmgr managed; now every frame.
		redraw();
	}
}

layout_objects()
{
	for(i := 0; i < OBJN; i++){
		obj_saved_y[i] = rn(MAPHT);
		obj_saved_x[i] = rn(W);
		j := rn(65536);
		if(j & 7)
			obj_type[i] = T_TREE;
		else if(j & 31)
			obj_type[i] = T_ROCK;
		else if(j & 63)
			obj_type[i] = T_BIG;
		else
			obj_type[i] = T_WOLF;
	}
	# original QSorts saved y ascending: the main draw pass walks the list in
	# order and inserts the man at his own y (associations broken, doesn't matter)
	for(i = 1; i < OBJN; i++){
		v := obj_saved_y[i];
		k := i - 1;
		while(k >= 0 && obj_saved_y[k] > v){
			obj_saved_y[k+1] = obj_saved_y[k];
			k--;
		}
		obj_saved_y[k+1] = v;
	}
	lift_idx = rn(OBJN);
	obj_type[lift_idx] = T_LIFT;
	buildwire();
}

game_init()
{
	for(i := 0; i < OBJN; i++){	# wolves move; reset from saved
		obj_x[i] = obj_saved_x[i];
		obj_y[i] = obj_saved_y[i];
	}
	px = W / 2;
	py = 0;
	scrn_top = 0;
	penalty = 0;
	game_over = 0;
	if(snd_on){
		tone->stop();
		snd_on = 0;
	}
}

step()
{
	py += 2;
	scrn_top++;
	if(py - scrn_top > H){
		# original animates the catch-up at scrn_top+=2 per 1ms Sleep
		while(py - scrn_top > H/2){
			scrn_top += 20;
			if(py - scrn_top < H/2)
				scrn_top = py - H/2;
			redraw();
			sys->sleep(10);
		}
	}
	if(py >= MAPHT){
		game_over = 1;
		if(snd_on){
			tone->stop();
			snd_on = 0;
		}
		newbest := 0;
		if(penalty <= best_score){
			best_score = penalty;
			if(scorestore != nil)
				scorestore->saveint("blackdiamond", best_score);
			newbest = 1;
		}
		if(have_tone)
			spawn finishbeeps(newbest);
	}
}

# space: give up — animate back to the top (4px/ms, x drifting 1px/ms toward
# centre, as the original's 1ms Sleep loop), then restart the same course
rewind()
{
	game_over = 1;
	if(snd_on){
		tone->stop();
		snd_on = 0;
	}
	while(scrn_top > 0 || py > 0){
		for(k := 0; k < 10; k++){
			scrn_top -= 4;
			if(scrn_top < 0) scrn_top = 0;
			py -= 4;
			if(py < 0) py = 0;
			px += sign(W/2 - px);
		}
		redraw();
		sys->sleep(10);
	}
	game_init();
}

finishbeeps(newbest: int)
{
	tone->beep(SNDBEEP, 250);
	if(newbest){
		sys->sleep(350);
		tone->beep(SNDBEEP, 250);
	}
}

# coverage (0/255 per pixel) of a sprite's k1 mask, for the software
# replica of the original's ROP_COLLISION sprite-overlap test
getcov(img, msk: ref Image): array of byte
{
	if(img == nil)
		return nil;
	n := img.r.dx() * img.r.dy();
	cov := array[n] of { * => byte 255 };
	if(msk != nil){
		tmp := disp.newimage(img.r, Draw->GREY8, 0, Draw->Black);
		if(tmp != nil){
			tmp.draw(img.r, white, msk, img.r.min);
			tmp.readpixels(img.r, cov);
		}
	}
	return cov;
}

loadwolves()
{
	for(f := 0; f < 2; f++){
		img := sprites[6+f];
		if(img == nil)
			continue;
		sw := img.r.dx();
		sh := img.r.dy();
		pix := array[sw*sh] of byte;
		if(img.readpixels(img.r, pix) < 0)
			continue;
		cov := getcov(img, masks[6+f]);
		if(cov == nil)
			continue;
		wrect[f] = img.r;
		wpix[f] = pix;
		wcov[f] = cov;
		# mirrored about the sprite origin (DCF_JUST_MIRROR about the DC centre)
		mpix := array[sw*sh] of byte;
		mcov := array[sw*sh] of byte;
		for(y := 0; y < sh; y++)
			for(x := 0; x < sw; x++){
				mpix[y*sw + (sw-1-x)] = pix[y*sw + x];
				mcov[y*sw + (sw-1-x)] = cov[y*sw + x];
			}
		wrect[2+f] = Rect((-(img.r.max.x-1), img.r.min.y), (-img.r.min.x+1, img.r.max.y));
		wpix[2+f] = mpix;
		wcov[2+f] = mcov;
	}
}

# rotate a pixel buffer by ang around the sprite origin, matching TempleOS
# Sprite3ZB (screen coords, y down); adapted from titanium.b's rotspr
rotbuf(sr: Rect, pix, cov: array of byte, ang: real): (ref Image, ref Image, Rect, array of byte)
{
	c := math->cos(ang);
	s := math->sin(ang);
	minx := miny := 16r7fffffff;
	maxx := maxy := -16r7fffffff;
	for(cy := 0; cy < 2; cy++) for(cx := 0; cx < 2; cx++){
		x := real sr.min.x;
		if(cx)
			x = real sr.max.x;
		y := real sr.min.y;
		if(cy)
			y = real sr.max.y;
		fx := int math->floor(x*c - y*s);
		fy := int math->floor(x*s + y*c);
		if(fx < minx) minx = fx;
		if(fx+1 > maxx) maxx = fx+1;
		if(fy < miny) miny = fy;
		if(fy+1 > maxy) maxy = fy+1;
	}
	dr := Rect((minx-1, miny-1), (maxx+1, maxy+1));
	dw := dr.dx();
	dh := dr.dy();
	sw := sr.dx();
	dpix := array[dw*dh] of { * => byte 0 };
	dcov := array[dw*dh] of { * => byte 0 };
	for(dy := 0; dy < dh; dy++) for(dx := 0; dx < dw; dx++){
		xx := real (dr.min.x+dx);
		yy := real (dr.min.y+dy);
		sx := int (xx*c + yy*s);	# inverse rotation; int rounds
		sy := int (-xx*s + yy*c);
		if(sx < sr.min.x || sx >= sr.max.x || sy < sr.min.y || sy >= sr.max.y)
			continue;
		si := (sy-sr.min.y)*sw + (sx-sr.min.x);
		if(int cov[si] > 127){
			dpix[dy*dw+dx] = pix[si];
			dcov[dy*dw+dx] = byte 255;
		}
	}
	nimg := disp.newimage(dr, Draw->CMAP8, 0, Draw->Black);
	nmask := disp.newimage(dr, Draw->GREY8, 0, Draw->Black);
	if(nimg == nil || nmask == nil)
		return (nil, nil, dr, nil);
	nimg.writepixels(dr, dpix);
	nmask.writepixels(dr, dcov);
	return (nimg, nmask, dr, dcov);
}

# this frame's wolf sprite, rocked by 0.4*Sin(7*tS) (quantized to NB angles)
# and mirrored when the man is to the wolf's left
getvariant(mir: int): (ref Image, ref Image, Rect, array of byte)
{
	src := wfr + 2*mir;
	k := src*NB + wb;
	if(!wvdone[k]){
		wvdone[k] = 1;
		if(wpix[src] != nil){
			ang := -0.4 + 0.8*real wb/real (NB-1);
			(wvimg[k], wvmask[k], wvrect[k], wvcov[k]) = rotbuf(wrect[src], wpix[src], wcov[src], ang);
		}
	}
	return (wvimg[k], wvmask[k], wvrect[k], wvcov[k]);
}

# prerender the chair-lift cable: a thick=2 double catenary spanning the
# screen, static per course (it depends only on the lift's x), blitted each
# frame at the scrolled y.  y1 = y-WIRE_DIP/2+Cosh(Ln(WIRE_DIP)+(|x1|-13)/1e4)+0.1*x1
buildwire()
{
	wiremask = nil;
	m := disp.newimage(Rect((0, WYMIN), (W, WYMAX)), Draw->GREY8, 0, Draw->Black);
	if(m == nil)
		return;
	lx := obj_saved_x[lift_idx];
	la := math->log(real WIREDIP);
	for(xs := -WIREW/2; xs < W + WIREW/2; xs += 2){
		x1 := xs - lx;
		if(x1 > -PULLY && x1 < PULLY)
			continue;	# gap at the pulley
		y1 := int (math->cosh(la + real (absi(x1)-PULLY)/10000.0) + 0.1*real x1 - real WIREDIP/2.0);
		m.draw(Rect((xs-WIREW/2, y1), (xs-WIREW/2+2, y1+2)), white, nil, Point(0, 0));
		m.draw(Rect((xs+WIREW/2, y1), (xs+WIREW/2+2, y1+2)), white, nil, Point(0, 0));
	}
	wiremask = m;
}

# software replica of the original's collision pass: redraw the man sprite in
# ROP_COLLISION over what the near pass drew and count overlapping mask pixels
hitcount(): int
{
	if(sprites[1] == nil || covs[1] == nil)
		return 0;
	mr := sprites[1].r.addpt(Point(px, py));
	n := 0;
	for(i := 0; i < OBJN; i++){
		if(!(obj_y[i]-32 <= py && py <= obj_y[i]))
			continue;
		if(obj_type[i] == T_WOLF && absi(px - obj_x[i]) > 3){
			mir := 0;
			if(px < obj_x[i])
				mir = 1;
			(nil, nil, vr, vcov) := getvariant(mir);
			if(vcov == nil)
				continue;
			br := vr.addpt(Point(obj_x[i], obj_y[i]));
			dcr := Rect((obj_x[i]-DCW/2, obj_y[i]-ANCH), (obj_x[i]+DCW/2, obj_y[i]-ANCH+DCH));
			n += covoverlap(mr, covs[1], br, vcov, dcr);
		} else {
			b := binum[obj_type[i]];
			if(sprites[b] == nil || covs[b] == nil)
				continue;
			br := sprites[b].r.addpt(Point(obj_x[i], obj_y[i]));
			n += covoverlap(mr, covs[1], br, covs[b], br);
		}
	}
	return n;
}

covoverlap(ar: Rect, acov: array of byte, br: Rect, bcov: array of byte, clip: Rect): int
{
	(ir, ok) := ar.clip(br);
	if(!ok)
		return 0;
	(ir, ok) = ir.clip(clip);
	if(!ok)
		return 0;
	aw := ar.dx();
	bw := br.dx();
	n := 0;
	for(y := ir.min.y; y < ir.max.y; y++){
		ai := (y-ar.min.y)*aw - ar.min.x;
		bi := (y-br.min.y)*bw - br.min.x;
		for(x := ir.min.x; x < ir.max.x; x++)
			if(int acov[ai+x] > 127 && int bcov[bi+x] > 127)
				n++;
	}
	return n;
}

drawspr(img: ref Image, o: Point, n, x, y: int)
{
	s := sprites[n];
	if(s == nil)
		return;
	img.draw(s.r.addpt(Point(o.x+x, o.y+y)), s, masks[n], s.r.min);
}

# DrawRunningWolf: alternate frames 6/7 every 0.5s, rocking, mirrored toward
# the man, drawn through a 48x38 DC so the bottom clips into the snow; moves
# the wolf 3px toward the man when on-screen (called from both draw passes,
# so a visible wolf closes up to 6px per frame, as in the original)
drawwolf(img: ref Image, o: Point, i: int)
{
	mir := 0;
	if(px < obj_x[i])
		mir = 1;
	(vi, vm, vr, nil) := getvariant(mir);
	oy := obj_y[i] - scrn_top;
	if(vi != nil){
		dst := vr.addpt(Point(o.x+obj_x[i], o.y+oy));
		dcr := Rect((o.x+obj_x[i]-DCW/2, o.y+oy-ANCH), (o.x+obj_x[i]+DCW/2, o.y+oy-ANCH+DCH));
		(cl, ok) := dst.clip(dcr);
		if(ok)
			img.draw(cl, vi, vm, Point(vr.min.x + cl.min.x - dst.min.x, vr.min.y + cl.min.y - dst.min.y));
	}
	if(oy >= 0 && oy < H)
		obj_x[i] += 3*sign(px - obj_x[i]);
}

drawobj(img: ref Image, o: Point, i: int)
{
	oy := obj_y[i] - scrn_top;
	if(oy < -650 || oy > H+80)	# cull: the draw would clip these anyway
		return;
	if(obj_type[i] == T_WOLF && absi(px - obj_x[i]) > 3)
		drawwolf(img, o, i);
	else
		drawspr(img, o, binum[obj_type[i]], obj_x[i], oy);
}

drawman(img: ref Image, o: Point, hit: int)
{
	n := 1;
	if(hit)
		n = 2;	# red man for exactly the colliding frames
	drawspr(img, o, n, px, py - scrn_top);
}

drawlift(img: ref Image, o: Point)
{
	wy := obj_y[lift_idx] - scrn_top - WIREHT;
	drawspr(img, o, 8, obj_x[lift_idx], wy+13);	# tower/pulley
	if(wiremask != nil && wy+WYMAX >= 0 && wy+WYMIN < H)
		img.draw(wiremask.r.addpt(Point(o.x, o.y+wy)), black, wiremask, wiremask.r.min);
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	ms := sys->millisec();
	wfr = 0;
	if(ms % 1000 >= 500)	# tS%1.0<0.5 picks frame 6, else 7
		wfr = 1;
	a := 0.4*math->sin(7.0*real ms/1000.0);
	wb = int ((a+0.4)/0.8*real (NB-1));
	if(wb < 0) wb = 0;
	if(wb > NB-1) wb = NB-1;

	img.draw(img.r, white, nil, Point(0, 0));	# DCFill: white snow
	o := img.r.min;

	# near pass: objects at/just below the man, then the collision test
	for(i := 0; i < OBJN; i++)
		if(obj_y[i]-32 <= py && py <= obj_y[i])
			drawobj(img, o, i);
	hitcnt := hitcount();
	if(!game_over){
		if(hitcnt){
			penalty++;	# time is irregular; scoring is imperfect, ~30fps
			if(have_tone && !snd_on){
				tone->snd(SND58);	# held while overlapping
				snd_on = 1;
			}
		} else if(snd_on){
			tone->stop();
			snd_on = 0;
		}
	}

	# main pass: every object in ascending y, the man inserted at his own y
	man_drawn := 0;
	for(i = 0; i < OBJN; i++){
		if(!man_drawn && obj_y[i] >= py){
			drawman(img, o, hitcnt);
			man_drawn = 1;
		}
		drawobj(img, o, i);
	}
	if(!man_drawn)
		drawman(img, o, hitcnt);
	drawlift(img, o);

	if(font != nil){
		msg := sys->sprint("Penalty:%d Best:%d", penalty, best_score);
		img.text(Point(o.x, o.y), black, Point(0, 0), font, msg);
		if(game_over && (ms/200) % 2 == 0)
			img.text(Point(o.x+(W-9*8)/2, o.y+(H-8)/2), red, Point(0, 0), font, "Game Over");
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


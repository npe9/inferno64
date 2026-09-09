implement Stadium;

# TempleOS Demo/Games/Stadium/Stadium.HC — peg wandering fans
# LMB throw ball; Enter restart; Esc/q quit
# Background is GRRead("StadiumBG") — the StadiumGen.HC screen capture of
# StadiumBG.DD — rasterized at icons/temple/stadium_bg.bit.  Fans are the
# BI=1 vector sprite (lib/temple/sprites/stadium_1.spr) drawn rotated by
# each fan's wander angle, as Sprite3ZB does; the ball is the BI=2 bitmap
# sprite spun by t0 and scaled by 1.5-t0 (the original's Mat4x4Scale DC
# transform), rendered by inverse-mapping into an RGBA buffer.
# GAP: the MenuPush pull-down (File Abort/Exit; Play Restart) has no wm
#      equivalent; its key bindings (Esc exit, Enter restart) are wired.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Font, Point, Rect: import draw;

include "math.m";
	math: Math;

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "rand.m";
	rand: Rand;
include "grpalette.m";
	grpal: Grpalette;
include "math/vsprite.m";
	vspr: Vsprite;
	Sprite: import vspr;
include "frameclock.m";
	fclock: Frameclock;

Stadium: module
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

FANS: con 10;
BALL_MS: con 200;	# BALL_TIME 0.2s

# the exact TempleOS 16-color palette, index = TempleOS color number
palette: array of int;
BLACK: con 0;
RED: con 4;

win: ref Window;
pal: array of ref Image;	# the 16 palette colors
black: ref Image;
tfont: ref Font;
bg: ref Image;			# StadiumBG capture, 640x472 at (0,0)
# The fan is a vector sprite, and vsprite(2) draws it: the element list
# read once, turned by the fan's wander angle, and rasterised.  The port
# used to walk the list itself and draw each line through draw(2), which
# was a third rasteriser for a format that already has one, and did not
# give the same pixels as the .bit beside the .spr.
#
# A wandering fan's angle only ever moves by 1/25 radian and is put back
# to 0 outside [-0.75, 0.75), so there are 39 of them and each raster is
# made once and kept - fewer lines drawn per frame than the walk it
# replaces.  A fan the ball knocks over is the exception: it is frozen at
# -Pi/2 and never passes that test again, so the cache is indexed over a
# range that reaches THAT too, and an angle outside the range is drawn
# without the cache rather than snapped to the nearest slot - snapping
# would have drawn a knocked-over fan nearly upright.
#
# Keying on the quantised angle alone is safe because no two angles this
# port can produce share a slot: the wander lands on multiples of 1/25
# inside +-0.75, and -Pi/2 quantises to -39.  Two fans nominally at the
# same wander angle can differ in the last bits, 1/25 not being exact in
# binary, and it would be wrong to treat that as a different pose.
fanspr: ref Sprite;
ASTEP: con 25.0;		# a wander step is 1/25 radian
KMIN: con -40;			# int(-Pi/2*ASTEP) is -39
KMAX: con 20;
NANG: con KMAX-KMIN;
fanimg, fanmsk: array of ref Image;
fanrect: array of Rect;

# ball bitmap sprite: palette indices, 16rFF transparent
ballpix: array of byte;
ballx0, bally0, ballw, ballh: int;
BALLR: con 30;			# max extent ~20px * max scale 1.5
ballimg: ref Image;		# RGBA scratch, (2*BALLR+1)^2
ballbuf: array of byte;

fx, fy, fang: array of real;
fhit: array of int;
ball_t := 0;
target_x, target_y: int;
pitcher_x, pitcher_y: int;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	palette = grpal->values();
	math = load Math Math->PATH;
	vspr = load Vsprite Vsprite->PATH;
	if(vspr == nil){
		sys->fprint(sys->fildes(2), "stadium: cannot load %s: %r\n",
			Vsprite->PATH);
		raise "fail:load";
	}
	vspr->init();
	bufio = load Bufio Bufio->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	fclock = load Frameclock Frameclock->PATH;
	fclock->init();
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS Stadium", Wmclient->Appl);
	d := win.display;
	pal = array[16] of ref Image;
	for(i := 0; i < 16; i++)
		pal[i] = d.color(palette[i]);
	black = pal[BLACK];
	tfont = Font.open(d, "/fonts/lucida/unicode.8.font");
	if(tfont == nil)
		tfont = Font.open(d, "*default*");
	bg = d.open("/icons/temple/stadium_bg.bit");
	(fanspr, nil) = vspr->read("/lib/temple/sprites/stadium_1.spr");
	fanimg = array[NANG] of ref Image;
	fanmsk = array[NANG] of ref Image;
	fanrect = array[NANG] of Rect;
	loadball("/lib/temple/sprites/stadium_2.spr");
	n := 2*BALLR + 1;
	ballimg = d.newimage(Rect((0, 0), (n, n)), Draw->RGBA32, 0, Draw->Transparent);
	ballbuf = array[n*n*4] of byte;
	fx = array[FANS] of real;
	fy = array[FANS] of real;
	fang = array[FANS] of real;
	fhit = array[FANS] of int;
	reset();
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn fclock->ticker(ticks, 60);	# 60fps: original AnimateTask: Sleep(10) — 10ms tick
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
			exit;
		'\n' =>
			reset();
		}
	dtms := <-ticks =>
		fcacc += dtms;
		if(fcacc > FCSTEP*FCMAX)
			fcacc = FCSTEP*FCMAX;
		for(fcn := 0; fcacc >= FCSTEP && fcn < FCMAX; fcn++){
			animate();
			fcacc -= FCSTEP;
		}
		redraw();
	}
}

reset()
{
	# original Init(): fans only; a ball in flight keeps flying
	img := win.image;
	w := 640;
	if(img != nil)
		w = img.r.dx();
	for(i := 0; i < FANS; i++){
		fx[i] = real rn(w);
		fy[i] = 50.0;
		fang[i] = 0.0;
		fhit[i] = 0;
	}
}

handleptr(p: ref Draw->Pointer)
{
	if((p.buttons & 1) == 0)
		return;
	img := win.image;
	if(img == nil)
		return;
	target_x = p.xy.x - img.r.min.x;
	target_y = p.xy.y - img.r.min.y;
	pitcher_x = img.r.dx() / 2;
	pitcher_y = img.r.dy();
	ball_t = sys->millisec();
}

animate()
{
	img := win.image;
	if(img == nil)
		return;
	w := img.r.dx();
	bx := 0.0; by := 0.0;
	have_ball := 0;
	if(ball_t != 0){
		t0 := real(sys->millisec() - ball_t) / real BALL_MS;
		if(t0 > 1.0)
			ball_t = 0;
		else{
			# hit test uses the true interpolated position
			# (the /=1.5-t0 in DrawIt only cancels the DC scale)
			have_ball = 1;
			bx = t0 * real target_x + (1.0 - t0) * real pitcher_x;
			by = t0 * real target_y + (1.0 - t0) * real pitcher_y;
		}
	}
	for(i := 0; i < FANS; i++){
		if(have_ball){
			dx := fx[i] - bx;
			dy := fy[i] - by;
			if(dx * dx + dy * dy < 200.0){
				# knocked flat on his side, frozen forever
				fhit[i] = 1;
				fang[i] = -Math->Pi / 2.0;
			}
		}
		if(!fhit[i]){
			# SignI64(RandI16): ±1 (0 only 1/65536)
			fx[i] += real sign(rn(65536) - 32768);
			fy[i] += real sign(rn(65536) - 32768);
			fang[i] += real sign(rn(65536) - 32768) / 25.0;
			if(fx[i] < 0.0 || fx[i] >= real w)
				fx[i] = real(w / 2);
			if(fy[i] < 10.0 || fy[i] >= 100.0)
				fy[i] = 50.0;
			if(fang[i] < -0.75 || fang[i] >= 0.75)
				fang[i] = 0.0;
		}
	}
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	# GrBlot(dc,0,0,background), DCF_NO_TRANSPARENTS — opaque blit
	bh := 0;
	if(bg != nil){
		img.draw(bg.r.addpt(o), bg, nil, bg.r.min);
		bh = bg.r.dy();
	}
	if(bh < h)
		img.draw(Rect((o.x, o.y + bh), (o.x + w, o.y + h)), black, nil, (0, 0));
	for(i := 0; i < FANS; i++)
		drawfan(img, o, int fx[i], int fy[i], fang[i]);
	if(ball_t != 0){
		t0 := real(sys->millisec() - ball_t) / real BALL_MS;
		if(t0 <= 1.0){
			bx := t0 * real target_x + (1.0 - t0) * real pitcher_x;
			by := t0 * real target_y + (1.0 - t0) * real pitcher_y;
			drawball(img, o, int bx, int by, t0);
		}
	}
	# GrPrint(dc,FONT_WIDTH,FONT_HEIGHT,"Peg the Fans") in RED
	if(tfont != nil)
		img.text(Point(o.x + 8, o.y + 8), pal[RED], (0, 0), tfont, "Peg the Fans");
	img.flush(Draw->Flushnow);
}

# Sprite3ZB: rotate the element list by ang about the sprite origin
# (Mat4x4RotZ: x' = x cos - y sin, y' = x sin + y cos), plot at (x,y).
# vsprite(2) does the turning and the drawing; this picks the raster.
drawfan(img: ref Image, o: Point, x, y: int, ang: real)
{
	if(fanspr == nil)
		return;
	k := int(ang*ASTEP) - KMIN;
	if(k >= 0 && k < NANG && fanimg[k] != nil){
		blitfan(img, o, x, y, fanimg[k], fanmsk[k], fanrect[k]);
		return;
	}
	(im, mk, r) := fanspr.transformed(ang*180.0/Math->Pi, 1.0).
		raster(win.display);
	if(im == nil)
		return;
	if(k >= 0 && k < NANG){
		fanimg[k] = im;
		fanmsk[k] = mk;
		fanrect[k] = r;
	}
	blitfan(img, o, x, y, im, mk, r);
}

blitfan(img: ref Image, o: Point, x, y: int, im, mk: ref Image, r: Rect)
{
	img.draw(Rect((o.x+x+r.min.x, o.y+y+r.min.y),
		(o.x+x+r.max.x, o.y+y+r.max.y)), im, mk, im.r.min);
}

# Sprite3ZB(...,"<ball>",t0) under Mat4x4Scale(1.5-t0): the bitmap spins
# by t0 and shrinks by 1.5-t0 about the sprite origin, centered at the
# true interpolated position.  Inverse-map dest pixels into the source.
drawball(img: ref Image, o: Point, x, y: int, t0: real)
{
	if(ballimg == nil || ballpix == nil)
		return;
	scale := 1.5 - t0;
	c := math->cos(t0);
	s := math->sin(t0);
	idx := 0;
	for(v := -BALLR; v <= BALLR; v++){
		for(u := -BALLR; u <= BALLR; u++){
			ux := real u / scale;
			vy := real v / scale;
			# rotate by -t0
			i := int(ux * c + vy * s) - ballx0;
			j := int(vy * c - ux * s) - bally0;
			pix := 16rFF;
			if(i >= 0 && i < ballw && j >= 0 && j < ballh)
				pix = int ballpix[j*ballw + i];
			if(pix != 16rFF){
				rgba := palette[pix & 15];
				ballbuf[idx] = byte (rgba >> 24);
				ballbuf[idx+1] = byte (rgba >> 16);
				ballbuf[idx+2] = byte (rgba >> 8);
				ballbuf[idx+3] = byte 16rFF;
			} else {
				ballbuf[idx] = byte 0;
				ballbuf[idx+1] = byte 0;
				ballbuf[idx+2] = byte 0;
				ballbuf[idx+3] = byte 0;
			}
			idx += 4;
		}
	}
	ballimg.writepixels(ballimg.r, ballbuf);
	img.draw(Rect((o.x + x - BALLR, o.y + y - BALLR),
		(o.x + x + BALLR + 1, o.y + y + BALLR + 1)),
		ballimg, nil, ballimg.r.min);
}

loadball(path: string)
{
	if(bufio == nil)
		return;
	b := bufio->open(path, Bufio->OREAD);
	if(b == nil)
		return;
	for(;;){
		ln := b.gets('\n');
		if(ln == nil)
			break;
		(nt, toks) := sys->tokenize(ln, " \t\n");
		if(nt < 6 || hd toks != "bitmap")
			continue;
		t := tl toks;
		ballx0 = int hd t;
		bally0 = int hd tl t;
		ballw = int hd tl tl t;
		ballh = int hd tl tl tl t;
		hex := hd tl tl tl tl t;
		if(ballw <= 0 || ballh <= 0 || len hex < 2*ballw*ballh)
			continue;
		ballpix = array[ballw*ballh] of byte;
		for(i := 0; i < ballw*ballh; i++)
			ballpix[i] = byte ((hexval(hex[2*i]) << 4) | hexval(hex[2*i+1]));
		return;
	}
}

hexval(ch: int): int
{
	if(ch >= '0' && ch <= '9')
		return ch - '0';
	if(ch >= 'a' && ch <= 'f')
		return ch - 'a' + 10;
	if(ch >= 'A' && ch <= 'F')
		return ch - 'A' + 10;
	return 0;
}

sign(v: int): int
{
	if(v < 0) return -1;
	if(v > 0) return 1;
	return 0;
}

rn(n: int): int
{
	if(rand == nil)
		return sys->millisec() % n;
	return rand->rand(n);
}


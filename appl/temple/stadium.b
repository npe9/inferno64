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

Stadium: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

FANS: con 10;
BALL_MS: con 200;	# BALL_TIME 0.2s

# the exact TempleOS 16-color palette, index = TempleOS color number
palette: array of int;
BLACK: con 0;
RED: con 4;

# one vector-sprite line element (fan sprite has only lines, all
# in the default color BLACK, default thickness 1)
Lel: adt {
	col, thk: int;
	x1, y1, x2, y2: int;
};

win: ref Window;
pal: array of ref Image;	# the 16 palette colors
black: ref Image;
tfont: ref Font;
bg: ref Image;			# StadiumBG capture, 640x472 at (0,0)
fanels: array of Lel;		# fan sprite line elements

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
	bufio = load Bufio Bufio->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
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
	tfont = Font.open(d, "/fonts/temple/temple.font");
	if(tfont == nil)
		tfont = Font.open(d, "*default*");
	bg = d.open("/icons/temple/stadium_bg.bit");
	fanels = loadspr("/lib/temple/sprites/stadium_1.spr");
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
	spawn timer(ticks, 10);	# original AnimateTask: Sleep(10) — 10ms tick
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
	<-ticks =>
		animate();
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
# (Mat4x4RotZ: x' = x cos - y sin, y' = x sin + y cos), plot at (x,y)
drawfan(img: ref Image, o: Point, x, y: int, ang: real)
{
	c := math->cos(ang);
	s := math->sin(ang);
	for(i := 0; i < len fanels; i++){
		e := fanels[i];
		x1 := int(real e.x1 * c - real e.y1 * s);
		y1 := int(real e.x1 * s + real e.y1 * c);
		x2 := int(real e.x2 * c - real e.y2 * s);
		y2 := int(real e.x2 * s + real e.y2 * c);
		r := e.thk / 2;
		img.line(Point(o.x + x + x1, o.y + y + y1),
			Point(o.x + x + x2, o.y + y + y2),
			Draw->Endsquare, Draw->Endsquare, r, pal[e.col & 15], (0, 0));
	}
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

loadspr(path: string): array of Lel
{
	if(bufio == nil)
		return array[0] of Lel;
	b := bufio->open(path, Bufio->OREAD);
	if(b == nil)
		return array[0] of Lel;
	l: list of Lel;
	nl := 0;
	col := BLACK;	# sprite plots in dc->color; DrawIt's dc starts BLACK
	thk := 1;
	for(;;){
		ln := b.gets('\n');
		if(ln == nil)
			break;
		(nt, toks) := sys->tokenize(ln, " \t\n");
		if(nt < 1)
			continue;
		case hd toks {
		"color" =>
			if(nt >= 2)
				col = int hd tl toks;
		"thick" =>
			if(nt >= 2)
				thk = int hd tl toks;
		"line" =>
			if(nt >= 5){
				t := tl toks;
				e := Lel(col, thk, int hd t, int hd tl t,
					int hd tl tl t, int hd tl tl tl t);
				l = e :: l;
				nl++;
			}
		}
	}
	a := array[nl] of Lel;
	for(i := nl - 1; i >= 0; i--){
		a[i] = hd l;
		l = tl l;
	}
	return a;
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

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}

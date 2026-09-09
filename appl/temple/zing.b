implement Zing;

# TempleOS Demo/Games/Zing.HC — bow and arrow toy
# LMB drag in bow box to aim; release to shoot; Enter restart; Esc/q quit
# GAP: the original's AnimateTask clamps the real cursor into the bow box
#      at all times; here the cursor is only warped into the box during a
#      drag (a windowed host must keep the titlebar and other windows
#      reachable). The original's MenuPush bar (File Abort/Exit, Play
#      Restart) has no counterpart; its actions are on Esc and Enter.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

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
include "grpalette.m";
	grpal: Grpalette;
include "frameclock.m";
	fclock: Frameclock;

Zing: module
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

# vector sprite element (lib/temple/sprites/zing_1.spr): the original's
# $SP "<1>" arrow, drawn rotated like Sprite3ZB
Sprel: adt {
	kind:	int;	# 0 line, 1 pt
	col:	int;
	x1, y1, x2, y2:	int;
};

win: ref Window;
pal: array of ref Image;	# the 16 TempleOS colors
black, brown, red, white: ref Image;
arrowspr: array of Sprel;
ptrfd: ref Sys->FD;
box_x0, box_y0, box_x1, box_y1: int;
bow_x, bow_y: real;
bow_drawn := 0;
bow_ang := 0.0;
mx, my: int;
prev_btn := 0;
have_tone := 0;
last_tick: int;

ax, ay, adx, ady: array of real;
narrows := 0;

# TempleOS 16-color palette, index = TempleOS color number
palette: array of int;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	palette = grpal->values();
	bufio = load Bufio Bufio->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	tone = load Tone Tone->PATH;
	fclock = load Frameclock Frameclock->PATH;
	fclock->init();
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS Zing", Wmclient->Appl);
	d := win.display;
	pal = array[16] of ref Image;
	for(i := 0; i < 16; i++)
		pal[i] = d.color(palette[i]);
	black = pal[0];
	red = pal[4];
	brown = pal[6];
	white = pal[15];
	arrowspr = loadspr("/lib/temple/sprites/zing_1.spr");
	ptrfd = sys->open("/dev/pointer", Sys->OWRITE);
	last_tick = sys->millisec();
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
		handleptr(p);
	k := <-win.ctxt.kbd =>
		case k {
		16r1b or 'q' or 'Q' =>
			if(have_tone) tone->stop();
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
			clampcursor();
			fcacc -= FCSTEP;
		}
		redraw();
	}
}

reset()
{
	img := win.image;
	w := 640; h := 480;
	if(img != nil){
		w = img.r.dx();
		h = img.r.dy();
	}
	box_x0 = 7 * w / 16;
	box_y0 = 6 * h / 8;
	box_x1 = 9 * w / 16;
	box_y1 = 7 * h / 8;
	bow_x = real(box_x0 + box_x1) / 2.0;
	bow_y = real(box_y0 + box_y1) / 2.0;
	bow_drawn = 0;
	bow_ang = -math->Pi / 2.0;
	narrows = 0;
	ax = array[0] of real;
	ay = array[0] of real;
	adx = array[0] of real;
	ady = array[0] of real;
	mx = int bow_x;
	my = int bow_y;
	# original Init() ends with MsSet(bow centre): warp the cursor there
	if(img != nil && ptrfd != nil)
		sys->fprint(ptrfd, "m%d %d", img.r.min.x + mx, img.r.min.y + my);
}

handleptr(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil)
		return;
	mx = p.xy.x - img.r.min.x;
	my = p.xy.y - img.r.min.y;
	btn := p.buttons & 1;
	if(btn && !prev_btn){
		bow_x = real(clampi(mx, box_x0, box_x1));
		bow_y = real(clampi(my, box_y0, box_y1));
		bow_drawn = 1;
	}
	if(!btn && prev_btn && bow_drawn){
		sx := clampi(mx, box_x0, box_x1);
		sy := clampi(my, box_y0, box_y1);
		if(sx != int bow_x || sy != int bow_y)
			shoot(real(sx), real(sy));
		bow_drawn = 0;
	}
	prev_btn = btn;
}

# original AnimateTask MsSet()s the real cursor into the bow box every
# 10ms; do the same while aiming (see GAP header for the always-on case)
clampcursor()
{
	if(!bow_drawn || ptrfd == nil)
		return;
	img := win.image;
	if(img == nil)
		return;
	cx := clampi(mx, box_x0, box_x1);
	cy := clampi(my, box_y0, box_y1);
	if(cx != mx || cy != my){
		sys->fprint(ptrfd, "m%d %d", img.r.min.x + cx, img.r.min.y + cy);
		mx = cx;
		my = cy;
	}
}

shoot(sx, sy: real)
{
	n := narrows;
	narrows = n + 1;
	ax = extend(ax, n);
	ay = extend(ay, n);
	adx = extend(adx, n);
	ady = extend(ady, n);
	ax[n] = sx;
	ay[n] = sy;
	adx[n] = 10.0 * (bow_x - sx);
	ady[n] = 10.0 * (bow_y - sy);
	if(have_tone)
		spawn noiseproc(50, 110, 114);	# original Noise(50,110,114)
}

# TempleOS Noise(ms,min_ona,max_ona): white noise in the ona band for ms;
# approximated as rapid random tones in the band (one voice)
noiseproc(ms, lo, hi: int)
{
	t0 := sys->millisec();
	while(sys->millisec() - t0 < ms){
		ona := lo;
		if(rand != nil)
			ona += rand->rand(hi - lo + 1);
		tone->snd(onafreq(ona));
		sys->sleep(10);
	}
	tone->stop();
}

# ona -> Hz, TempleOS Snd() semitone scale: 440*2^((ona-60)/12), Ona2Freq: ona 60 = 440Hz
onafreq(ona: int): int
{
	return int (440.0 * math->pow(2.0, real(ona - 60) / 12.0));
}

extend(a: array of real, n: int): array of real
{
	b := array[n + 1] of real;
	for(i := 0; i < n; i++)
		b[i] = a[i];
	return b;
}

animate()
{
	now := sys->millisec();
	dt := real(now - last_tick) / 1000.0;
	if(dt <= 0.0)
		dt = 0.01;
	last_tick = now;
	# cull against the live window, like the original's pix_width/height
	w := 640.0; h := 480.0;
	img := win.image;
	if(img != nil){
		w = real img.r.dx();
		h = real img.r.dy();
	}
	keep := 0;
	for(i := 0; i < narrows; i++){
		ax[i] += adx[i] * dt;
		ay[i] += ady[i] * dt;
		if(ax[i] >= 0.0 && ax[i] < w && ay[i] >= 0.0 && ay[i] < h){
			if(keep != i){
				ax[keep] = ax[i];
				ay[keep] = ay[i];
				adx[keep] = adx[i];
				ady[keep] = ady[i];
			}
			keep++;
		}
	}
	narrows = keep;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	img.draw(img.r, white, nil, Point(0, 0));

	# GrBorder: red outline rectangle
	p00 := Point(o.x + box_x0, o.y + box_y0);
	p10 := Point(o.x + box_x1, o.y + box_y0);
	p01 := Point(o.x + box_x0, o.y + box_y1);
	p11 := Point(o.x + box_x1, o.y + box_y1);
	img.line(p00, p10, Draw->Endsquare, Draw->Endsquare, 0, red, Point(0, 0));
	img.line(p10, p11, Draw->Endsquare, Draw->Endsquare, 0, red, Point(0, 0));
	img.line(p11, p01, Draw->Endsquare, Draw->Endsquare, 0, red, Point(0, 0));
	img.line(p01, p00, Draw->Endsquare, Draw->Endsquare, 0, red, Point(0, 0));

	x := real(clampi(mx, box_x0, box_x1));
	y := real(clampi(my, box_y0, box_y1));
	dx := bow_x - x;
	dy := bow_y - y;
	if(bow_drawn && (dx != 0.0 || dy != 0.0))
		bow_ang = math->atan2(dy, dx);
	else if(!bow_drawn){
		bow_x = x;
		bow_y = y;
	}

	draw_len := math->sqrt(dx * dx + dy * dy);
	str_w := draw_len / 3.0;
	str_h := math->sqrt(3600.0 - str_w * str_w);
	if(str_h != str_h)	# NaN guard (draw_len > 180); original lacks it
		str_h = 0.0;

	cp := math->cos(bow_ang + math->Pi / 2.0);
	sp := math->sin(bow_ang + math->Pi / 2.0);
	ca := math->cos(bow_ang);
	sa := math->sin(bow_ang);

	# bow string: two black lines from the string ends to the draw point
	img.line(pt(o, x - str_h / 2.0 * cp + str_w * ca,
			y - str_h / 2.0 * sp + str_w * sa),
		pt(o, x, y), Draw->Endsquare, Draw->Endsquare, 0, black, Point(0, 0));
	img.line(pt(o, x + str_h / 2.0 * cp + str_w * ca,
			y + str_h / 2.0 * sp + str_w * sa),
		pt(o, x, y), Draw->Endsquare, Draw->Endsquare, 0, black, Point(0, 0));

	# the bow: one Gr2BSpline3 through 5 control points, brown, thick 2
	cx := array[5] of real;
	cy := array[5] of real;
	cx[0] = x - str_h / 2.0 * cp + str_w * ca;
	cy[0] = y - str_h / 2.0 * sp + str_w * sa;
	cx[1] = x - 0.75 * str_h / 2.0 * cp + (draw_len / 2.0 + str_w) * ca;
	cy[1] = y - 0.75 * str_h / 2.0 * sp + (draw_len / 2.0 + str_w) * sa;
	cx[2] = x + (draw_len / 2.0 + str_w) * ca;
	cy[2] = y + (draw_len / 2.0 + str_w) * sa;
	cx[3] = x + 0.75 * str_h / 2.0 * cp + (draw_len / 2.0 + str_w) * ca;
	cy[3] = y + 0.75 * str_h / 2.0 * sp + (draw_len / 2.0 + str_w) * sa;
	cx[4] = x + str_h / 2.0 * cp + str_w * ca;
	cy[4] = y + str_h / 2.0 * sp + str_w * sa;
	bspline(img, o, cx, cy);

	if(bow_drawn)
		drawarrow(img, o, x, y, bow_ang);	# at the draw point, like Sprite3ZB(dc,x,y,...)

	for(i := 0; i < narrows; i++){
		ang := math->atan2(ady[i], adx[i]);
		drawarrow(img, o, ax[i], ay[i], ang);
	}
	img.flush(Draw->Flushnow);
}

# clamped quadratic B-spline through the control points (Gr2BSpline3):
# passes through the endpoints, interior points pull the curve
bspline(img: ref Image, o: Point, cx, cy: array of real)
{
	SEGSTEPS: con 8;
	n := len cx;
	prev := pt(o, cx[0], cy[0]);
	for(i := 1; i < n - 1; i++){
		sx := cx[0]; sy := cy[0];
		if(i > 1){
			sx = (cx[i-1] + cx[i]) / 2.0;
			sy = (cy[i-1] + cy[i]) / 2.0;
		}
		ex := cx[n-1]; ey := cy[n-1];
		if(i < n - 2){
			ex = (cx[i] + cx[i+1]) / 2.0;
			ey = (cy[i] + cy[i+1]) / 2.0;
		}
		for(s := 1; s <= SEGSTEPS; s++){
			t := real s / real SEGSTEPS;
			u := 1.0 - t;
			bx := u*u*sx + 2.0*t*u*cx[i] + t*t*ex;
			by := u*u*sy + 2.0*t*u*cy[i] + t*t*ey;
			p := pt(o, bx, by);
			img.line(prev, p, Draw->Endsquare, Draw->Endsquare, 1, brown, Point(0, 0));
			prev = p;
		}
	}
}

# the original's $SP "<1>" arrow, rotated about its origin like
# Sprite3ZB(dc,x,y,0,...,ang)
drawarrow(img: ref Image, o: Point, x, y, ang: real)
{
	cs := math->cos(ang);
	sn := math->sin(ang);
	if(len arrowspr > 0){
		for(i := 0; i < len arrowspr; i++){
			e := arrowspr[i];
			c := pal[e.col & 15];
			p1 := pt(o, x + real e.x1 * cs - real e.y1 * sn,
				y + real e.x1 * sn + real e.y1 * cs);
			case e.kind {
			0 =>
				p2 := pt(o, x + real e.x2 * cs - real e.y2 * sn,
					y + real e.x2 * sn + real e.y2 * cs);
				img.line(p1, p2, Draw->Endsquare, Draw->Endsquare, 0, c, Point(0, 0));
			1 =>
				img.draw(Rect(p1, Point(p1.x + 1, p1.y + 1)), c, nil, Point(0, 0));
			}
		}
		return;
	}
	# fallback if the sprite file is missing: plain shaft and head
	tip := pt(o, x + 53.0 * cs, y + 53.0 * sn);
	tail := pt(o, x, y);
	img.line(tail, tip, Draw->Endsquare, Draw->Endsquare, 0, brown, Point(0, 0));
}

loadspr(path: string): array of Sprel
{
	if(bufio == nil)
		return array[0] of Sprel;
	b := bufio->open(path, Bufio->OREAD);
	if(b == nil)
		return array[0] of Sprel;
	l: list of Sprel;
	n := 0;
	col := 0;
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
		"line" =>
			if(nt >= 5){
				t := tl toks;
				e := Sprel(0, col, int hd t, int hd tl t,
					int hd tl tl t, int hd tl tl tl t);
				l = e :: l;
				n++;
			}
		"pt" =>
			if(nt >= 3){
				t := tl toks;
				e := Sprel(1, col, int hd t, int hd tl t, 0, 0);
				l = e :: l;
				n++;
			}
		}
	}
	a := array[n] of Sprel;
	for(i := n - 1; i >= 0; i--){
		a[i] = hd l;
		l = tl l;
	}
	return a;
}

pt(o: Point, x, y: real): Point
{
	return Point(o.x + int x, o.y + int y);
}

clampi(v, lo, hi: int): int
{
	if(v < lo) return lo;
	if(v > hi) return hi;
	return v;
}


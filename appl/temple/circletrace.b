implement Circletrace;

# TempleOS Demo/Games/CircleTrace.HC — trace a circle freehand
# LMB draw around guide circle; score = elapsed_time * avg_error where
# avg_error = per-pixel radial error / path length, as in the original.
# An attempt only counts if total_distance > 0.95*CIRCUMFERENCE.
# GAP: original draws guide and trace in ROP_XOR (re-inverting on overlap);
#      Inferno draw(2) has no XOR raster op, so both are drawn opaque.

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

include "tone.m";
	tone: Tone;

include "scorestore.m";
	scorestore: Scorestore;
include "grpalette.m";
	grpal: Grpalette;
include "frameclock.m";
	fclock: Frameclock;

Circletrace: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

RADIUS: con 100;
CIRCUMFERENCE: con 2.0 * Math->Pi * real RADIUS;

# TempleOS Snd(ona) is semitones: freq = 440*2^((ona-60)/12) (Ona2Freq: ona 60 = 440Hz)
SND86: con 1976;	# new-best jingle
SND62: con 494;		# ordinary completion
SND34: con 98;		# trace too short

win: ref Window;
ink: array of ref Image;
font: ref Font;
cx, cy: int;
down := 0;
lx, ly: int;
total_err := 0.0;
total_dist := 0.001;
avg_error := 0.0;
elapsed_time := 0.0;
score := 999.0;
best := 999.0;
t0 := 0;
hudw := 0;
have_tone := 0;
song_pause := 0;
song_quit := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	tone = load Tone Tone->PATH;
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	scorestore = load Scorestore Scorestore->PATH;
	fclock = load Frameclock Frameclock->PATH;
	fclock->init();
	if(scorestore != nil)
		best = scorestore->loadreal("circletrace", best);

	win = wmclient->window(ctxt, "TempleOS CircleTrace", Wmclient->Appl);
	d := win.display;
	# the exact TempleOS 16-color palette (index = TempleOS color)
	cols := grpal->values();
	ink = array[16] of ref Image;
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);
	font = Font.open(d, "/fonts/lucida/unicode.8.font");
	if(font == nil)
		font = Font.open(d, "*default*");

	win.reshape(Rect((0, 0), (500, 500)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	resetguide();

	if(have_tone)
		spawn songloop();
	ticks := chan of int;
	spawn fclock->ticker(ticks, 60);	# 60fps: original HUD refreshes each winmgr frame (~30fps)

	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!')
			resetguide();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		ptr(p);
	k := <-win.ctxt.kbd =>
		if(k == 16r1b || k == 'q' || k == 'Q'){
			song_quit = 1;
			if(have_tone)
				tone->stop();
			exit;
		}
		if(k == 'r' || k == 'R' || k == '\n')
			resetguide();
	<-ticks =>
		if(down){
			# time keeps running while the trace is held still
			elapsed_time = real (sys->millisec() - t0) / 1000.0;
			avg_error = total_err / total_dist;
			score = elapsed_time * avg_error;
			hud();
			img := win.image;
			if(img != nil)
				img.flush(Draw->Flushnow);
		}
	}
}

# background music, as the original's SongTask; muted during result sounds
songloop()
{
	while(!song_quit){
		if(!song_pause)
			tone->play("5hEDC4A5RCDECR");
		else
			sys->sleep(50);
	}
}


resetguide()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, ink[15], nil, Point(0, 0));
	cx = img.r.dx() / 2;
	cy = img.r.dy() / 2;
	o := img.r.min;
	img.ellipse(Point(cx, cy).add(o), RADIUS, RADIUS, 0, ink[0], Point(0, 0));
	down = 0;
	total_err = 0.0;
	total_dist = 0.001;
	hud();
	img.flush(Draw->Flushnow);
}

# per-pixel radial error at (x,y), as the original's CTPlot callback
pixerr(x, y: int): real
{
	dx := real (x - cx);
	dy := real (y - cy);
	return math->fabs(math->sqrt(dx*dx + dy*dy) - real RADIUS);
}

# accumulate |rad-RADIUS| at every pixel of the segment, endpoints
# inclusive — the original plots via Line(dc,...,&CTPlot)
lineerr(x0, y0, x1, y1: int): real
{
	e := 0.0;
	dx := x1 - x0;
	if(dx < 0)
		dx = -dx;
	dy := y1 - y0;
	if(dy < 0)
		dy = -dy;
	sx := 1;
	if(x0 > x1)
		sx = -1;
	sy := 1;
	if(y0 > y1)
		sy = -1;
	err := dx - dy;
	x := x0;
	y := y0;
	for(;;){
		e += pixerr(x, y);
		if(x == x1 && y == y1)
			break;
		e2 := 2*err;
		if(e2 > -dy){
			err -= dy;
			x += sx;
		}
		if(e2 < dx){
			err += dx;
			y += sy;
		}
	}
	return e;
}

# the original's DrawIt() HUD line, GrPrinted at (0,0) every frame
hud()
{
	img := win.image;
	if(img == nil || font == nil)
		return;
	s := sys->sprint("Error:%6.3fTime:%6.3fScore:%6.3fBest:%8.3f",
		avg_error, elapsed_time, score, best);
	o := img.r.min;
	w := font.width(s);
	cw := w;
	if(hudw > cw)
		cw = hudw;
	hudw = w;
	img.draw(Rect((0, 0), (cw, font.height)).addpt(o), ink[15], nil, Point(0, 0));
	img.text(o, ink[0], Point(0, 0), font, s);
}

ptr(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil)
		return;
	x := p.xy.x - img.r.min.x;
	y := p.xy.y - img.r.min.y;
	o := img.r.min;
	if(p.buttons & 1){
		if(!down){
			# fresh attempt on every press, as the original
			down = 1;
			lx = x; ly = y;
			total_err = 0.0;
			total_dist = 0.001;
			t0 = sys->millisec();
			elapsed_time = 0.0;
			avg_error = 0.0;
			score = 0.0;
			img.draw(img.r, ink[15], nil, Point(0, 0));
			img.ellipse(Point(cx, cy).add(o), RADIUS, RADIUS, 0, ink[0], Point(0, 0));
			hud();
			img.flush(Draw->Flushnow);
		}else if(x != lx || y != ly){
			img.line(Point(lx, ly).add(o), Point(x, y).add(o),
				Draw->Endsquare, Draw->Endsquare, 0, ink[4], Point(0, 0));
			total_dist += math->sqrt(real ((x-lx)*(x-lx) + (y-ly)*(y-ly)));
			total_err += lineerr(lx, ly, x, y);
			# undo the segment-endpoint pixel duplicated by the
			# next segment's start (original subtracts after GrPlot)
			total_err -= pixerr(x, y);
			lx = x; ly = y;
			elapsed_time = real (sys->millisec() - t0) / 1000.0;
			avg_error = total_err / total_dist;
			score = elapsed_time * avg_error;
			hud();
			img.flush(Draw->Flushnow);
		}
	}else if(down){
		down = 0;
		elapsed_time = real (sys->millisec() - t0) / 1000.0;
		avg_error = total_err / total_dist;
		score = elapsed_time * avg_error;
		completed := total_dist > 0.95 * CIRCUMFERENCE;
		newbest := 0;
		if(completed && score < best){
			newbest = 1;
			best = score;
			if(scorestore != nil)
				scorestore->savereal("circletrace", best);
		}
		hud();
		img.flush(Draw->Flushnow);
		if(have_tone){
			song_pause = 1;
			tone->stop();
			sys->sleep(200);
			if(completed){
				if(newbest){
					# Snd(86);Sleep(50);Snd;Sleep(50); x2 then Snd(86);Sleep(50);
					for(i := 0; i < 2; i++){
						tone->snd(SND86);
						sys->sleep(50);
						tone->stop();
						sys->sleep(50);
					}
					tone->snd(SND86);
					sys->sleep(50);
				}else{
					tone->snd(SND62);
					sys->sleep(50);
				}
			}else{
				tone->snd(SND34);
				sys->sleep(1000);
			}
			tone->stop();
			sys->sleep(200);
			song_pause = 0;
		}
	}
}

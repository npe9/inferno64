implement Flapbat;

# TempleOS Demo/Games/FlapBat.HC — Wmclient+Draw
# GAP: no SpriteInterpolate bat frames / flood-fill sprite art — ellipse+arcs bat
# GAP: no GrPrint HUD — progress bar; RegWrite best_score not persisted
# GAP: no MSG_KEY_UP — space retriggers flap; hold-to-glide omitted
# GAP: SongTask loop approximate via tone->play strings

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "keyboard.m";

include "rand.m";
	rand: Rand;

include "tone.m";
	tone: Tone;

Flapbat: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

BORDER: con 6;
EAT_TIME: con 0.5;
FLAP_TIME: con 0.5;
BAT_BOX: con 10;
BUGS_NUM: con 32;
GLOW_PERIOD: con 3.0;

win: ref Window;
ink: array of ref Image;
flap_down: int;
flap_phase, delta_phase, bat_y, bat_x: real;
eat_timeout, flap_time: real;
frame_x, game_t0, game_tf: real;
bug_cnt: int;
bugs_x, bugs_y: array of int;
bugs_dead: array of int;
bugs_glow_phase: array of real;
best_score: real;
game_done: int;
have_tone := 0;
song_pause := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
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

	win = wmclient->window(ctxt, "TempleOS FlapBat", Wmclient->Appl);
	d := win.display;
	ink = array[16] of ref Image;
	cols := array[] of {
		Draw->Black, Draw->Blue, Draw->Green, Draw->Cyan,
		Draw->Red, Draw->Magenta, Draw->Darkyellow, Draw->Grey,
		int 16r444444FF, Draw->Paleblue, Draw->Palegreen, Draw->Palebluegreen,
		int 16rFF8888FF, int 16rFF88FFFF, Draw->Yellow, Draw->White
	};
	for(i := 0; i < 16; i++)
		ink[i] = d.color(cols[i]);

	best_score = 9999.0;
	bugs_x = array[BUGS_NUM] of int;
	bugs_y = array[BUGS_NUM] of int;
	bugs_dead = array[BUGS_NUM] of int;
	bugs_glow_phase = array[BUGS_NUM] of real;

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: nil);
	game_init();
	if(have_tone)
		spawn songloop();

	ticks := chan of int;
	spawn timer(ticks, 16);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	k := <-win.ctxt.kbd =>
		case k {
		16r1b or 'q' or 'Q' =>
			if(have_tone)
				tone->stop();
			exit;
		'\n' or 'r' or 'R' =>
			game_init();
		' ' =>
			flap_down = 1;
		}
	<-ticks =>
			animate();
			redraw();
	}
}

game_init()
{
	flap_down = 0;
	flap_phase = 0.0;
	bat_x = 0.0;
	bat_y = 0.0;
	frame_x = 0.0;
	bug_cnt = BUGS_NUM;
	game_tf = 0.0;
	game_done = 0;
	eat_timeout = flap_time = 0.0;
	delta_phase = 0.0;
	song_pause = 0;
	game_t0 = now();
	for(i := 0; i < BUGS_NUM; i++){
		bugs_dead[i] = 0;
		bugs_x[i] = rn(65536);
		bugs_y[i] = rn(65536);
		bugs_glow_phase[i] = GLOW_PERIOD * real(rn(1000)) / 1000.0;
	}
}

animate()
{
	ts := now();
	if(flap_down){
		flap_down = 0;
		dt := ts - flap_time;
		if(dt > FLAP_TIME)
			dt = FLAP_TIME;
		delta_phase = -0.005 * dt / FLAP_TIME;
		flap_time = ts;
	}else if(delta_phase < 0.0){
		bat_y += 75.0 * delta_phase;
		delta_phase += 0.000015;
	}else
		bat_y += 0.15;
	img := win.image;
	if(img != nil){
		h := real img.r.dy();
		if(bat_y < real BORDER)
			bat_y = real BORDER;
		if(bat_y > h - real BORDER)
			bat_y = h - real BORDER;
	}
	flap_phase += delta_phase;
	if(flap_phase < 0.0)
		flap_phase = 0.0;
	if(flap_phase > 1.0)
		flap_phase = 1.0;
	checkbugs();
}

checkbugs()
{
	img := win.image;
	if(img == nil)
		return;
	w := img.r.dx();
	h := img.r.dy();
	playw := w - 2*BORDER;
	if(playw < 1)
		playw = 1;
	playh := h - 2*BORDER;
	if(playh < 1)
		playh = 1;
	bat_x = real(w >> 3);
	ts := now();
	if(eat_timeout > 0.0 && eat_timeout - ts < 0.75*EAT_TIME)
		song_pause = 0;
	if(eat_timeout > 0.0 && ts >= eat_timeout)
		eat_timeout = 0.0;
	for(i := 0; i < BUGS_NUM; i++){
		if(bugs_dead[i])
			continue;
		x := (bugs_x[i] + int frame_x) % playw + BORDER;
		y := bugs_y[i] % playh + BORDER;
		if(abs(x - int bat_x) < BAT_BOX && abs(y - int bat_y) < BAT_BOX){
			bugs_dead[i] = 1;
			eat_timeout = ts + EAT_TIME;
			song_pause = 1;
			if(have_tone)
				tone->beep(74, 80);
			bug_cnt--;
		}
	}
	if(game_tf == 0.0 && bug_cnt == 0){
		game_tf = ts;
		game_done = 1;
		song_pause = 1;
		if(have_tone)
			tone->stop();
		elapsed := game_tf - game_t0;
		if(elapsed < best_score)
			best_score = elapsed;
	}
	frame_x -= 0.1;
	if(frame_x < 0.0)
		frame_x += real playw;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	w := img.r.dx();
	h := img.r.dy();
	o := img.r.min;
	playw := w - 2*BORDER;
	if(playw < 1)
		playw = 1;
	playh := h - 2*BORDER;
	if(playh < 1)
		playh = 1;
	ts := now();
	bat_x = real(w >> 3);

	img.draw(img.r, ink[7], nil, Point(0, 0));

	# moon
	mx := (7*w) >> 3;
	img.draw(Rect((o.x+mx-12, o.y+8), (o.x+mx+12, o.y+32)), ink[15], nil, Point(0, 0));
	img.ellipse(Point(o.x+mx, o.y+20), 10, 10, 1, ink[7], Point(0, 0));

	# cave arc hint
	cave_r := 10 + int(20.0 * saw(15.0*ts, 2.0));
	img.ellipse(Point(o.x+int bat_x+25, o.y+int bat_y), cave_r, 5, 1, ink[8], Point(0, 0));

	drawbat(img, o.x+int bat_x, o.y+int bat_y, ts);

	for(i := 0; i < BUGS_NUM; i++){
		if(bugs_dead[i])
			continue;
		x := (bugs_x[i] + int frame_x) % playw + BORDER;
		y := bugs_y[i] % playh + BORDER;
		col := ink[0];
		if(saw(ts + bugs_glow_phase[i], GLOW_PERIOD) < 0.2){
			if(i & 1)
				col = ink[14];
			else
				col = ink[2];
		}
		img.draw(Rect((o.x+x, o.y+y), (o.x+x+2, o.y+y+1)), col, nil, Point(0, 0));
		img.draw(Rect((o.x+x, o.y+y-1), (o.x+x+1, o.y+y)), ink[0], nil, Point(0, 0));
	}

	# bug progress bar (top)
	done := BUGS_NUM - bug_cnt;
	barw := (w - 20) * done / BUGS_NUM;
	img.draw(Rect((o.x+10, o.y+2), (o.x+10+barw, o.y+6)), ink[2], nil, Point(0, 0));

	if(game_done){
		img.draw(Rect((o.x+w/2-80, o.y+h/2-12), (o.x+w/2+80, o.y+h/2+12)), ink[4], nil, Point(0, 0));
	}
	img.flush(Draw->Flushnow);
}

drawbat(img: ref Image, bx, by: int, ts: real)
{
	o := img.r.min;
	eating := 0;
	if(eat_timeout > 0.0 && ts < eat_timeout)
		eating = 1;
	phase := flap_phase * flap_phase * flap_phase;
	if(eating){
		blend := 1.0 - (eat_timeout - ts) / EAT_TIME;
		if(blend < 0.0)
			blend = 0.0;
		if(blend > 1.0)
			blend = 1.0;
		phase = phase * (1.0 - blend) + blend;
	}
	wing := int(8.0 + 12.0 * phase);
	img.ellipse(Point(o.x+bx, o.y+by), 8, 6, 1, ink[0], Point(0, 0));
	img.line(Point(o.x+bx-wing, o.y+by-2), Point(o.x+bx-2, o.y+by-8),
		Draw->Enddisc, Draw->Enddisc, 2, ink[0], Point(0, 0));
	img.line(Point(o.x+bx+wing, o.y+by-2), Point(o.x+bx+2, o.y+by-8),
		Draw->Enddisc, Draw->Enddisc, 2, ink[0], Point(0, 0));
	if(eating)
		img.draw(Rect((o.x+bx-3, o.y+by+2), (o.x+bx+3, o.y+by+5)), ink[4], nil, Point(0, 0));
}

songloop()
{
	scores := array[] of {
		"4eB5E4B5C4B5EsEFqE4eB5E4B5C4B5EsEF",
		"5qE4eA5D4ABA5DsDCqD4eB5E4B5C4B5EsEDqE",
		"5EsEDqE",
	};
	for(;;){
		if(!song_pause){
			for(i := 0; i < len scores; i++){
				if(song_pause)
					break;
				tone->play(scores[i]);
			}
		}else
			sys->sleep(50);
	}
}

saw(t, period: real): real
{
	if(period == 0.0)
		return 0.0;
	f := t / period;
	f = f - real int f;
	return 2.0 * f - 1.0;
}

now(): real
{
	return real sys->millisec() / 1000.0;
}

abs(v: int): int
{
	if(v < 0)
		return -v;
	return v;
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

implement Treecheckers;

# TempleOS Demo/Games/TreeCheckers.HC — Wmclient+Draw
# GAP: PopUpRangeI64 board size → fixed size 5 (rad 11, 32 units)
# GAP: no GrPrint — player banner color + game-over bar
# GAP: Blink midpoints approximated with millisec toggle

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "rand.m";
	rand: Rand;

include "tone.m";
	tone: Tone;

Treecheckers: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# size=5 defaults from InitDefines()
CIRCLE_RAD: con 11;
UNITS_NUM: con 32;
MOVE_CIRCLES: con 3;
BIG: con 2147483647;

win: ref Window;
mapimg: ref Image;
ink: array of ref Image;
border_x, border_y, map_w, map_h: int;
cur_player: int;
num_alive: array of int;
show_start: int;
start_x, start_y, end_x, end_y: int;
u_x, u_y, u_player, u_link: array of int;
u_alive, u_king: array of int;
sel: int;
lastl := 0;
have_tone := 0;

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

	win = wmclient->window(ctxt, "TempleOS TreeCheckers", Wmclient->Appl);
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

	u_x = array[UNITS_NUM] of int;
	u_y = array[UNITS_NUM] of int;
	u_player = array[UNITS_NUM] of int;
	u_link = array[UNITS_NUM] of int;
	u_alive = array[UNITS_NUM] of int;
	u_king = array[UNITS_NUM] of int;
	num_alive = array[2] of int;

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	game_init();

	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!')
			redraw();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		ptr(p);
	k := <-win.ctxt.kbd =>
		case k {
		16r1b or 'q' or 'Q' =>
			exit;
		'\n' or 'r' or 'R' =>
			game_init();
		}
	}
}

game_init()
{
	img := win.image;
	w := 640;
	h := 480;
	if(img != nil){
		w = img.r.dx();
		h = img.r.dy();
	}
	if(mapimg != nil)
		mapimg = nil;
	mapimg = drawhexmap(w, h);
	cur_player = 0;
	sel = -1;
	show_start = 0;
	placeunits();
	redraw();
}

drawhexmap(w, h: int): ref Image
{
	d := win.display;
	dc := d.newimage(Rect((0, 0), (w, h)), d.image.chans, 0, Draw->White);
	dc.draw(dc.r, ink[15], nil, Point(0, 0));

	cols := (w - 8 - CIRCLE_RAD) / (2*CIRCLE_RAD);
	cols = cols & ~1;
	cols = cols - 1;
	rows := (h - 8) / (2*CIRCLE_RAD);
	rows = rows & ~1;
	border_x = (w + CIRCLE_RAD - cols*2*CIRCLE_RAD) / 2;
	border_y = (h - rows*2*CIRCLE_RAD) / 2;

	map_w = (w - border_x*2 - CIRCLE_RAD) / (CIRCLE_RAD*2);
	map_h = (h - border_y*2) / (CIRCLE_RAD*2);

	for(j := 0; j < map_h; j++){
		for(i := 0; i < map_w; i++){
			x := i*CIRCLE_RAD*2 + border_x + CIRCLE_RAD;
			y := j*CIRCLE_RAD*2 + border_y + CIRCLE_RAD;
			if(j & 1)
				x += CIRCLE_RAD;
			(x, y) = s2w(x, y);
			dc.ellipse(Point(x, y), CIRCLE_RAD, CIRCLE_RAD, 1, ink[7], Point(0, 0));
		}
	}
	map_w *= CIRCLE_RAD*2;
	map_h *= CIRCLE_RAD*2;
	return dc;
}

placeunits()
{
	half := UNITS_NUM / 2;
	for(i := 0; i < half; i++){
		ok := 0;
		while(!ok){
			uy := floori(rn(map_h), CIRCLE_RAD*2) + CIRCLE_RAD;
			uy2 := map_h - 1 - uy;
			j1 := uy / (CIRCLE_RAD*2);
			j2 := uy2 / (CIRCLE_RAD*2);
			uy += border_y;
			uy2 += border_y;

			ux := 0;
			if(i == 0){
				if(j1 & 1)
					continue;
				ux = CIRCLE_RAD;
			}else
				ux = floori(rn((map_w - CIRCLE_RAD*2*2)/2), CIRCLE_RAD*2) + CIRCLE_RAD;
			ux2 := map_w - 1 - ux;

			if(j1 & 1)
				ux += CIRCLE_RAD;
			if(j2 & 1)
				ux2 += CIRCLE_RAD;
			ux += border_x;
			ux2 += border_x;

			(ux, uy) = s2w(ux, uy);
			(ux2, uy2) = s2w(ux2, uy2);

			u_x[i] = ux;
			u_y[i] = uy;
			u_x[i+half] = ux2;
			u_y[i+half] = uy2;
			ok = 1;
		}
		u_player[i] = 0;
		u_player[i+half] = 1;
		u_alive[i] = 1;
		u_alive[i+half] = 1;
		if(i == 0){
			u_king[i] = 1;
			u_king[i+half] = 1;
		}else{
			u_king[i] = 0;
			u_king[i+half] = 0;
		}
	}
	for(ii := 0; ii < half; ii++){
		if(!u_king[ii]){
			best_dd := BIG;
			best := 0;
			for(j := 0; j < half; j++){
				if(ii == j)
					continue;
				dd := sqri(u_x[ii]-u_x[j]) + sqri(u_y[ii]-u_y[j]);
				if((u_x[j] < u_x[ii] || u_king[j]) && dd < best_dd){
					best_dd = dd;
					best = j;
				}
			}
			u_link[ii] = best;
			u_link[ii+half] = best + half;
		}
	}
	num_alive[0] = half;
	num_alive[1] = half;
}

ptr(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil)
		return;
	x := p.xy.x - img.r.min.x;
	y := p.xy.y - img.r.min.y;
	left := (p.buttons & 1) != 0;
	if(left && !lastl){
		if(num_alive[0] > 1 && num_alive[1] > 1){
			sel = unitfind(x, y, cur_player);
			if(sel >= 0){
				start_x = end_x = u_x[sel];
				start_y = end_y = u_y[sel];
				show_start = 1;
			}
		}
	}
	if(left && sel >= 0)
		unitmove(sel, x, y);
	if(!left && lastl && sel >= 0){
		unitmove(sel, x, y);
		killschk(u_x[sel], u_y[sel], cur_player);
		show_start = 0;
		sel = -1;
		cur_player = 1 - cur_player;
	}
	lastl = left;
	redraw();
}

unitfind(x, y, player: int): int
{
	best_dd := BIG;
	res := -1;
	for(i := 0; i < UNITS_NUM; i++){
		if(u_player[i] != player || !u_alive[i])
			continue;
		dd := sqri(u_x[i]-x) + sqri(u_y[i]-y);
		if(dd < best_dd){
			best_dd = dd;
			res = i;
		}
	}
	return res;
}

killschk(x1, y1, player: int)
{
	for(i := 0; i < UNITS_NUM; i++){
		if(u_player[i] == player || !u_alive[i] || u_king[i])
			continue;
		x2 := (u_x[i] + u_x[u_link[i]]) >> 1;
		y2 := (u_y[i] + u_y[u_link[i]]) >> 1;
		dd := sqri(x2-x1) + sqri(y2-y1);
		rad := CIRCLE_RAD + 2;
		if(dd <= rad*rad){
			u_alive[i] = 0;
			beepkill();
			num_alive[u_player[i]]--;
			for(;;){
				found := 0;
				for(j := 0; j < UNITS_NUM; j++){
					if(!u_alive[j] || u_player[j] == player || u_king[j])
						continue;
					if(!u_alive[u_link[j]]){
						found = 1;
						u_alive[j] = 0;
						beepkill();
						num_alive[u_player[j]]--;
					}
				}
				if(!found)
					break;
			}
		}
	}
}

unitmove(idx, px, py: int): int
{
	if(idx < 0)
		return 0;
	(x2, y2) := s2w(px, py);
	(c2, r2) := s2circle(x2, y2);
	x := start_x;
	y := start_y;
	for(step := 0; step <= MOVE_CIRCLES; step++){
		(c, r) := s2circle(x, y);
		if(c == c2 && r == r2){
			end_x = u_x[idx] = x2;
			end_y = u_y[idx] = y2;
			return 1;
		}
		if(r2 != r){
			if(r & 1){
				if(c < c2)
					c++;
			}else if(c > c2)
				c--;
		}
		if(r2 > r){
			r++;
			(x, y) = circle2s(c, r);
		}else if(r2 < r){
			r--;
			(x, y) = circle2s(c, r);
		}else if(c2 > c){
			c++;
			(x, y) = circle2s(c, r);
		}else if(c2 < c){
			c--;
			(x, y) = circle2s(c, r);
		}
	}
	return 0;
}

s2circle(px, py: int): (int, int)
{
	j := (py - border_y) / (CIRCLE_RAD*2);
	c := (px - border_x) / (CIRCLE_RAD*2);
	if(j & 1)
		c = (px - CIRCLE_RAD - border_x) / (CIRCLE_RAD*2);
	return (c, j);
}

circle2s(c, r: int): (int, int)
{
	x := c*CIRCLE_RAD*2 + CIRCLE_RAD + border_x;
	y := r*CIRCLE_RAD*2 + CIRCLE_RAD + border_y;
	if(r & 1)
		x += CIRCLE_RAD;
	return (x, y);
}

s2w(px, py: int): (int, int)
{
	(c, r) := s2circle(px, py);
	return circle2s(c, r);
}

redraw()
{
	img := win.image;
	if(img == nil || mapimg == nil)
		return;
	o := img.r.min;
	img.draw(img.r, mapimg, nil, mapimg.r.min);

	if(cur_player == 0)
		img.draw(Rect((o.x, o.y), (o.x+img.r.dx(), o.y+18)), ink[10], nil, Point(0, 0));
	else
		img.draw(Rect((o.x, o.y), (o.x+img.r.dx(), o.y+18)), ink[13], nil, Point(0, 0));

	for(i := 0; i < UNITS_NUM; i++){
		if(!u_alive[i])
			continue;
		col := ink[2];
		if(u_player[i] == 0){
			if(u_king[i])
				col = ink[10];
			else
				col = ink[2];
		}else{
			if(u_king[i])
				col = ink[13];
			else
				col = ink[5];
		}
		fillcircle(img, u_x[i], u_y[i], col);
		if(u_king[i] || !u_alive[i])
			continue;
		img.line(Point(o.x+u_x[i], o.y+u_y[i]),
			Point(o.x+u_x[u_link[i]], o.y+u_y[u_link[i]]),
			0, 0, 1, ink[0], Point(0, 0));
		if(blink()){
			mx := (u_x[i] + u_x[u_link[i]]) >> 1;
			my := (u_y[i] + u_y[u_link[i]]) >> 1;
			img.draw(Rect((o.x+mx-2, o.y+my-2), (o.x+mx+3, o.y+my+3)), ink[1], nil, Point(0, 0));
		}
	}
	if(show_start){
		img.line(Point(o.x+start_x-4, o.y+start_y-4), Point(o.x+start_x+4, o.y+start_y+4),
			0, 0, 1, ink[12], Point(0, 0));
		img.line(Point(o.x+start_x-4, o.y+start_y+4), Point(o.x+start_x+4, o.y+start_y-4),
			0, 0, 1, ink[12], Point(0, 0));
		img.line(Point(o.x+start_x, o.y+start_y), Point(o.x+end_x, o.y+end_y),
			0, 0, 1, ink[12], Point(0, 0));
	}
	if((num_alive[0] == 1 || num_alive[1] == 1) && blink4()){
		w := img.r.dx();
		h := img.r.dy();
		img.draw(Rect((o.x+w/2-60, o.y+h/2-10), (o.x+w/2+60, o.y+h/2+10)), ink[0], nil, Point(0, 0));
	}
	img.flush(Draw->Flushnow);
}

fillcircle(img: ref Image, cx, cy: int, col: ref Image)
{
	o := img.r.min;
	r := CIRCLE_RAD - 2;
	if(r < 2)
		r = 2;
	for(dy := -r; dy <= r; dy++)
		for(dx := -r; dx <= r; dx++)
			if(dx*dx + dy*dy <= r*r)
				img.draw(Rect((o.x+cx+dx, o.y+cy+dy), (o.x+cx+dx+1, o.y+cy+dy+1)), col, nil, Point(0, 0));
}

beepkill()
{
	if(have_tone){
		tone->beep(62, 100);
		tone->stop();
		sys->sleep(25);
	}
}

blink(): int
{
	return (sys->millisec() / 500) & 1;
}

blink4(): int
{
	return ((sys->millisec() / 250) & 3) == 0;
}

sqri(v: int): int
{
	return v * v;
}

floori(x, step: int): int
{
	if(step <= 0)
		return x;
	return (x / step) * step;
}

rn(n: int): int
{
	if(n <= 0)
		return 0;
	if(rand == nil)
		return sys->millisec() % n;
	return rand->rand(n);
}

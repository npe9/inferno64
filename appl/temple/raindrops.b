implement Raindrops;

# TempleOS Demo/Games/RainDrops.HC — simplified
# GAP: GrPeek onto windowpanes; we use an occupancy grid for wet glass.
# Hold 1 / 2 for hotspots; q quit

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "tk.m";

include "keyboard.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "rand.m";
	rand: Rand;

Raindrops: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

ND: con 512;

win: ref Window;
blue, red, white, black: ref Image;
dx, dy: array of int;
key1 := 0;
key2 := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS RainDrops", Wmclient->Appl);
	d := win.display;
	blue = d.color(Draw->Blue);
	red = d.color(Draw->Red);
	white = d.color(Draw->White);
	black = d.color(Draw->Black);
	dx = array[ND] of { * => -1 };
	dy = array[ND] of { * => -1 };
	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "keyup" :: "ptr" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 30);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		case k {
		16r1b or 'q' or 'Q' =>
			exit;
		'1' =>
			key1 = 1;
		'2' =>
			key2 = 1;
		Keyboard->Keyup | '1' =>
			key1 = 0;
		Keyboard->Keyup | '2' =>
			key2 = 0;
		}
	<-ticks =>
		step();
		redraw();
	}
}

step()
{
	img := win.image;
	if(img == nil)
		return;
	w := img.r.dx();
	h := img.r.dy();
	# spawn a few drops
	for(n := 0; n < 4; n++){
		for(i := 0; i < ND; i++)
			if(dy[i] < 0){
				dx[i] = rn(w);
				dy[i] = 0;
				break;
			}
	}
	for(i := 0; i < ND; i++)
		if(dy[i] >= 0){
			dy[i] += 3 + rn(3);
			if(dy[i] >= h)
				dy[i] = -1;
		}
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, white, nil, Point(0, 0));
	w := img.r.dx();
	h := img.r.dy();
	cx := w/2;
	cy := h/2;
	o := img.r.min;
	# window frame (simplified)
	img.line(Point(cx-20, cy-50).add(o), Point(cx, cy-150).add(o), 0, 0, 0, red, Point(0, 0));
	img.line(Point(cx+20, cy-50).add(o), Point(cx, cy-150).add(o), 0, 0, 0, red, Point(0, 0));
	img.line(Point(cx-100, cy-100).add(o), Point(cx, cy).add(o), 0, 0, 0, red, Point(0, 0));
	img.line(Point(cx+100, cy-100).add(o), Point(cx, cy).add(o), 0, 0, 0, red, Point(0, 0));
	img.draw(Rect((o.x+cx-20, o.y+cy+60), (o.x+cx+21, o.y+cy+81)), red, nil, Point(0, 0));
	img.line(Point(cx-200, cy).add(o), Point(cx, cy+100).add(o), 0, 0, 0, red, Point(0, 0));
	img.line(Point(cx+200, cy).add(o), Point(cx, cy+100).add(o), 0, 0, 0, red, Point(0, 0));
	if(key1)
		img.draw(Rect((o.x+cx-2, o.y+cy-2), (o.x+cx+3, o.y+cy+3)), black, nil, Point(0, 0));
	if(key2)
		img.draw(Rect((o.x+cx-2, o.y+cy+98), (o.x+cx+3, o.y+cy+103)), black, nil, Point(0, 0));
	for(i := 0; i < ND; i++)
		if(dy[i] >= 0)
			img.draw(Rect((o.x+dx[i], o.y+dy[i]), (o.x+dx[i]+1, o.y+dy[i]+1)),
				blue, nil, Point(0, 0));
	img.flush(Draw->Flushnow);
}

rn(n: int): int
{
	if(n <= 0)
		return 0;
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

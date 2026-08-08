implement Life;

# TempleOS Demo/Graphics/Life.HC — stock Inferno Wmclient+Draw port
# Paint with LMB; r=random; space=clear; q=quit

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

Life: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

W: con 100;
H: con 75;

win: ref Window;
green, black, grey: ref Image;
cur, nxt: array of array of int;
drawing := 0;

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

	win = wmclient->window(ctxt, "TempleOS Life", Wmclient->Appl);
	d := win.display;
	green = d.color(Draw->Green);
	black = d.color(Draw->Black);
	grey = d.color(Draw->Grey);

	cur = array[H] of { * => array[W] of { * => 0 } };
	nxt = array[H] of { * => array[W] of { * => 0 } };
	for(i := 0; i < 400; i++)
		cur[rn(H)][rn(W)] = 1;

	win.reshape(Rect((0, 0), (400, 300)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	redraw();

	ticks := chan of int;
	spawn timer(ticks, 80);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!')
			redraw();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		ptr(p.xy.x, p.xy.y, p.buttons);
	k := <-win.ctxt.kbd =>
		case k {
		16r1b or 'q' or 'Q' =>
			exit;
		' ' =>
			for(y := 0; y < H; y++)
				for(x := 0; x < W; x++)
					cur[y][x] = 0;
			redraw();
		'r' or 'R' =>
			for(y := 0; y < H; y++)
				for(x := 0; x < W; x++)
					cur[y][x] = 0;
			for(j := 0; j < 400; j++)
				cur[rn(H)][rn(W)] = 1;
			redraw();
		}
	<-ticks =>
		if(!drawing)
			generation();
	}
}

ptr(x, y, buttons: int)
{
	img := win.image;
	if(img == nil)
		return;
	x -= img.r.min.x;
	y -= img.r.min.y;
	cw := img.r.dx() / W;
	ch := img.r.dy() / H;
	if(cw < 1) cw = 1;
	if(ch < 1) ch = 1;
	cx := x / cw;
	cy := y / ch;
	if(buttons & 1){
		if(cx >= 0 && cx < W && cy >= 0 && cy < H){
			cur[cy][cx] = 1;
			drawing = 1;
			redraw();
		}
	}else
		drawing = 0;
}

generation()
{
	for(y := 0; y < H; y++)
		for(x := 0; x < W; x++){
			n := 0;
			for(dy := -1; dy <= 1; dy++)
				for(dx := -1; dx <= 1; dx++)
					if(dx != 0 || dy != 0){
						xx := (x + dx + W) % W;
						yy := (y + dy + H) % H;
						n += cur[yy][xx];
					}
			# TempleOS counts self in cnt; with self excluded: survive/birth on n==2
			if(cur[y][x])
				nxt[y][x] = (n == 2);
			else
				nxt[y][x] = (n == 2);
		}
	tmp := cur;
	cur = nxt;
	nxt = tmp;
	redraw();
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, black, nil, Point(0, 0));
	cw := img.r.dx() / W;
	ch := img.r.dy() / H;
	if(cw < 1) cw = 1;
	if(ch < 1) ch = 1;
	o := img.r.min;
	for(y := 0; y < H; y++)
		for(x := 0; x < W; x++)
			if(cur[y][x])
				img.draw(Rect((o.x+x*cw, o.y+y*ch), (o.x+x*cw+cw, o.y+y*ch+ch)),
					green, nil, Point(0, 0));
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

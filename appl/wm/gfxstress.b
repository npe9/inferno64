implement Gfxstress;

# Deterministic phase-oriented stress test for the Draw protocol, memdraw,
# screen damage/upload, and the optional draw3d device path.

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect, Font: import draw;
include "tk.m";
include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;
include "math/polyfill.m";
include "math/draw3d.m";
	draw3d: Draw3d;
	Vector: import draw3d;

Gfxstress: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
d: ref Display;
d3c: ref Draw3d->Context;
img, tile, alpha, mask, scratch: ref Image;
black, white, red, green, blue, yellow: ref Image;
font: ref Font;
seed := 16r13579bdf;
moveno: int;

rnd(n: int): int
{
	seed = seed * 1103515245 + 12345;
	if(seed < 0)
		seed = -seed;
	if(n <= 0)
		return 0;
	return seed % n;
}

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	draw3d = load Draw3d "/dis/math/draw3ddev.dis";
	if(draw3d == nil)
		draw3d = load Draw3d Draw3d->PATH;
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "Graphics stress", Wmclient->Appl);
	win.reshape(Rect((0, 0), (800, 600)));
	# Exact placement keeps automated runs from waiting for a pointer-driven placement.
	win.onscreen("place");
	d = win.display;
	img = win.image;
	black = d.color(Draw->Black);
	white = d.color(Draw->White);
	red = d.color(Draw->Red);
	green = d.color(Draw->Green);
	blue = d.color(Draw->Blue);
	yellow = d.color(Draw->Yellow);
	tile = d.newimage(Rect((0,0),(256,256)), img.chans, 0, Draw->Blue);
	alpha = d.newimage(Rect((0,0),(128,128)), Draw->RGBA32, 0, -12582784);
	mask = d.newimage(Rect((0,0),(128,128)), Draw->GREY8, 0, -2139062017);
	scratch = d.newimage(Rect((0,0),(512,512)), img.chans, 0, Draw->Black);
	font = Font.open(d, "/fonts/lucidasans/unicode.8.font");
	if(font == nil)
		font = Font.open(d, "*default*");

	phase := "all";
	seconds := 8;
	if(argv != nil && tl argv != nil){
		phase = hd tl argv;
		if(tl tl argv != nil)
			seconds = int hd tl tl argv;
	}
	if(seconds < 1)
		seconds = 1;
	if(phase == "all"){
		phases := "fill" :: "copy" :: "overlap" :: "alpha" :: "mask" ::
			"line" :: "ellipse" :: "poly" :: "text" :: "upload" ::
			"damage" :: "windowmove" :: "draw3d" :: "draw3dthick" :: nil;
		for(; phases != nil; phases = tl phases)
			run(hd phases, seconds);
	}else
		run(phase, seconds);
	sys->sleep(250);
}

run(phase: string, seconds: int)
{
	start := sys->millisec();
	end := start + seconds * 1000;
	ops := 0;
	for(; sys->millisec() < end;){
		case phase {
		"fill" => ops += fillbatch();
		"copy" => ops += copybatch();
		"overlap" => ops += overlapbatch();
		"alpha" => ops += alphabatch(0);
		"mask" => ops += alphabatch(1);
		"line" => ops += linebatch();
		"ellipse" => ops += ellipsebatch();
		"poly" => ops += polybatch();
		"text" => ops += textbatch();
		"upload" => ops += uploadbatch();
		"damage" => ops += damagebatch();
		"draw3d" => ops += draw3dbatch(0);
		"draw3dthick" => ops += draw3dbatch(1);
		"windowmove" => ops += windowmovebatch();
		* => sys->fprint(sys->fildes(2), "gfxstress: unknown phase %s\n", phase); return;
		}
		img.flush(Draw->Flushnow);
		if(phase == "windowmove")
			sys->sleep(16);
	}
	elapsed := sys->millisec() - start;
	sys->print("GFXSTRESS phase=%s ops=%d ms=%d ops_per_sec=%d\n",
		phase, ops, elapsed, (ops * 1000) / elapsed);
}

windowmovebatch(): int
{
	sz := win.r.size();
	spanx := win.displayr.dx() - sz.x;
	spany := win.displayr.dy() - sz.y;
	x := win.displayr.min.x;
	y := win.displayr.min.y;
	if(spanx > 0)
		x += (moveno*37)%(spanx+1);
	if(spany > 0)
		y += (moveno*23)%(spany+1);
	err := win.wmctl(sys->sprint("!reshape . -1 %d %d %d %d origin",
		x, y, x+sz.x, y+sz.y));
	if(err != nil){
		raise sys->sprint("fail:gfxstress: window move: %s", err);
	}
	img = win.image;
	moveno++;
	return 1;
}

fillbatch(): int
{
	for(i := 0; i < 400; i++){
		p := Point(rnd(780), rnd(580));
		img.draw(Rect(p, p.add((20,20))), red, nil, Point(0,0));
	}
	return 400;
}

copybatch(): int
{
	for(i := 0; i < 250; i++){
		p := Point(rnd(544), rnd(344));
		img.draw(Rect(p, p.add((256,256))), tile, nil, Point(0,0));
	}
	return 250;
}

overlapbatch(): int
{
	for(i := 0; i < 200; i++){
		r := Rect((20+rnd(300),20+rnd(200)), (420+rnd(300),320+rnd(200)));
		img.draw(r, img, nil, r.min.sub((3,3)));
	}
	return 200;
}

alphabatch(masked: int): int
{
	for(i := 0; i < 250; i++){
		p := Point(rnd(672), rnd(472));
		if(masked)
			img.gendraw(Rect(p,p.add((128,128))), alpha, Point(0,0), mask, Point(0,0));
		else
			img.draw(Rect(p,p.add((128,128))), alpha, nil, Point(0,0));
	}
	return 250;
}

linebatch(): int
{
	for(i := 0; i < 500; i++)
		img.line(Point(rnd(800),rnd(600)), Point(rnd(800),rnd(600)),
			Draw->Endsquare, Draw->Endsquare, rnd(4), yellow, Point(0,0));
	return 500;
}

ellipsebatch(): int
{
	for(i := 0; i < 300; i++){
		p := Point(30+rnd(740),30+rnd(540));
		if(i & 1)
			img.ellipse(p, 5+rnd(40), 5+rnd(30), 2, green, Point(0,0));
		else
			img.fillellipse(p, 5+rnd(40), 5+rnd(30), blue, Point(0,0));
	}
	return 300;
}

polybatch(): int
{
	for(i := 0; i < 250; i++){
		p := Point(40+rnd(720),40+rnd(520));
		a := array[] of { p.add((-30,-20)), p.add((35,-15)), p.add((20,35)), p.add((-25,30)) };
		if(i & 1)
			img.fillpoly(a, 0, red, Point(0,0));
		else
			img.poly(a, Draw->Endsquare, Draw->Endsquare, 1, white, Point(0,0));
	}
	return 250;
}

textbatch(): int
{
	if(font == nil)
		return 0;
	for(i := 0; i < 300; i++)
		img.text(Point(rnd(650), 12+rnd(570)), white, Point(0,0), font,
			"Inferno graphics stress 0123456789");
	return 300;
}

uploadbatch(): int
{
	b := array[512*64*4] of byte;
	for(i := 0; i < len b; i++)
		b[i] = byte (i + seed);
	for(i = 0; i < 16; i++){
		scratch.writepixels(Rect((0,i*32),(512,i*32+64)), b);
		img.draw(Rect((100,40+i*32),(612,104+i*32)), scratch, nil, Point(0,i*32));
	}
	return 16;
}

damagebatch(): int
{
	for(i := 0; i < 64; i++){
		p := Point(rnd(792),rnd(592));
		img.draw(Rect(p,p.add((8,8))), green, nil, Point(0,0));
		img.flush(Draw->Flushnow);
	}
	return 64;
}

draw3dbatch(thick: int): int
{
	if(draw3d == nil)
		return 0;
	if(d3c == nil){
		draw3d->init();
		d3c = draw3d->context(img);
		draw3d->viewport(d3c, 0, 0, 800, 600);
		draw3d->mode(Draw3d->PROJ);
		draw3d->identity();
		draw3d->frustum(1.5, 2.0, 100.0);
	}
	draw3d->mode(Draw3d->MODEL);
	draw3d->identity();
	draw3d->translate(0.0, 0.0, -6.0);
	draw3d->setcolour(d3c, yellow);
	for(i := 0; i < 500; i++){
		x := real(rnd(200)-100)/50.0;
		y := real(rnd(200)-100)/50.0;
		a := Vector(x,y,0.0);
		b := Vector(-x,-y,real(rnd(100))/100.0);
		draw3d->line3(d3c, a, b, thick);
	}
	return 500;
}

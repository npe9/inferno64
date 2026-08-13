implement Box;

# TempleOS Demo/Graphics/Box.HC — software 3D wireframe (Limbo math)
# Plan step 1: project cube edges with Mat4-less rotate+perspective

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "math.m";
	math: Math;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

Box: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

win: ref Window;
yellow, black, grey: ref Image;
ang := 0.0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS Box", Wmclient->Appl);
	d := win.display;
	yellow = d.color(Draw->Yellow);
	black = d.color(Draw->Black);
	grey = d.color(Draw->Grey);
	win.reshape(Rect((0, 0), (400, 400)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 30);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!')
			drawbox();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		if(k == 16r1b || k == 'q' || k == 'Q')
			exit;
	<-ticks =>
		ang += 0.04;
		drawbox();
	}
}

drawbox()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, black, nil, Point(0, 0));
	cx := img.r.min.x + img.r.dx()/2;
	cy := img.r.min.y + img.r.dy()/2;
	s := 70.0;
	pts := array[8] of Point;
	i := 0;
	for(zz := -1; zz <= 1; zz += 2)
		for(yy := -1; yy <= 1; yy += 2)
			for(xx := -1; xx <= 1; xx += 2){
				fx := real xx;
				fy := real yy;
				fz := real zz;
				ca := math->cos(ang);
				sa := math->sin(ang);
				x1 := fx*ca + fz*sa;
				z1 := -fx*sa + fz*ca;
				cb := math->cos(ang*0.7);
				sb := math->sin(ang*0.7);
				y2 := fy*cb - z1*sb;
				z2 := fy*sb + z1*cb;
				f := 3.0/(4.0+z2);
				pts[i] = Point(cx+int(x1*s*f), cy+int(y2*s*f));
				i++;
			}
	edges := array[] of {
		(0,1),(1,3),(3,2),(2,0),
		(4,5),(5,7),(7,6),(6,4),
		(0,4),(1,5),(2,6),(3,7)
	};
	for(j := 0; j < len edges; j++){
		(a, b) := edges[j];
		img.line(pts[a], pts[b], Draw->Endsquare, Draw->Endsquare, 0, yellow, Point(0, 0));
	}
	img.flush(Draw->Flushnow);
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}

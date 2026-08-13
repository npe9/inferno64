implement Hanoi;

# TempleOS Demo/Graphics/Hanoi.HC — animated Towers of Hanoi

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

Hanoi: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

DISKS: con 6;
PED: con 20;
DH: con 7;
DW: con 5;

win: ref Window;
ink: array of ref Image;
poles_x: array of int;
disks_x, disks_y, disks_pole: array of int;
quitreq := 0;
moving := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS Hanoi", Wmclient->Appl);
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

	poles_x = array[3] of int;
	disks_x = array[DISKS] of int;
	disks_y = array[DISKS] of int;
	disks_pole = array[DISKS] of int;
	win.reshape(Rect((0, 0), (640, 400)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	reset();
	redraw();
	spawn animate();

	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!')
			redraw();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		if(k == 16r1b || k == 'q' || k == 'Q'){
			quitreq = 1;
			exit;
		}
		if(k == '\n' || k == 'r' || k == 'R'){
			if(!moving){
				reset();
				spawn animate();
			}
		}
	}
}

reset()
{
	img := win.image;
	w := 640;
	if(img != nil)
		w = img.r.dx();
	for(i := 0; i < 3; i++)
		poles_x[i] = (1+i)*w/4;
	for(i = 0; i < DISKS; i++)
		disks_pole[i] = 0;
	setrest();
}

setrest()
{
	img := win.image;
	h := 400;
	if(img != nil)
		h = img.r.dy();
	for(i := 0; i < DISKS; i++){
		disks_x[i] = poles_x[disks_pole[i]];
		disks_y[i] = h - PED - (DH+1)/2 - 1 - (DH+1)*posinstk(disks_pole[i], i);
	}
}

posinstk(pole, disk: int): int
{
	res := 0;
	for(i := DISKS-1; i > disk; i--)
		if(disks_pole[i] == pole)
			res++;
	return res;
}

topdisk(pole: int): int
{
	for(i := 0; i < DISKS; i++)
		if(disks_pole[i] == pole)
			return i;
	return -1;
}

other(a, b: int): int
{
	return 3 - a - b;
}

mysleep()
{
	if(quitreq)
		return;
	sys->sleep(3);
	redraw();
}

movedisks(src, dst, num: int)
{
	if(quitreq)
		return;
	if(num > 1)
		movedisks(src, other(src, dst), num-1);
	top := topdisk(src);
	if(top < 0)
		return;
	img := win.image;
	h := 400;
	if(img != nil)
		h = img.r.dy();
	top_y := h - PED - (DH+1)/2 - (DH+1)*(DISKS+2);
	for(y := disks_y[top]; y > top_y; y--){
		disks_y[top] = y;
		mysleep();
	}
	if(src < dst)
		for(x := poles_x[src]; x <= poles_x[dst]; x++){
			disks_x[top] = x;
			mysleep();
		}
	else
		for(x = poles_x[src]; x >= poles_x[dst]; x--){
			disks_x[top] = x;
			mysleep();
		}
	disks_pole[top] = dst;
	dest_y := h - PED - (DH+1)/2 - 1 - (DH+1)*posinstk(dst, top);
	for(y = disks_y[top]; y < dest_y; y++){
		disks_y[top] = y;
		mysleep();
	}
	setrest();
	redraw();
	if(num > 1)
		movedisks(other(src, dst), dst, num-1);
}

animate()
{
	moving = 1;
	sys->sleep(400);
	movedisks(0, 2, DISKS);
	moving = 0;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, ink[15], nil, Point(0, 0));
	o := img.r.min;
	h := img.r.dy();
	for(i := 0; i < 3; i++)
		poles_x[i] = (1+i)*img.r.dx()/4;
	# pedestal
	img.draw(Rect((o.x+poles_x[0]-50, o.y+h-PED), (o.x+poles_x[2]+50, o.y+h-12)),
		ink[0], nil, Point(0, 0));
	img.draw(Rect((o.x+poles_x[0]-49, o.y+h-PED+1), (o.x+poles_x[2]+49, o.y+h-14)),
		ink[8], nil, Point(0, 0));
	for(i = 0; i < 3; i++){
		img.draw(Rect((o.x+poles_x[i]-3, o.y+h-PED-(DISKS+1)*(DH+1)),
			(o.x+poles_x[i]+4, o.y+h-PED)), ink[0], nil, Point(0, 0));
		img.draw(Rect((o.x+poles_x[i]-2, o.y+h-PED+1-(DISKS+1)*(DH+1)),
			(o.x+poles_x[i]+3, o.y+h-PED)), ink[14], nil, Point(0, 0));
	}
	for(i = 0; i < DISKS; i++){
		hw := (i+1)*DW;
		img.draw(Rect((o.x+disks_x[i]-hw, o.y+disks_y[i]-DH/2),
			(o.x+disks_x[i]+hw+1, o.y+disks_y[i]+DH/2)), ink[0], nil, Point(0, 0));
		img.draw(Rect((o.x+disks_x[i]-hw+1, o.y+disks_y[i]-DH/2+1),
			(o.x+disks_x[i]+hw, o.y+disks_y[i]+DH/2-1)), ink[i+1], nil, Point(0, 0));
	}
	img.flush(Draw->Flushnow);
}

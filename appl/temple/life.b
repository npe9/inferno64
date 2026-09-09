implement Life;

# TempleOS Demo/Graphics/Life.HC — stock Inferno Wmclient+Draw port
#
# The original runs PER-PIXEL on two full-screen 640x480 buffers
# (DCNew(GR_WIDTH,GR_HEIGHT), GrPeek/GrPlot), starting from an EMPTY
# board.  You seed it by holding button 1: the mouse loop draws
# continuous GREEN lines between successive pointer positions
# (GrLine3), with thickness 0.04*ms.speed — the kernel's ms.speed is
# pixels/second (Sqrt(dd)*time_stamp_freq/dt in MsHardSpeedSet) — so
# fast strokes are fat, slow ones thin.  Every drawing step sets
# restart=TRUE, which makes the in-progress generation scan goto
# start_over: the sim keeps running while you draw, restarting from
# the modified board.  Any key with a nonzero char exits.
#
# The rule is Terry's variant, not classic Conway: cnt counts the 3x3
# INCLUDING self; a live cell survives on cnt==3 (2 neighbours), a
# dead cell is born on cnt==2 (2 neighbours).  Border row/column
# pixels are never plotted by the scan (y,x run 1..dim-2): no
# wraparound, the edges are permanently dead (a painted border pixel
# feeds neighbour counts for one generation, then vanishes with the
# buffer swap).
#
# Timing: the original AnimateTask Sleep(50)s between generations
# (JIFFY_FREQ=1000 → 50ms) with a Yield per row, and the winmgr blits
# the current buffer at 30fps.  Here a spawned animate thread computes
# a generation (Dis-interpreted, tens of ms at this size), sleeps
# 50ms, swaps, and asks the main thread to blit — the same real-time
# cadence.
#
# GAP: original runs fullscreen borderless (WinMax, SELF_BORDER/
# SELF_FOCUS inhibited); this is a normal 640x480 Inferno window.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect, Pointer: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;
include "grpalette.m";
	grpal: Grpalette;

Life: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

W: con 640;	# GR_WIDTH
H: con 480;	# GR_HEIGHT
BW: con W/8;	# GREY1 bytes per row

win: ref Window;
green, black: ref Image;	# exact TempleOS GREEN / background
mask: ref Image;		# GREY1 blit mask, rebuilt from bits[curdc]

# dbl buf, like dc[2]: one byte per pixel, plus a parallel GREY1
# bitmap (leftmost pixel in the high bit) kept in step for blitting
boards := array[2] of array of byte;
bits := array[2] of array of byte;
curdc := 0;
restart := 0;

# mouse-line state (the MSG_MS_L_DOWN inner GetMsg loop)
drawing := 0;
lastx, lasty, lastms: int;
speed := 0.0;			# ms.speed equivalent, pixels/second

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS Life", Wmclient->Appl);
	d := win.display;
	green = d.color(grpal->value(Grpalette->GREEN));	# TempleOS GREEN
	black = d.color(grpal->value(Grpalette->BLACK));
	mask = d.newimage(Rect((0, 0), (W, H)), Draw->GREY1, 0, Draw->Black);

	# original starts from an EMPTY board — you draw the seed
	boards[0] = array[W*H] of byte;
	boards[1] = array[W*H] of byte;
	bits[0] = array[BW*H] of byte;
	bits[1] = array[BW*H] of byte;

	win.reshape(Rect((0, 0), (W, H)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	redraw();

	drawc := chan of int;
	spawn animate(drawc);
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
		if(k >= 16rE000)
			break;		# key releases / bare shifters: no char
		# original exits on ANY key with a nonzero char
		exit;
	<-drawc =>
		redraw();
	}
}

# AnimateTask: scan cur into next, restarting whenever the mouse
# loop touches the board; swap and show after a 50ms sleep
animate(drawc: chan of int)
{
	colsum := array[W] of int;
	for(;;){
		nextdc := curdc ^ 1;
		for(;;){	# start_over:
			restart = 0;
			# DCClear(dc[next_dc]): fresh zeroed buffers
			nb := array[W*H] of byte;
			nm := array[BW*H] of byte;
			boards[nextdc] = nb;
			bits[nextdc] = nm;
			aborted := 0;
			for(y := 1; y < H-1; y++){
				b := boards[curdc];
				r0 := (y-1)*W;
				r1 := y*W;
				r2 := (y+1)*W;
				for(x := 0; x < W; x++)
					colsum[x] = int b[r0+x] + int b[r1+x] + int b[r2+x];
				mrow := y*BW;
				for(x = 1; x < W-1; x++){
					cnt := colsum[x-1] + colsum[x] + colsum[x+1];
					# cnt includes self: survive on 3, birth on 2
					if(b[r1+x] != byte 0){
						if(cnt == 3){
							nb[r1+x] = byte 1;
							nm[mrow + (x>>3)] |= byte (16r80 >> (x&7));
						}
					}else{
						# cnt==3 here for the classic rules
						if(cnt == 2){
							nb[r1+x] = byte 1;
							nm[mrow + (x>>3)] |= byte (16r80 >> (x&7));
						}
					}
				}
				if(restart){	# goto start_over
					aborted = 1;
					break;
				}
			}
			if(!aborted)
				break;
		}
		sys->sleep(50);
		curdc = nextdc;
		drawc <-= 1;
	}
}

# the MSG_MS_L_DOWN handler: green line from the previous pointer
# position, thickness 0.04*ms.speed, restart the sim scan
ptr(p: ref Pointer)
{
	img := win.image;
	if(img == nil)
		return;
	x := p.xy.x - img.r.min.x;
	y := p.xy.y - img.r.min.y;
	if(p.buttons & 1){
		now := sys->millisec();
		if(!drawing){
			drawing = 1;
			lastx = x;
			lasty = y;
			lastms = now;
			speed = 0.0;
		}
		dd := (x-lastx)*(x-lastx) + (y-lasty)*(y-lasty);
		dt := now - lastms;
		if(dd > 0 && dt > 0)
			speed = real isqrt(dd) * 1000.0 / real dt;
		# HolyC F64->I64 rounds to nearest, as Limbo's int cast does
		thick := int (0.04 * speed);
		stampline(lastx, lasty, x, y, thick);
		restart = 1;
		lastx = x;
		lasty = y;
		lastms = now;
		redraw();
	}else
		drawing = 0;
}

# GrLine3 with dc->thick: Bresenham, stamping a disc of diameter
# thick.  Overlapping discs let us stamp every r/2 steps (and both
# endpoints) without gaps; thick is capped to bound the per-event
# cost in interpreted Dis.
stampline(x0, y0, x1, y1, thick: int)
{
	if(thick > 64)
		thick = 64;
	r := thick/2;
	step := r/2;
	if(step < 1)
		step = 1;
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
	e := dx - dy;
	n := 0;
	for(;;){
		if(n % step == 0 || (x0 == x1 && y0 == y1))
			stamp(x0, y0, r);
		if(x0 == x1 && y0 == y1)
			break;
		e2 := 2*e;
		if(e2 > -dy){
			e -= dy;
			x0 += sx;
		}
		if(e2 < dx){
			e += dx;
			y0 += sy;
		}
		n++;
	}
}

stamp(x, y, r: int)
{
	if(r <= 0){
		plot(x, y);
		return;
	}
	r2 := r*r;
	for(dy := -r; dy <= r; dy++)
		for(dx := -r; dx <= r; dx++)
			if(dx*dx + dy*dy <= r2)
				plot(x+dx, y+dy);
}

plot(x, y: int)
{
	if(x < 0 || x >= W || y < 0 || y >= H)
		return;
	boards[curdc][y*W+x] = byte 1;
	bits[curdc][y*BW + (x>>3)] |= byte (16r80 >> (x&7));
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, black, nil, Point(0, 0));
	mask.writepixels(mask.r, bits[curdc]);
	o := img.r.min;
	img.draw(Rect(o, (o.x+W, o.y+H)), green, mask, Point(0, 0));
	img.flush(Draw->Flushnow);
}

isqrt(n: int): int
{
	if(n <= 0)
		return 0;
	x := n;
	y := (x + 1) / 2;
	while(y < x){
		x = y;
		y = (x + n/x) / 2;
	}
	return x;
}

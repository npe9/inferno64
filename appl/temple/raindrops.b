implement Raindrops;

# TempleOS Demo/Games/RainDrops.HC — falling-water simulation.
#
# The original keeps a persistent backing DC (cur_dc): drops are plotted
# BLUE and erased WHITE as they move, and every frame the live window
# (frame lines, open/closed holes, labels, drops) is blotted into it so
# the sim GrPeeks real geometry.  Here the backing store is a byte grid
# seeded by rendering the frame into an offscreen GREY8 image and
# classifying its pixels, so grid geometry matches the drawn frame
# pixel-for-pixel; drops are kept in a GREY1 mask blitted in one draw op.
# Holding '1'/'2' opens a WHITE (passable) 5x5 hole at a funnel vertex;
# Enter restarts.
#
# Timing: the original's AnimateTask loops Sleep(10) — a 100Hz sim moving
# each drop 1px and spawning 2 drops per 10ms, with winmgr redrawing at
# ~30fps.  We tick at 30ms and run 3 exact 10ms substeps per tick, then
# redraw, preserving the real-time rates.
#
# GAP: no MenuPush pulldown (File Abort/Exit; Play Restart/OpenUpper/
# OpenLower) — the keys Esc, Enter, '1', '2' cover every menu entry.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Font, Point, Rect: import draw;

include "tk.m";

include "keyboard.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "rand.m";
	rand: Rand;
include "grpalette.m";
	grpal: Grpalette;
include "frameclock.m";
	fclock: Frameclock;

Raindrops: module
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

DROPSNUM: con 8192;		# original DROPS_NUM 0x2000

# grid cell values (stand-ins for cur_dc pixel colors)
W: con byte 0;			# WHITE: empty, passable
R: con byte 1;			# LTRED: frame
B: con byte 2;			# BLUE: drop
K: con byte 3;			# BLACK: label text

win: ref Window;
cwhite, cltred, cblue, cblack, cgrey: ref Image;
font: ref Font;

dropx := array[DROPSNUM] of int;
dropy := array[DROPSNUM] of int;
curdrop := 0;

grid: array of byte;		# live sim surface (the cur_dc stand-in)
base: array of byte;		# frame geometry only, holes closed
maskbuf: array of byte;		# GREY1-packed drop pixels
maskimg: ref Image;
gw := 0;
gh := 0;
mrow := 0;			# bytes per GREY1 row

key1 := 0;
key2 := 0;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	grpal = load Grpalette Grpalette->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	rand = load Rand Rand->PATH;
	fclock = load Frameclock Frameclock->PATH;
	fclock->init();
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	win = wmclient->window(ctxt, "TempleOS RainDrops", Wmclient->Appl);
	d := win.display;
	# exact TempleOS palette entries
	cwhite = d.color(grpal->value(Grpalette->WHITE));	# WHITE
	cltred = d.color(grpal->value(Grpalette->LTRED));	# LTRED
	cblue = d.color(grpal->value(Grpalette->BLUE));	# BLUE
	cblack = d.color(grpal->value(Grpalette->BLACK));	# BLACK
	cgrey = d.color(grpal->value(Grpalette->LTGRAY));	# mid grey for offscreen classify
	font = Font.open(d, "/fonts/lucida/unicode.8.font");
	win.reshape(Rect((0, 0), (640, 480)));	# TempleOS screen size
	win.onscreen("place");
	win.startinput("kbd" :: "keyup" :: "ptr" :: nil);

	ticks := chan of int;
	spawn fclock->ticker(ticks, 60);
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
		'\n' =>			# Play/Restart
			restart();
		'1' =>
			if(key1 == 0){
				key1 = 1;
				openhole(hole1());
			}
		'2' =>
			if(key2 == 0){
				key2 = 1;
				openhole(hole2());
			}
		Keyboard->Keyup | '1' =>
			if(key1){
				key1 = 0;
				closehole(hole1());
			}
		Keyboard->Keyup | '2' =>
			if(key2){
				key2 = 0;
				closehole(hole2());
			}
		}
	dtms := <-ticks =>
		img := win.image;
		if(img == nil)
			break;
		if(img.r.dx() != gw || img.r.dy() != gh)
			buildgeom();
		if(grid == nil)
			break;
		# The substep was always 10ms; what has changed is that the
		# number of them a frame needs is measured rather than assumed
		# to be three.
		fcacc += dtms;
		if(fcacc > FCSTEP*FCMAX)
			fcacc = FCSTEP*FCMAX;
		for(fcn := 0; fcacc >= FCSTEP && fcn < FCMAX; fcn++){
			substep();
			fcacc -= FCSTEP;
		}
		redraw();
	}
}

hole1(): Rect
{
	return Rect((gw/2-2, gh/2-2), (gw/2+3, gh/2+3));
}

hole2(): Rect
{
	return Rect((gw/2-2, gh/2+98), (gw/2+3, gh/2+103));
}

# The original's DrawFrame, minus the hold-'1'/'2' white hole rects
# (drawn separately so the offscreen classify render can omit them).
# Coordinates are the original's, relative to window centre.
drawgeom(img: ref Image, o: Point, lred, blk: ref Image)
{
	cx := gw/2;
	cy := gh/2;
	img.line(Point(cx-20, cy-50).add(o), Point(cx, cy-150).add(o), 0, 0, 0, lred, (0, 0));
	img.line(Point(cx+20, cy-50).add(o), Point(cx, cy-150).add(o), 0, 0, 0, lred, (0, 0));
	img.line(Point(cx-100, cy-100).add(o), Point(cx, cy).add(o), 0, 0, 0, lred, (0, 0));
	img.line(Point(cx+100, cy-100).add(o), Point(cx, cy).add(o), 0, 0, 0, lred, (0, 0));
	if(font != nil)
		img.text(Point(cx+10, cy).add(o), blk, (0, 0), font, "Press '1'");
	img.draw(Rect((cx-20, cy+60), (cx+21, cy+81)).addpt(o), lred, nil, (0, 0));
	img.line(Point(cx-200, cy).add(o), Point(cx, cy+100).add(o), 0, 0, 0, lred, (0, 0));
	img.line(Point(cx+200, cy).add(o), Point(cx, cy+100).add(o), 0, 0, 0, lred, (0, 0));
	if(font != nil)
		img.text(Point(cx+10, cy+100).add(o), blk, (0, 0), font, "Press '2'");
	img.line(Point(cx+400, cy+100).add(o), Point(cx-250, cy+200).add(o), 0, 0, 0, lred, (0, 0));
}

# Build base/grid from an offscreen render of the frame, so the sim's
# geometry is exactly the pixels the frame draws (UpdateCurBase's blot).
buildgeom()
{
	img := win.image;
	if(img == nil)
		return;
	gw = img.r.dx();
	gh = img.r.dy();
	mrow = draw->bytesperline(Rect((0, 0), (gw, gh)), 1);
	d := win.display;
	maskimg = d.newimage(Rect((0, 0), (gw, gh)), Draw->GREY1, 0, Draw->Black);
	grey := d.newimage(Rect((0, 0), (gw, gh)), Draw->GREY8, 0, Draw->White);
	if(maskimg == nil || grey == nil){
		sys->fprint(sys->fildes(2), "raindrops: newimage failed\n");
		grid = nil;
		return;
	}
	grey.draw(grey.r, cwhite, nil, (0, 0));
	drawgeom(grey, Point(0, 0), cgrey, cblack);
	buf := array[gw*gh] of byte;
	grey.readpixels(grey.r, buf);
	base = array[gw*gh] of byte;
	for(k := 0; k < gw*gh; k++){
		v := int buf[k];
		if(v >= 200)
			base[k] = W;
		else if(v <= 60)
			base[k] = K;
		else
			base[k] = R;
	}
	grid = array[gw*gh] of byte;
	restart();
}

# Original Init(): kill every drop; the per-frame blot then washes the
# pooled water out of cur_dc, so here we reset the grid to the geometry.
restart()
{
	if(grid == nil)
		return;
	for(i := 0; i < DROPSNUM; i++)
		dropy[i] = -1;
	curdrop = 0;
	grid[0:] = base;
	maskbuf = array[mrow*gh] of byte;
	if(key1)
		openhole(hole1());
	if(key2)
		openhole(hole2());
}

# Hold-'1'/'2': the original draws a WHITE 5x5 rect over the funnel
# vertex, and the blot makes those pixels passable, draining the pool.
openhole(r: Rect)
{
	for(y := r.min.y; y < r.max.y; y++)
		for(x := r.min.x; x < r.max.x; x++)
			if(x >= 0 && x < gw && y >= 0 && y < gh && grid[y*gw+x] == R)
				grid[y*gw+x] = W;
}

# Release: the frame lines are drawn again and blotted over the region,
# overwriting even drop pixels that had wandered onto line pixels.
closehole(r: Rect)
{
	for(y := r.min.y; y < r.max.y; y++)
		for(x := r.min.x; x < r.max.x; x++)
			if(x >= 0 && x < gw && y >= 0 && y < gh && base[y*gw+x] == R){
				if(grid[y*gw+x] == B)
					maskbuf[y*mrow + (x>>3)] &= ~(byte 16r80 >> (x&7));
				grid[y*gw+x] = R;
			}
}

peek(x, y: int): int
{
	if(x < 0 || x >= gw || y < 0 || y >= gh)
		return -1;		# off-DC: not WHITE, acts as a wall
	return int grid[y*gw+x];
}

plot(x, y: int)
{
	grid[y*gw+x] = B;
	maskbuf[y*mrow + (x>>3)] |= byte 16r80 >> (x&7);
}

erase(x, y: int)
{
	if(x < 0 || x >= gw || y < 0 || y >= gh)
		return;
	if(grid[y*gw+x] == B){
		grid[y*gw+x] = W;
		maskbuf[y*mrow + (x>>3)] &= ~(byte 16r80 >> (x&7));
	}
}

# One 10ms tick of the original AnimateTask: spawn 2 drops from the
# recycled pool, then move every live drop by the GrPeek slide rules.
substep()
{
	# spawn 2, scanning for a dead slot, else recycling a live drop
	for(s := 0; s < 2; s++){
		j := 0;
		do {
			curdrop++;
			if(curdrop >= DROPSNUM)
				curdrop = 0;
			if(dropy[curdrop] < 0)
				break;
			j++;
		} while(j <= DROPSNUM);
		if(dropy[curdrop] >= 0)	# recycled: blot would wash its pixel
			erase(dropx[curdrop], dropy[curdrop]);
		dropx[curdrop] = rn(gw);
		dropy[curdrop] = 0;
	}

	for(i := 0; i < DROPSNUM; i++){
		if(dropy[i] < 0)
			continue;
		if(dropy[i] >= gh-1){	# off the bottom: dies (blot cleans it)
			erase(dropx[i], dropy[i]);
			dropy[i] = -1;
			continue;
		}
		x0 := dropx[i];
		y0 := dropy[i];
		x1 := x0;
		y1 := y0;
		if(peek(x0, y0+1) == int W)
			y1++;
		else {
			c1 := peek(x0+1, y0);
			c2 := peek(x0-1, y0);
			if(c1 == int W && c2 != int W)
				x1++;
			else if(c2 == int W && c1 != int W)
				x1--;
			else if(c1 == int W && c2 == int W){
				c1 = peek(x0+1, y0+1);
				c2 = peek(x0-1, y0+1);
				if(c1 == int W && c2 != int W)
					x1++;
				else if(c2 == int W && c1 != int W)
					x1--;
				else if(rn(2))
					x1++;
				else
					x1--;
			}
			if(peek(x1, y1+1) == int W)
				y1++;
		}
		if(peek(x0, y0) == int B)
			erase(x0, y0);
		plot(x1, y1);
		dropx[i] = x1;
		dropy[i] = y1;
	}
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	img.draw(img.r, cwhite, nil, (0, 0));
	drawgeom(img, o, cltred, cblack);
	# hold-'1'/'2' opening: WHITE 5x5 rect at the funnel vertex
	if(key1)
		img.draw(hole1().addpt(o), cwhite, nil, (0, 0));
	if(key2)
		img.draw(hole2().addpt(o), cwhite, nil, (0, 0));
	# drops last: DrawDrops plots only where the window is WHITE, and
	# the mask never holds bits on geometry cells, so this matches
	maskimg.writepixels(maskimg.r, maskbuf);
	img.draw(img.r, cblue, maskimg, (0, 0));
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


implement Orbitalview;

# danby/orbital - what a hydrogen wave function looks like in space
#
# danby-hydrogen(1) shoots the RADIAL equation and draws u(r): how the
# electron is distributed with distance, and nothing about direction.
# That is half the answer.  The other half is the angular part, and it
# is the half with the shapes in it - the s sphere, the p dumbbells, the
# d cloverleaves, which are the pictures everyone has seen and which are
# the reason chemistry has directions in it at all.
#
# Two views of the same state, because neither is enough alone.
#
# On the left, the wave function in THREE dimensions: every place where
# |psi| is above a fraction of its largest value, drawn as a point and
# projected onto the screen, turning slowly.  That shows the shape.  It
# cannot show the inside, because a projection is a sum over everything
# behind everything else - which is exactly what makes it a projection
# and exactly what you see when you look at anything.
#
# On the right, a slice: psi in the y = 0 plane, with sign.  That shows
# what the projection hides - the radial nodes, the spheres inside
# spheres, and the change of sign from one lobe to the next that makes
# two of them cancel when they overlap.  A 2s orbital and a 1s orbital
# project to almost the same blob and are not remotely the same thing.
#
# The functions are orbital(2)'s, not this file's, so orbitaltest(1)
# checks what is drawn here rather than a copy of it.

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Font, Point, Rect: import draw;
include "tk.m";
include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;
include "math.m";
	math: Math;
include "orbital.m";
	orb: Orbital;
include "env.m";
	env: Env;

Orbitalview: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

# the state
n := 3;
l := 2;
m := 0;
charge := 1.0;
level := 0.30;			# the |psi| contour the cloud sits on

GRID: con 34;			# samples per axis for the cloud
SLICE: con 84;			# and per axis for the slice

win: ref Window;
font: ref Font;
bg, fg, grid, poscol, negcol, axiscol: ref Image;

# the cloud, rebuilt whenever the state changes
Pt: adt { x, y, z: real; s: int; };
cloud: array of Pt;
ncloud := 0;
half := 10.0;

# the slice, as signed values in -1..1
slice: array of real;

spin := 0.0;
tilt := 0.5;
paused := 0;

valid(): int
{
	am := m;
	if(am < 0)
		am = -am;
	return n >= 1 && l >= 0 && l < n && am <= l;
}

rebuild()
{
	if(!valid()){
		ncloud = 0;
		return;
	}
	half = orb->extent(n, charge);
	pk := orb->peak(n, l, m, charge, half, 22);
	if(pk <= 0.0)
		pk = 1.0;
	thr := level*pk;
	if(cloud == nil)
		cloud = array[GRID*GRID*GRID] of Pt;
	ncloud = 0;
	d := 2.0*half/real(GRID-1);
	for(i := 0; i < GRID; i++){
		x := -half + real i*d;
		for(j := 0; j < GRID; j++){
			y := -half + real j*d;
			for(k := 0; k < GRID; k++){
				z := -half + real k*d;
				v := orb->psi(n, l, m, charge, x, y, z);
				a := v;
				if(a < 0.0)
					a = -a;
				if(a < thr)
					continue;
				s := 1;
				if(v < 0.0)
					s = -1;
				cloud[ncloud++] = Pt(x, y, z, s);
			}
		}
	}
	# the slice, through y = 0
	if(slice == nil)
		slice = array[SLICE*SLICE] of real;
	ds := 2.0*half/real(SLICE-1);
	for(i = 0; i < SLICE; i++){
		x := -half + real i*ds;
		for(k := 0; k < SLICE; k++){
			z := -half + real k*ds;
			slice[k*SLICE+i] = orb->psi(n, l, m, charge, x, 0.0, z)/pk;
		}
	}
}

# `danby/orbital -c\' builds the cloud and reports what is in it,
# without opening anything.  The lobes and their signs are the whole
# content of the picture, and this is how they can be checked where
# there is no display - see orbitaltest(1), which drives it.
census()
{
	rebuild();
	sys->print("state %s n=%d l=%d m=%d points %d half %.4g\n",
		name(), n, l, m, ncloud, half);
	# how the signs fall above and below the xy plane, and inside and
	# outside the xz plane: that is what tells p_z from p_x
	(ap, an, bp, bn) := (0, 0, 0, 0);
	(xp, xn) := (0, 0);
	for(i := 0; i < ncloud; i++){
		c := cloud[i];
		if(c.z > 0.0){
			if(c.s > 0) ap++; else an++;
		}else if(c.z < 0.0){
			if(c.s > 0) bp++; else bn++;
		}
		if(c.x > 0.0){
			if(c.s > 0) xp++; else xn++;
		}
	}
	sys->print("  above z=0: %d positive %d negative\n", ap, an);
	sys->print("  below z=0: %d positive %d negative\n", bp, bn);
	sys->print("  x>0:       %d positive %d negative\n", xp, xn);
}

init(ctxt: ref Draw->Context, argv: list of string)
{
	# The maths first and the graphics afterwards, in that order and
	# not the other way round: emu-g has no Draw at all, so a program
	# that loads it before doing anything cannot be checked anywhere
	# there is no display.  `-c\' returns before the window exists.
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	orb = load Orbital Orbital->PATH;
	if(sys == nil || math == nil || orb == nil)
		raise "fail:orbital: missing module";
	orb->init();
	args := array[len argv] of string;
	na := 0;
	for(a := tl argv; a != nil; a = tl a)
		args[na++] = hd a;
	cflag := 0;
	for(i := 0; i < na; i++){
		case args[i] {
		"-c" => cflag = 1;
		"-n" => if(i+1 < na) n = int args[++i];
		"-l" => if(i+1 < na) l = int args[++i];
		"-m" => if(i+1 < na) m = int args[++i];
		}
	}
	if(cflag){
		census();
		return;
	}
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	env = load Env Env->PATH;
	if(draw == nil || wmclient == nil)
		raise "fail:orbital: no display";
	if(env != nil){
		env->clone();
		env->setenv("wmman", "danby-orbital");
	}
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "A hydrogen orbital, in space", Wmclient->Appl);
	font = Font.open(win.display, "/fonts/lucida/unicode.8.font");
	bg = win.display.color(int 16rf4f0e7ff);
	fg = win.display.color(int 16r20272cff);
	grid = win.display.color(int 16rd6d0c4ff);
	poscol = win.display.color(int 16r178f86ff);
	negcol = win.display.color(int 16rb85c38ff);
	axiscol = win.display.color(int 16r585e67ff);
	rebuild();
	win.reshape(Rect((0,0),(900,520)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	ticks := chan of int;
	spawn timer(ticks);
	redraw();
	for(;;) alt {
	c := <-win.ctl or c = <-win.ctxt.ctl =>
		win.wmctl(c);
		redraw();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		key(k);
	<-ticks =>
		if(!paused)
			spin += 0.02;
		redraw();
	}
}

# n, l and m are integers and a slider is the wrong thing for an
# integer: these step with keys, and a step that would leave a state
# that does not exist is refused rather than silently clamped.
key(k: int)
{
	case k {
	16r1b or 'q' or 'Q' =>
		win.wmctl("exit");
		exit;
	' ' =>
		paused = !paused;
		return;
	'n' =>
		if(n < 5){
			n++;
			rebuild();
		}
	'N' =>
		if(n > 1){
			n--;
			if(l >= n)
				l = n-1;
			am := m;
			if(am < 0)
				am = -am;
			if(am > l)
				m = 0;
			rebuild();
		}
	'l' =>
		if(l < n-1){
			l++;
			rebuild();
		}
	'L' =>
		if(l > 0){
			l--;
			am := m;
			if(am < 0)
				am = -am;
			if(am > l)
				m = 0;
			rebuild();
		}
	'm' =>
		if(m < l){
			m++;
			rebuild();
		}
	'M' =>
		if(m > -l){
			m--;
			rebuild();
		}
	'+' or '=' =>
		if(level > 0.06){
			level -= 0.04;
			rebuild();
		}
	'-' or '_' =>
		if(level < 0.8){
			level += 0.04;
			rebuild();
		}
	16rf00e =>			# left
		spin -= 0.1;
	16rf00f =>			# right
		spin += 0.1;
	16rf00d =>			# up
		tilt += 0.08;
	16rf00c =>			# down
		tilt -= 0.08;
	}
	redraw();
}

timer(c: chan of int)
{
	for(;;){
		sys->sleep(40);
		c <-= 1;
	}
}

# Project a point, turning about z by spin and then tilting towards the
# viewer.  Depth is returned so the caller can draw the far side first
# and let the near side cover it, which is the whole of what makes a
# cloud of points read as a solid.
project(r: Rect, p: Pt): (int, int, real)
{
	cs := math->cos(spin); sn := math->sin(spin);
	x1 := p.x*cs - p.y*sn;
	y1 := p.x*sn + p.y*cs;
	ct := math->cos(tilt); st := math->sin(tilt);
	y2 := y1*ct - p.z*st;
	z2 := y1*st + p.z*ct;
	sc := real(r.dx());
	if(r.dy() < r.dx())
		sc = real(r.dy());
	sc = sc*0.44/half;
	cx := (r.min.x+r.max.x)/2;
	cy := (r.min.y+r.max.y)/2;
	return (cx + int(x1*sc), cy - int(z2*sc), y2);
}

redraw()
{
	im := win.image;
	if(im == nil)
		return;
	im.draw(im.r, bg, nil, Point(0,0));
	r := im.r;
	split := r.min.x + (r.dx()*3)/5;
	left := Rect(r.min.add((8,26)), (split-6, r.max.y-30));
	right := Rect((split+6, r.min.y+26), r.max.sub((8,30)));
	drawcloud(im, left);
	drawslice(im, right);
	im.line((split,r.min.y+24), (split,r.max.y-28), Draw->Endsquare,
		Draw->Endsquare, 0, grid, Point(0,0));
	im.text(r.min.add((10,12)), fg, Point(0,0), font,
		sys->sprint("%s     n %d   l %d   m %d   Z %.3g   contour %.2f of the peak   %d points",
			name(), n, l, m, charge, level, ncloud));
	im.text((r.min.x+10, r.max.y-8), fg, Point(0,0), font,
		"n/N l/L m/M change the state   +/- move the contour   arrows turn it   space stops   q quits");
	im.text((split+10, r.min.y+12), fg, Point(0,0), font,
		"the y=0 slice, with sign");
	im.flush(Draw->Flushnow);
}

# The spectroscopic name, which is what anyone actually calls these.
name(): string
{
	if(!valid())
		return "not a state";
	lett := "spdfg";
	c := '?';
	if(l < len lett)
		c = lett[l];
	s := sys->sprint("%d%c", n, c);
	if(l > 0)
		s += sys->sprint(" m=%d", m);
	return s;
}

drawcloud(im: ref Image, r: Rect)
{
	im.line(((r.min.x+r.max.x)/2, r.min.y), ((r.min.x+r.max.x)/2, r.max.y),
		Draw->Endsquare, Draw->Endsquare, 0, grid, Point(0,0));
	im.line((r.min.x, (r.min.y+r.max.y)/2), (r.max.x, (r.min.y+r.max.y)/2),
		Draw->Endsquare, Draw->Endsquare, 0, grid, Point(0,0));
	if(ncloud == 0)
		return;
	# Far points first.  Without this the cloud is a flat stencil: the
	# points that happen to come last win, and which those are has
	# nothing to do with which are in front.
	for(pass := 0; pass < 2; pass++){
		for(i := 0; i < ncloud; i++){
			(px, py, d) := project(r, cloud[i]);
			if((pass == 0) != (d < 0.0))
				continue;
			if(px < r.min.x || px >= r.max.x || py < r.min.y || py >= r.max.y)
				continue;
			col := poscol;
			if(cloud[i].s < 0)
				col = negcol;
			im.draw(Rect((px,py),(px+2,py+2)), col, nil, Point(0,0));
		}
	}
}

drawslice(im: ref Image, r: Rect)
{
	if(slice == nil || !valid())
		return;
	w := r.dx();
	h := r.dy();
	if(w <= 0 || h <= 0)
		return;
	cw := w/SLICE;
	ch := h/SLICE;
	if(cw < 1)
		cw = 1;
	if(ch < 1)
		ch = 1;
	ox := r.min.x + (w - cw*SLICE)/2;
	oy := r.min.y + (h - ch*SLICE)/2;
	for(i := 0; i < SLICE; i++)
		for(k := 0; k < SLICE; k++){
			v := slice[k*SLICE+i];
			a := v;
			if(a < 0.0)
				a = -a;
			if(a < 0.02)
				continue;
			# a in 0..1 towards the lobe's colour, so the sign is a
			# hue and the size is how far it has got from the paper
			t := a;
			if(t > 1.0)
				t = 1.0;
			col := blend(v > 0.0, t);
			x := ox + i*cw;
			y := oy + (SLICE-1-k)*ch;
			im.draw(Rect((x,y),(x+cw,y+ch)), col, nil, Point(0,0));
		}
	im.line((ox, oy+ch*SLICE/2), (ox+cw*SLICE, oy+ch*SLICE/2),
		Draw->Endsquare, Draw->Endsquare, 0, axiscol, Point(0,0));
	im.line((ox+cw*SLICE/2, oy), (ox+cw*SLICE/2, oy+ch*SLICE),
		Draw->Endsquare, Draw->Endsquare, 0, axiscol, Point(0,0));
}

# A tint between the paper and one of the two lobe colours.  Mixed here
# and kept opaque: these are drawn as solid cells, so a translucent
# colour would composite twice wherever two cells touch.
cache: array of ref Image;
CACHEN: con 16;

blend(pos: int, t: real): ref Image
{
	if(cache == nil)
		cache = array[2*CACHEN] of ref Image;
	k := int(t*real(CACHEN-1)+0.5);
	if(k < 0)
		k = 0;
	if(k >= CACHEN)
		k = CACHEN-1;
	idx := k;
	if(!pos)
		idx += CACHEN;
	if(cache[idx] != nil)
		return cache[idx];
	(br, bgc, bb) := (16rf4, 16rf0, 16re7);
	(lr, lg, lb) := (16r17, 16r8f, 16r86);
	if(!pos)
		(lr, lg, lb) = (16rb8, 16r5c, 16r38);
	f := real k/real(CACHEN-1);
	cr := int(real br + (real lr - real br)*f);
	cg := int(real bgc + (real lg - real bgc)*f);
	cb := int(real bb + (real lb - real bb)*f);
	v := (cr<<24)|(cg<<16)|(cb<<8)|16rff;
	cache[idx] = win.display.color(v);
	return cache[idx];
}

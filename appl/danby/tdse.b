implement Tdse;

# danby/tdse - a wave packet meeting a barrier, solved as it happens
#
# Every other quantum model in danby(1) draws an answer that was worked
# out in advance: a standing state, a steady beam, or a formula
# evaluated along an axis.  danby/packet comes closest to motion and
# still only substitutes the known width at each instant.  This one
# actually solves the time-dependent Schrodinger equation, step by step,
# and draws the result as it appears - the packet arrives at the
# barrier, and part of it goes through while part comes back.
#
# In atomic units, with psi = u + iv,
#
#	du/dt = -(1/2) v'' + V v
#	dv/dt = +(1/2) u'' - V u
#
# which is a two-field problem of exactly the shape pde(2)'s
# "equation hoc" takes, with the potential written as a function of x.
#
# Two things about the numerics are load-bearing and neither is
# optional.  The step is STAGGERED - v is advanced using the u that has
# just been computed, not the one it started with - because the
# eigenvalues here are purely imaginary and advancing both together
# multiplies every mode by sqrt(1+(lambda h)^2) at every step, for any h
# however small.  That is not a step-size problem; a simultaneous update
# cannot solve this equation at all.  And the mesh is Nx by 2 rather
# than Nx by 1, because pde(2) wants at least two rows each way; the
# two rows are seeded identically and clamped, so the y part of the
# Laplacian is exactly zero and the problem is honestly one-dimensional.
#
# What to watch: the packet splits.  Not "some particles go through and
# some do not" - one packet arrives and two leave, and the numbers at
# the bottom are what fraction of it went each way.  Compare them with
# danby-tunnel(1), which gives the same two numbers from a formula.

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Font, Point, Rect: import draw;
include "tk.m";
include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "math.m";
	math: Math;
include "pde.m";
	pde: Pde;
include "env.m";
	env: Env;

Tdse: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };


win: ref Window;
font: ref Font;
bg, fg, grid, wavecol, denscol, barcol, axiscol: ref Image;

prob: ref Pde->Problem;
paused := 0;
t := 0.0;

# the sliders, and where they start
barrier := 10.0;		# V, the height of the wall
width := 0.6;			# and how thick it is
momentum := 4.0;		# the packet's k, so its energy is k^2/2
spread := 1.2;			# its initial width


# The mesh comes from the spec file, so these read it off the problem
# rather than repeating it.  A different mesh line in the file needs no
# change here.
nx(): int  { return prob.field.nx; }
dx(): real { return prob.field.dx; }
xmax(): real { return real prob.field.nx*prob.field.dx; }
xb(): real { return prob.hocmod->symbol("xb").val; }

SPECFILE: con "/lib/danby/tdse.pde";

# The equation is a text file, not a string in here, so it can be read
# and changed without a compiler - and so a test can run the SAME text
# the program runs rather than a copy of it that could drift.  The two
# sliders that appear in it are overridden through the problem's own hoc
# instance afterwards, which is why the file needs no substitution.
readspec(): string
{
	iob := bufio->open(SPECFILE, Bufio->OREAD);
	if(iob == nil){
		sys->fprint(sys->fildes(2), "danby/tdse: %s: %r\n", SPECFILE);
		raise "fail:spec";
	}
	s := "";
	while((l := iob.gets('\n')) != nil)
		s += l;
	return s;
}

reset()
{
	(p, err) := pde->newproblem(readspec());
	if(err != nil){
		sys->fprint(sys->fildes(2), "danby/tdse: %s\n", err);
		raise "fail:spec";
	}
	prob = p;
	# the sliders, into the problem's own hoc variables
	prob.hocmod->setvar("v0", barrier);
	prob.hocmod->setvar("bw", width);
	nx := prob.field.nx;
	dx := prob.field.dx;
	x0 := real nx*dx*0.25;
	for(i := 0; i < nx; i++){
		x := real i*dx;
		g := math->exp(-(x-x0)*(x-x0)/(4.0*spread*spread));
		for(r := 0; r < 2; r++){
			pde->set(prob.field, i, r, g*math->cos(momentum*x));
			pde->set(prob.fieldb, i, r, g*math->sin(momentum*x));
		}
	}
	t = 0.0;
}

# What fraction of the packet is each side of the barrier, and how much
# there is altogether - which must not change, and is the one number
# that says the solver is still solving.
shares(): (real, real, real)
{
	(left, right, tot) := (0.0, 0.0, 0.0);
	for(i := 0; i < nx(); i++){
		u := pde->get(prob.field, i, 0);
		v := pde->get(prob.fieldb, i, 0);
		d := (u*u+v*v)*dx();
		tot += d;
		if(real i*dx() < xb())
			left += d;
		else
			right += d;
	}
	if(tot <= 0.0)
		return (0.0, 0.0, 0.0);
	return (left/tot, right/tot, tot);
}

step()
{
	pde->step(prob, 0.004);
	t += 0.004;
}

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	bufio = load Bufio Bufio->PATH;
	math = load Math Math->PATH;
	pde = load Pde Pde->PATH;
	env = load Env Env->PATH;
	if(sys == nil || draw == nil || wmclient == nil || math == nil || pde == nil || bufio == nil)
		raise "fail:tdse: missing module";
	pde->init();
	if(env != nil){
		env->clone();
		env->setenv("wmman", "danby-tdse");
	}
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "A wave packet meeting a barrier", Wmclient->Appl);
	font = Font.open(win.display, "/fonts/lucida/unicode.8.font");
	bg = win.display.color(int 16rf4f0e7ff);
	fg = win.display.color(int 16r20272cff);
	grid = win.display.color(int 16rd6d0c4ff);
	wavecol = win.display.color(int 16r178f86ff);
	denscol = win.display.color(int 16rd5cad6ff);
	barcol = win.display.color(int 16rb85c38ff);
	axiscol = win.display.color(int 16r585e67ff);
	reset();
	win.reshape(Rect((0,0),(820,480)));
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
		pointer(p);
	k := <-win.ctxt.kbd =>
		case k {
		16r1b or 'q' or 'Q' =>
			win.wmctl("exit");
			return;
		' ' =>
			paused = !paused;
		'r' or 'R' =>
			reset();
		'.' =>
			if(paused)
				step();
		}
		redraw();
	<-ticks =>
		if(!paused)
			for(i := 0; i < 3; i++)
				step();
		redraw();
	}
}

timer(c: chan of int)
{
	for(;;){
		sys->sleep(25);
		c <-= 1;
	}
}

# Four tracks along the bottom, dragged with button 1.  Changing any of
# them restarts: the barrier is in the equations and the packet is an
# initial condition, so neither can be altered part way through a run
# and still mean anything.
TRACKS: con 4;
trackname := array[] of {"barrier V", "width", "momentum k", "packet width"};
trackmax := array[] of {20.0, 3.0, 8.0, 3.0};

trackvals(): array of real
{
	return array[] of {barrier, width, momentum, spread};
}

pointer(p: ref Draw->Pointer)
{
	if(!(p.buttons&1) || win.image == nil)
		return;
	r := win.image.r;
	ty := r.max.y-34;
	if(p.xy.y < ty)
		return;
	w := r.dx()/TRACKS;
	j := (p.xy.x-r.min.x)/w;
	if(j < 0 || j >= TRACKS)
		return;
	f := real(p.xy.x-r.min.x-j*w)/real(w-12);
	if(f < 0.0)
		f = 0.0;
	if(f > 1.0)
		f = 1.0;
	v := f*trackmax[j];
	case j {
	0 => barrier = v;
	1 => width = v;
	2 => momentum = v;
	3 => spread = v;
	}
	if(width < 0.05)
		width = 0.05;
	if(spread < 0.2)
		spread = 0.2;
	reset();
	redraw();
}

mapx(r: Rect, x: real): int
{
	return r.min.x + int(x/xmax()*real r.dx());
}

redraw()
{
	im := win.image;
	if(im == nil)
		return;
	im.draw(im.r, bg, nil, Point(0,0));
	r := Rect(im.r.min.add((10,26)), im.r.max.sub((10,44)));
	mid := (r.min.y+r.max.y)/2;

	# the barrier, behind everything, as a band across the full height
	bl := mapx(r, xb() - width/2.0);
	br := mapx(r, xb() + width/2.0);
	if(br <= bl)
		br = bl+1;
	im.draw(Rect((bl,r.min.y),(br,r.max.y)), grid, nil, Point(0,0));

	# |psi|^2, filled down to the axis.  fillpoly wants the polygon
	# closed explicitly - handed an open one it fills nothing at all,
	# silently - and the closing point is the last thing here.
	dens := array[nx()+3] of Point;
	n := 0;
	scale := real(r.dy())/2.0*0.9;
	peak := 0.0;
	for(i := 0; i < nx(); i++){
		u := pde->get(prob.field, i, 0);
		v := pde->get(prob.fieldb, i, 0);
		d := u*u+v*v;
		if(d > peak)
			peak = d;
	}
	if(peak <= 0.0)
		peak = 1.0;
	for(i = 0; i < nx(); i++){
		u := pde->get(prob.field, i, 0);
		v := pde->get(prob.fieldb, i, 0);
		d := (u*u+v*v)/peak;
		dens[n++] = (mapx(r, real i*dx()), mid - int(d*scale));
	}
	dens[n++] = (mapx(r, real(nx()-1)*dx()), mid);
	dens[n++] = (mapx(r, 0.0), mid);
	dens[n++] = dens[0];
	im.fillpoly(dens[0:n], ~0, denscol, Point(0,0));

	# the real part of psi, which is what actually oscillates
	wave := array[nx()] of Point;
	for(i = 0; i < nx(); i++){
		u := pde->get(prob.field, i, 0);
		wave[i] = (mapx(r, real i*dx()), mid - int(u/math->sqrt(peak)*scale*0.5));
	}
	im.poly(wave, Draw->Endsquare, Draw->Endsquare, 0, wavecol, Point(0,0));

	im.line((r.min.x,mid), (r.max.x,mid), Draw->Endsquare, Draw->Endsquare,
		0, axiscol, Point(0,0));
	im.line((bl,r.min.y), (bl,r.max.y), Draw->Endsquare, Draw->Endsquare,
		0, barcol, Point(0,0));
	im.line((br,r.min.y), (br,r.max.y), Draw->Endsquare, Draw->Endsquare,
		0, barcol, Point(0,0));

	(left, right, tot) := shares();
	state := "running";
	if(paused)
		state = "paused";
	im.text(im.r.min.add((10,12)), fg, Point(0,0), font,
		sys->sprint("%s   t %.2f   E %.3g   V %.3g   before the wall %.3f   past it %.3f   total %.4f",
			state, t, momentum*momentum/2.0, barrier, left, right, tot));
	drawtracks(im);
	im.flush(Draw->Flushnow);
}

drawtracks(im: ref Image)
{
	r := im.r;
	vals := trackvals();
	w := r.dx()/TRACKS;
	y := r.max.y-24;
	for(j := 0; j < TRACKS; j++){
		x := r.min.x + j*w;
		im.line((x+4,y), (x+w-8,y), Draw->Endsquare, Draw->Endsquare,
			1, grid, Point(0,0));
		k := x+4 + int(vals[j]/trackmax[j]*real(w-12));
		im.ellipse((k,y), 4, 4, 0, barcol, Point(0,0));
		im.text((x+4,r.max.y-6), fg, Point(0,0), font,
			sys->sprint("%s %.3g", trackname[j], vals[j]));
	}
}

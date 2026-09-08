implement Orblab;

# See module/orblab.m for the script vocabulary and why this is a library
# the model calls rather than a module that loads the model back.
# Everything below except parsing is appl/temple/orbital.b's own window,
# integrator, trails and controls, unchanged in behaviour - including
# draworbits(), whose comment explains why the focus body is pinned at
# view centre - with the model side coming from dynsys(2) instead of from
# eleven entry points on a loaded module.

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Font, Point, Rect: import draw;
include "tk.m";
include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;
include "numerics.m";
	numerics: Numerics;
include "plot.m";
	plot: Plot;
	Plotter: import plot;
include "env.m";
	env: Env;
include "math.m";
	math: Math;
# orblab.m includes dynsys.m itself, so a model needs only sys.m, draw.m
# and this one; do NOT include dynsys.m here as well.
include "orblab.m";
	dynsys: Dynsys;
	Model: import dynsys;
	Expr: import Hoc;

Ntrail: con 1600;

win: ref Window;
font: ref Font;
bg, fg, grid, firstcolour, secondcolour: ref Image;
bodycolour: array of ref Image;
model: ref Model;
bodylabels: array of string;
massexprs: array of ref Expr;
mass: array of real;
state: array of real;
work: ref Numerics->Workspace;
graph: ref Plotter;
trail: array of array of real;
trailcount := 0;
trailnext := 0;
t := 0.0;
paused := 0;
finished := 0;
observationmaximum := array[] of {1.0,1.0};
title := "";
manual := "";

loadparsemods(): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(sys == nil)
		return "orblab: cannot load Sys";
	if(dynsys == nil)
		dynsys = load Dynsys Dynsys->PATH;
	if(dynsys == nil)
		return sys->sprint("orblab: cannot load %s: %r", Dynsys->PATH);
	return nil;
}

loaddrawmods(): string
{
	if(draw == nil)
		draw = load Draw Draw->PATH;
	if(numerics == nil)
		numerics = load Numerics Numerics->PATH;
	if(plot == nil)
		plot = load Plot Plot->PATH;
	if(wmclient == nil)
		wmclient = load Wmclient Wmclient->PATH;
	if(draw == nil || numerics == nil || plot == nil || wmclient == nil)
		return "orblab: a drawing module is missing";
	return nil;
}

parse(spec: string): (ref Model, array of string, array of ref Expr, string)
{
	if((e := loadparsemods()) != nil)
		return (nil, nil, nil, e);
	m := dynsys->newmodel();
	ttl := "";
	man := "";
	labels: array of string;
	exprs: array of ref Expr;
	(nil, lines) := sys->tokenize(spec, "\n");
	lineno := 0;
	for(; lines != nil; lines = tl lines){
		lineno++;
		(nwords, a) := sys->tokenize(hd lines, " \t\r");
		if(nwords == 0 || (hd a)[0] == '#')
			continue;
		w := array[nwords] of string;
		for(i := 0; a != nil; (a, i) = (tl a, i+1))
			w[i] = hd a;
		case w[0] {
		"title" =>
			if(nwords < 2)
				return (nil, nil, nil, lineerr(lineno, "title: usage: title TEXT..."));
			ttl = joinfrom(w, 1);
			continue;
		"manual" =>
			if(nwords != 2)
				return (nil, nil, nil, lineerr(lineno, "manual: usage: manual PAGE"));
			man = w[1];
			continue;
		"body" =>
			if(nwords < 3)
				return (nil, nil, nil, lineerr(lineno, "body: usage: body NAME EXPR..."));
			(e2, err2) := m.hocmod->compileeqn(joinfrom(w, 2));
			if(err2 != nil)
				return (nil, nil, nil, lineerr(lineno, "body "+w[1]+": "+err2));
			labels = growstrs(labels, w[1]);
			exprs = growexprs(exprs, e2);
			continue;
		}
		(claimed, err) := dynsys->cmd(m, w);
		if(err != nil)
			return (nil, nil, nil, lineerr(lineno, err));
		if(!claimed)
			return (nil, nil, nil, lineerr(lineno, "unknown command "+w[0]));
	}
	if((err := dynsys->check(m)) != nil)
		return (nil, nil, nil, err);
	if(ttl == "")
		return (nil, nil, nil, "spec has no title command");
	if(len labels == 0)
		return (nil, nil, nil, "spec has no body commands");
	if(len m.statenames != 4*len labels)
		return (nil, nil, nil, sys->sprint(
			"%d bodies need %d states - x, y and the two velocities each - and this spec has %d",
			len labels, 4*len labels, len m.statenames));
	if(len m.observablelabels != 2)
		return (nil, nil, nil, sys->sprint(
			"spec has %d observable commands, needs exactly 2",
			len m.observablelabels));

	title = ttl;
	manual = man;
	return (m, labels, exprs, nil);
}

# The parameters are bound by dynsys->initialstate(), so this must follow
# one; a mass is an expression because in this family a slider usually IS
# a mass.
masses(m: ref Model, exprs: array of ref Expr): array of real
{
	r := array[len exprs] of real;
	for(i := 0; i < len exprs; i++)
		r[i] = m.hocmod->eval(exprs[i]);
	return r;
}

growstrs(a: array of string, s: string): array of string
{
	r := array[len a + 1] of string;
	for(i := 0; i < len a; i++)
		r[i] = a[i];
	r[len a] = s;
	return r;
}

growexprs(a: array of ref Expr, e: ref Expr):
		array of ref Expr
{
	r := array[len a + 1] of ref Expr;
	for(i := 0; i < len a; i++)
		r[i] = a[i];
	r[len a] = e;
	return r;
}

lineerr(n: int, s: string): string
{
	return sys->sprint("spec line %d: %s", n, s);
}

joinfrom(w: array of string, from: int): string
{
	s := "";
	for(i := from; i < len w; i++){
		if(i > from)
			s += " ";
		s += w[i];
	}
	return s;
}

# A label is one word in the script, because a parameter label is also
# the symbol its expressions use; an underscore displays as a space.
label(name: string): string
{
	s := name;
	for(i := 0; i < len s; i++)
		if(s[i] == '_')
			s[i] = ' ';
	return s;
}


run(ctxt: ref Draw->Context, name, spec: string): string
{
	err: string;
	(model, bodylabels, massexprs, err) = parse(spec);
	if(err != nil)
		return err;
	if((err = loaddrawmods()) != nil)
		return err;
	env = load Env Env->PATH;
	if(env != nil){
		env->clone();
		page := manual;
		if(page == "")
			page = "danby-"+name;
		env->setenv("wmman", page);
	}
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, title, Wmclient->Appl);
	font = Font.open(win.display, "/fonts/lucida/unicode.8.font");
	bg = win.display.color(int 16r080d18ff);
	fg = win.display.color(int 16re7edf7ff);
	grid = win.display.color(int 16r394457ff);
	firstcolour = win.display.color(int 16r4ec9b0ff);
	secondcolour = win.display.color(int 16rf2b84bff);
	bodycolour = array[] of {
		win.display.color(int 16rf2b84bff),
		win.display.color(int 16r4ec9b0ff),
		win.display.color(int 16r70a5ffff),
		win.display.color(int 16re77c8eff),
		win.display.color(int 16rc792eaff),
		win.display.color(int 16r9dd274ff)
	};
	graph = plot->new(win.image, font);
	graph.cmd("table history time first second -capacity 20000");
	graph.cmd("colour foreground 16re7edf7ff\n"+
		"colour grid 16r394457ff\n"+
		"colour first 16r4ec9b0ff\n"+
		"colour second 16rf2b84bff");
	trail = array[Ntrail] of array of real;
	reset();
	win.reshape(Rect((0,0),(920,580)));
	win.onscreen("place");
	win.startinput("kbd"::"ptr"::nil);
	ticks := chan of int;
	spawn timer(ticks);
	redraw();
	for(;;) alt {
	ctl := <-win.ctl or ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(ctl == "exit")
			return nil;
		redraw();
	pointer := <-win.ctxt.ptr =>
		win.pointer(*pointer);
		handlepointer(pointer);
		redraw();
	key := <-win.ctxt.kbd =>
		case key {
		16r1b or 'q' or 'Q' =>
			win.wmctl("exit");
			return nil;
		' ' => if(!finished) paused = !paused;
		'r' or 'R' => reset();
		'.' => if(paused && !finished) step();
		}
	<-ticks =>
		if(!paused && !finished)
			for(i := 0; i < 4 && !finished; i++)
				step();
		redraw();
	}
}

rhs(rhsTime: real, values, derivative: array of real)
{
	dynsys->rhs(model, rhsTime, values, derivative);
}

reset()
{
	state = dynsys->initialstate(model);
	mass = masses(model, massexprs);	# parameters are bound by the line above
	work = numerics->workspace(len state);
	t = 0.0;
	paused = 0;
	finished = 0;
	trailcount = 0;
	trailnext = 0;
	observationmaximum[0] = 1.0;
	observationmaximum[1] = 1.0;
	graph.cmd("history clear");
	record();
}

step()
{
	numerics->rk4(work, rhs, t, 0.0025, state);
	t += 0.0025;
	if(t >= model.maxtime){
		finished = 1;
		paused = 1;
	}
	record();
}

record()
{
	positions := array[2*len mass] of real;
	for(i := 0; i < len mass; i++){
		positions[2*i] = state[4*i];
		positions[2*i+1] = state[4*i+1];
	}
	trail[trailnext] = positions;
	trailnext = (trailnext+1)%Ntrail;
	if(trailcount < Ntrail)
		trailcount++;
	values := dynsys->observables(model, state);
	for(i = 0; i < 2; i++){
		magnitude := values[i];
		if(magnitude < 0.0)
			magnitude = -magnitude;
		if(magnitude*1.15 > observationmaximum[i])
			observationmaximum[i] = magnitude*1.15;
	}
	graph.cmd(sys->sprint("history append %.17g %.17g %.17g",
		t, values[0], values[1]));
}

handlepointer(pointer: ref Draw->Pointer)
{
	if(!(pointer.buttons&1) || win.image == nil)
		return;
	r := win.image.r;
	if(pointer.xy.y <= r.max.y-55)
		return;
	n := len model.parameter;
	width := r.dx()/n;
	which := (pointer.xy.x-r.min.x)/width;
	if(which < 0)
		which = 0;
	if(which >= n)
		which = n-1;
	fraction := real(pointer.xy.x-(r.min.x+which*width))/real(width);
	if(fraction < 0.01)
		fraction = 0.01;
	model.parameter[which] = model.minima[which]+
		(model.maxima[which]-model.minima[which])*fraction;
	reset();
}

redraw()
{
	im := win.image;
	if(im == nil)
		return;
	im.draw(im.r, bg, nil, Point(0,0));
	content := Rect(im.r.min.add((25,38)), im.r.max.sub((18,62)));
	middle := content.min.x+(content.dx()*3)/5;
	orbitview := Rect(content.min, (middle-20,content.max.y));
	draworbits(im, orbitview);
	graph.image = im;
	graph.cmd("clear");
	graph.cmd("content margin 25 38 18 62\n"+
		"split content x orbitview 3 plotview 2 gutter 55\n"+
		"view diagnostics plotview");
	tmax := t;
	if(tmax < 2.0)
		tmax = 2.0;
	ymax := observationmaximum[0];
	if(observationmaximum[1] > ymax)
		ymax = observationmaximum[1];
	graph.cmd(sys->sprint("scale diagnostics x 0 %.8g", tmax));
	graph.cmd(sys->sprint("scale diagnostics y %.8g %.8g reverse", -ymax, ymax));
	graph.cmd("axis diagnostics x time");
	graph.cmd("axis diagnostics y value");
	graph.cmd("line diagnostics history x time y first colour first width 2");
	graph.cmd("line diagnostics history x time y second colour second width 2");
	graph.draw();
	values := dynsys->observables(model, state);
	status := "running";
	if(paused)
		status = "paused";
	if(finished)
		status = "complete";
	im.text(im.r.min.add((10,18)), fg, Point(0,0), font,
		sys->sprint("%s   %s   t %.3g   %s %.4g   %s %.4g",
			title, status, t, label(model.observablelabels[0]), values[0],
			label(model.observablelabels[1]), values[1]));
	for(i := 0; i < len model.parameter; i++)
		drawparameter(im, i, model.paramlabels[i],
			model.parameter[i], model.maxima[i]);
	im.flush(Draw->Flushnow);
}

# draworbits keeps the most massive body (the "planet") pinned at the
# centre of view and lets the SCALE do all the work as the orbit grows or
# shrinks - not an independent x/y bounding box mapped straight onto the
# view rect, which was the bug: that box's own centre drifts as the
# trail's extent changes even though the planet's own position hasn't
# moved, so the planet visibly wandered around the screen instead of
# staying put while the view zoomed.  A single uniform scale (not
# separate x and y ranges) also keeps a circular orbit looking circular
# instead of stretched to fill whichever axis has more room.
draworbits(im: ref Image, view: Rect)
{
	focus := 0;
	for(i := 1; i < len mass; i++)
		if(mass[i] > mass[focus])
			focus = i;

	# extent: the largest distance any trail point sits from the FOCUS
	# body's own position at that same instant - not from its current
	# position, so a system whose "planet" is not perfectly fixed still
	# reads correctly.
	extent := 0.1;
	for(k := 0; k < trailcount; k++){
		index := trailnext-trailcount+k;
		if(index < 0)
			index += Ntrail;
		positions := trail[index];
		fx := positions[2*focus];
		fy := positions[2*focus+1];
		for(i = 0; i < len mass; i++){
			dx := positions[2*i]-fx;
			if(dx < 0.0)
				dx = -dx;
			if(dx > extent)
				extent = dx;
			dy := positions[2*i+1]-fy;
			if(dy < 0.0)
				dy = -dy;
			if(dy > extent)
				extent = dy;
		}
	}
	extent *= 1.24;

	half := view.dx();
	if(view.dy() < half)
		half = view.dy();
	scale := real(half)/(2.0*extent);
	centre := Point((view.min.x+view.max.x)/2, (view.min.y+view.max.y)/2);

	for(i = 0; i < len mass; i++){
		haveprevious := 0;
		previous := Point(0,0);
		for(k = 0; k < trailcount; k++){
			index := trailnext-trailcount+k;
			if(index < 0)
				index += Ntrail;
			positions := trail[index];
			point := project(centre, scale, positions[2*i], positions[2*i+1],
				positions[2*focus], positions[2*focus+1]);
			if(haveprevious)
				im.line(previous, point, 0, 0, 1,
					bodycolour[i%len bodycolour], Point(0,0));
			previous = point;
			haveprevious = 1;
		}
		point := project(centre, scale, state[4*i], state[4*i+1],
			state[4*focus], state[4*focus+1]);
		radius := 4;
		if(mass[i] > 0.1)
			radius = 7;
		im.ellipse(point, radius, radius, 0, bodycolour[i%len bodycolour], Point(0,0));
		im.text(point.add((radius+3,-3)), fg, Point(0,0), font, label(bodylabels[i]));
	}
}

# (x,y) relative to the focus body's own position (cx,cy) at the SAME
# instant, scaled uniformly and offset from view centre - so (cx,cy)
# itself always lands exactly on centre, every frame, regardless of
# scale: the focus body never moves on screen, only the scale changes.
project(centre: Point, scale: real, x, y, cx, cy: real): Point
{
	return centre.add((int((x-cx)*scale), -int((y-cy)*scale)));
}

drawparameter(im: ref Image, index: int, name: string, value, maximum: real)
{
	width := im.r.dx()/len model.parameter;
	x := im.r.min.x+index*width;
	y := im.r.max.y-40;
	im.line((x+4,y),(x+width-6,y), 0, 0, 2, grid, Point(0,0));
	fraction := (value-model.minima[index])/(maximum-model.minima[index]);
	knob := x+4+int(fraction*real(width-10));
	im.ellipse((knob,y), 4, 4, 0, fg, Point(0,0));
	im.text((x+4,im.r.max.y-17), fg, Point(0,0), font,
		sys->sprint("%s %.3g", label(name), value));
}

timer(ticks: chan of int)
{
	for(;;){
		sys->sleep(25);
		ticks <-= 1;
	}
}

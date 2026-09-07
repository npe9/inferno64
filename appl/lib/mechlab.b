implement Mechlab;

# See module/mechlab.m for the script vocabulary and why this is a
# library the model calls rather than a module that loads the model
# back.  Everything below except parsing is appl/temple/mechanism.b's
# own window, integrator and controls, unchanged in behaviour: the
# model side of it now comes from dynsys(2) instead of from thirteen
# entry points on a loaded module.

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
# mechlab.m includes dynsys.m itself, so that a model file needs only
# sys.m, draw.m and this one - do NOT include dynsys.m here as well,
# Limbo has no include guard and would see Hoc and Dynsys twice.
include "mechlab.m";
	dynsys: Dynsys;
	Model: import dynsys;

win: ref Window;
font: ref Font;
bg, fg, grid, bodycolour, firstcolour, secondcolour: ref Image;
model: ref Model;
links: array of int;
title := "";
state: array of real;
work: ref Numerics->Workspace;
graph: ref Plotter;
t := 0.0;
paused := 0;
finished := 0;
observationmaximum := array[] of {1.0,1.0};
ControlBandH: con 76;

# parse() needs no more than these two, so that a test can check a
# model's numbers under emu-g, which has no display and cannot load the
# drawing side at all.
loadparsemods(): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(sys == nil)
		return "mechlab: cannot load Sys";
	if(dynsys == nil)
		dynsys = load Dynsys Dynsys->PATH;
	if(dynsys == nil)
		return sys->sprint("mechlab: cannot load %s: %r", Dynsys->PATH);
	return nil;
}

loaddrawmods(): string
{
	if(draw == nil)
		draw = load Draw Draw->PATH;
	if(draw == nil)
		return "mechlab: cannot load Draw";
	if(numerics == nil)
		numerics = load Numerics Numerics->PATH;
	if(numerics == nil)
		return sys->sprint("mechlab: cannot load %s: %r", Numerics->PATH);
	if(plot == nil)
		plot = load Plot Plot->PATH;
	if(plot == nil)
		return sys->sprint("mechlab: cannot load %s: %r", Plot->PATH);
	if(wmclient == nil)
		wmclient = load Wmclient Wmclient->PATH;
	if(wmclient == nil)
		return sys->sprint("mechlab: cannot load %s: %r", Wmclient->PATH);
	return nil;
}

# parse: the whole of the script, and nothing else - no window, no
# integration.  mechlabtest(1) uses this to check a model's numbers with
# no display, which is the only kind of check worth having for the
# equations (see doc/temple-plan.md on what starting a demo proves).
parse(spec: string): (ref Model, array of int, string)
{
	if((e := loadparsemods()) != nil)
		return (nil, nil, e);
	m := dynsys->newmodel();
	lnk: list of int;
	nlink := 0;
	ttl := "";
	man := "";
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
				return (nil, nil, lineerr(lineno, "title: usage: title TEXT..."));
			ttl = joinfrom(w, 1);
			continue;
		"manual" =>
			if(nwords != 2)
				return (nil, nil, lineerr(lineno, "manual: usage: manual PAGE"));
			man = w[1];
			continue;
		"link" =>
			if(nwords != 3)
				return (nil, nil, lineerr(lineno, "link: usage: link NAME NAME"));
			ai := nameindex(m.pointnames, w[1]);
			bi := nameindex(m.pointnames, w[2]);
			if(ai < 0)
				return (nil, nil, lineerr(lineno, "link: no point named "+w[1]));
			if(bi < 0)
				return (nil, nil, lineerr(lineno, "link: no point named "+w[2]));
			lnk = bi :: ai :: lnk;
			nlink += 2;
			continue;
		}
		(claimed, err) := dynsys->cmd(m, w);
		if(err != nil)
			return (nil, nil, lineerr(lineno, err));
		if(!claimed)
			return (nil, nil, lineerr(lineno, "unknown command "+w[0]));
	}
	if((err := dynsys->check(m)) != nil)
		return (nil, nil, err);
	if(ttl == "")
		return (nil, nil, "spec has no title command");
	if(len m.observablelabels != 2)
		return (nil, nil, sys->sprint("spec has %d observable commands, needs exactly 2",
			len m.observablelabels));
	if(len m.pointnames == 0)
		return (nil, nil, "spec has no point commands");
	l := array[nlink] of int;
	for(i := nlink-1; i >= 0; i--){
		l[i] = hd lnk;
		lnk = tl lnk;
	}
	title = ttl;
	manual = man;
	return (m, l, nil);
}

manual := "";

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

nameindex(a: array of string, name: string): int
{
	for(i := 0; i < len a; i++)
		if(a[i] == name)
			return i;
	return -1;
}

run(ctxt: ref Draw->Context, name, spec: string): string
{
	err: string;
	(model, links, err) = parse(spec);
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
	bg = win.display.color(int 16rf4f0e7ff);
	fg = win.display.color(int 16r20272cff);
	grid = win.display.color(int 16rd6d0c4ff);
	bodycolour = win.display.color(int 16rb85c38ff);
	firstcolour = win.display.color(int 16r178f86ff);
	secondcolour = win.display.color(int 16r7b5aa6ff);
	graph = plot->new(win.image, font);
	graph.cmd("table history time first second -capacity 20000");
	graph.cmd("colour foreground 16r20272cff\n"+
		"colour grid 16rd6d0c4ff\n"+
		"colour first 16r178f86ff\n"+
		"colour second 16r7b5aa6ff");
	reset();
	win.reshape(Rect((0,0),(900,560)));
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
	work = numerics->workspace(len state);
	t = 0.0;
	paused = 0;
	finished = 0;
	observationmaximum[0] = 1.0;
	observationmaximum[1] = 1.0;
	graph.cmd("history clear");
	record();
}

step()
{
	h := 0.005;
	numerics->rk4(work, rhs, t, h, state);
	t += h;
	if(t >= model.maxtime){
		finished = 1;
		paused = 1;
	}
	record();
}

record()
{
	values := dynsys->observables(model, state);
	for(i := 0; i < 2; i++){
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
	bandtop := r.max.y-ControlBandH;
	if(pointer.xy.y < bandtop)
		return;
	n := len model.parameter;
	if(n == 0)
		return;
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
	bandtop := im.r.max.y-ControlBandH;
	content := Rect(im.r.min.add((25,38)),(im.r.max.x-18,bandtop-10));
	middle := content.min.x+(content.dx()*3)/5;
	mechanismview := Rect(content.min,(middle-20,content.max.y));
	drawmechanism(im, mechanismview);
	graph.image = im;
	graph.cmd("clear");
	graph.cmd("content margin 25 38 18 "+string (ControlBandH+10)+"\n"+
		"split content x mechanismview 3 plotview 2 gutter 55\n"+
		"view quantities plotview");
	tmax := t;
	if(tmax < 2.0)
		tmax = 2.0;
	ymax := observationmaximum[0];
	if(observationmaximum[1] > ymax)
		ymax = observationmaximum[1];
	graph.cmd(sys->sprint("scale quantities x 0 %.8g", tmax));
	graph.cmd(sys->sprint("scale quantities y %.8g %.8g reverse", -ymax, ymax));
	graph.cmd("axis quantities x time");
	graph.cmd("axis quantities y value");
	graph.cmd("line quantities history x time y first colour first width 2");
	graph.cmd("line quantities history x time y second colour second width 2");
	graph.draw();
	values := dynsys->observables(model, state);
	status := "running";
	if(paused)
		status = "paused";
	if(finished)
		status = "complete";
	im.text(im.r.min.add((10,18)), fg, Point(0,0), font,
		sys->sprint("%s   %s   t %.3g   %s %.3g   %s %.3g",
			title, status, t, label(model.observablelabels[0]), values[0],
			label(model.observablelabels[1]), values[1]));
	for(i := 0; i < len model.parameter; i++)
		drawparameter(im, i, model.paramlabels[i], model.parameter[i],
			model.maxima[i]);
	im.flush(Draw->Flushnow);
}

drawmechanism(im: ref Image, view: Rect)
{
	points := dynsys->points(model, state);
	if(len points == 0)
		return;
	xmin := points[0];
	xmax := points[0];
	ymin := points[1];
	ymax := points[1];
	for(i := 0; i < len points/2; i++){
		x := points[2*i];
		y := points[2*i+1];
		if(x < xmin)
			xmin = x;
		if(x > xmax)
			xmax = x;
		if(y < ymin)
			ymin = y;
		if(y > ymax)
			ymax = y;
	}
	if(xmax-xmin < 1.0){
		xmin -= 0.5;
		xmax += 0.5;
	}
	if(ymax-ymin < 1.0){
		ymin -= 0.5;
		ymax += 0.5;
	}
	xpad := (xmax-xmin)*0.15;
	ypad := (ymax-ymin)*0.15;
	xmin -= xpad;
	xmax += xpad;
	ymin -= ypad;
	ymax += ypad;
	for(i = 0; i < len links/2; i++){
		a := links[2*i];
		b := links[2*i+1];
		if(2*a+1 >= len points || 2*b+1 >= len points)
			continue;
		pa := project(view, points[2*a], points[2*a+1], xmin, xmax, ymin, ymax);
		pb := project(view, points[2*b], points[2*b+1], xmin, xmax, ymin, ymax);
		im.line(pa, pb, Draw->Endsquare, Draw->Endsquare, 3, bodycolour, Point(0,0));
	}
	for(i = 0; i < len points/2; i++){
		p := project(view, points[2*i], points[2*i+1], xmin, xmax, ymin, ymax);
		im.ellipse(p, 4, 4, 0, fg, Point(0,0));
	}
}

project(view: Rect, x, y, xmin, xmax, ymin, ymax: real): Point
{
	px := view.min.x+int((x-xmin)/(xmax-xmin)*real(view.dx()));
	py := view.max.y-int((y-ymin)/(ymax-ymin)*real(view.dy()));
	return (px,py);
}

drawparameter(im: ref Image, index: int, name: string, value, maximum: real)
{
	width := im.r.dx()/len model.parameter;
	x := im.r.min.x+index*width;
	bandtop := im.r.max.y-ControlBandH;
	y := bandtop+24;
	im.line((x+4,y),(x+width-6,y),0,0,2,grid,Point(0,0));
	fraction := (value-model.minima[index])/(maximum-model.minima[index]);
	knob := x+4+int(fraction*real(width-10));
	im.ellipse((knob,y), 4, 4, 0, fg, Point(0,0));
	maxchars := (width-10)/8;
	if(maxchars < 6)
		maxchars = 6;
	im.text((x+4,bandtop+47), fg, Point(0,0), font,
		sys->sprint("%s %.3g", fitlabel(name,maxchars), value));
}

# A label is one word in the script, because param labels are also the
# symbol names expressions use.  An underscore in one is written as a
# space when it is displayed, so "support_mass" reads as "support mass"
# on the control band without being two tokens in the spec.
label(name: string): string
{
	s := name;
	for(i := 0; i < len s; i++)
		if(s[i] == '_')
			s[i] = ' ';
	return s;
}

fitlabel(name: string, maxchars: int): string
{
	name = label(name);
	if(name == nil)
		return "";
	if(maxchars < 4)
		maxchars = 4;
	if(len name <= maxchars)
		return name;
	return name[0:maxchars-3]+"...";
}

timer(ticks: chan of int)
{
	for(;;){
		sys->sleep(25);
		ticks <-= 1;
	}
}

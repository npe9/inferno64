implement Trajlab;

# See module/trajlab.m for the script vocabulary and why this is a
# library the model calls rather than a module that loads the model back.
# Everything below except parsing is appl/temple/trajectory.b's own
# window, integrator and controls, unchanged in behaviour: the model side
# of it now comes from dynsys(2) instead of from seven entry points on a
# loaded module.

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
# trajlab.m includes dynsys.m itself, so a model needs only sys.m, draw.m
# and this one; do NOT include dynsys.m here as well.
include "trajlab.m";
	dynsys: Dynsys;
	Model: import dynsys;

win: ref Window;
font: ref Font;
bg, fg, grid, pathcolour, speedcolour: ref Image;
model: ref Model;
state: array of real;
work: ref Numerics->Workspace;
graph: ref Plotter;
t := 0.0;
paused := 0;
finished := 0;
groundimpact := 0;
xmaximum := 10.0;
ymaximum := 5.0;
speedmaximum := 10.0;
title := "";
manual := "";
ControlBandH: con 76;

loadparsemods(): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(sys == nil)
		return "trajlab: cannot load Sys";
	if(dynsys == nil)
		dynsys = load Dynsys Dynsys->PATH;
	if(dynsys == nil)
		return sys->sprint("trajlab: cannot load %s: %r", Dynsys->PATH);
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
		return "trajlab: a drawing module is missing";
	return nil;
}

parse(spec: string): (ref Model, string)
{
	if((e := loadparsemods()) != nil)
		return (nil, e);
	m := dynsys->newmodel();
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
				return (nil, lineerr(lineno, "title: usage: title TEXT..."));
			ttl = joinfrom(w, 1);
			continue;
		"manual" =>
			if(nwords != 2)
				return (nil, lineerr(lineno, "manual: usage: manual PAGE"));
			man = w[1];
			continue;
		}
		(claimed, err) := dynsys->cmd(m, w);
		if(err != nil)
			return (nil, lineerr(lineno, err));
		if(!claimed)
			return (nil, lineerr(lineno, "unknown command "+w[0]));
	}
	if((err := dynsys->check(m)) != nil)
		return (nil, err);
	if(ttl == "")
		return (nil, "spec has no title command");
	for(i := 0; i < len m.parameter; i++)
		if(m.minima[i] != 0.0)
			return (nil, sys->sprint(
				"param %s: this family's sliders run from zero, so its minimum must be 0.0",
				m.paramlabels[i]));
	if(len m.statenames != 4)
		return (nil, sys->sprint(
			"a flight has four states - position, height, and the two velocities - and this spec has %d",
			len m.statenames));
	if(m.maxtime <= 0.0)
		return (nil, "spec has no maxtime command");
	title = ttl;
	manual = man;
	return (m, nil);
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
	(model, err) = parse(spec);
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
	pathcolour = win.display.color(int 16rb85c38ff);
	speedcolour = win.display.color(int 16r178f86ff);
	graph = plot->new(win.image, font);
	graph.cmd("table history time x y speed -capacity 20000");
	graph.cmd("colour foreground 16r20272cff\n"+
		"colour grid 16rd6d0c4ff\n"+
		"colour path 16rb85c38ff\n"+
		"colour speed 16r178f86ff");
	reset();
	win.reshape(Rect((0,0),(820,500)));
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
			for(i := 0; i < 5 && !finished; i++)
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
	groundimpact = 0;
	xmaximum = 10.0;
	ymaximum = 5.0;
	speedmaximum = speed();
	if(speedmaximum < 10.0)
		speedmaximum = 10.0;
	graph.cmd("history clear");
	record();
}

step()
{
	h := 0.005;
	old := array[] of {state[0],state[1],state[2],state[3]};
	oldt := t;
	numerics->rk4(work, rhs, t, h, state);
	t += h;
	# the flight ends where the height crosses zero, interpolated to the
	# crossing rather than to the end of the step
	if(state[1] < 0.0 && old[1] >= 0.0 && oldt > 0.0){
		fraction := old[1]/(old[1]-state[1]);
		for(i := 0; i < len state; i++)
			state[i] = old[i]+fraction*(state[i]-old[i]);
		state[1] = 0.0;
		t = oldt+fraction*h;
		finished = 1;
		groundimpact = 1;
		paused = 1;
	}
	if(t >= model.maxtime){
		finished = 1;
		paused = 1;
	}
	if(state[0]*1.1 > xmaximum)
		xmaximum = state[0]*1.1;
	if(state[1]*1.15 > ymaximum)
		ymaximum = state[1]*1.15;
	if(speed()*1.1 > speedmaximum)
		speedmaximum = speed()*1.1;
	record();
}

speed(): real
{
	if(math == nil)
		math = load Math Math->PATH;
	return math->sqrt(state[2]*state[2]+state[3]*state[3]);
}

record()
{
	graph.cmd(sys->sprint("history append %.17g %.17g %.17g %.17g",
		t, state[0], state[1], speed()));
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
	width := r.dx()/n;
	which := (pointer.xy.x-r.min.x)/width;
	if(which < 0)
		which = 0;
	if(which >= n)
		which = n-1;
	fraction := real(pointer.xy.x-(r.min.x+which*width))/real(width);
	if(fraction < 0.01)
		fraction = 0.01;
	model.parameter[which] = model.maxima[which]*fraction;
	reset();
}

redraw()
{
	im := win.image;
	if(im == nil)
		return;
	im.draw(im.r, bg, nil, Point(0,0));
	graph.image = im;
	graph.cmd("clear");
	graph.cmd("content margin 48 38 18 "+string (ControlBandH+10)+"\n"+
		"split content x flight 2 telemetry 1 gutter 55\n"+
		"view flight flight");
	graph.cmd(sys->sprint("scale flight x 0 %.8g", xmaximum));
	graph.cmd(sys->sprint("scale flight y 0 %.8g reverse", ymaximum));
	graph.cmd("axis flight x distance");
	graph.cmd("axis flight y height");
	graph.cmd("line flight history x x y y colour path width 2");
	tmax := t;
	if(tmax < 2.0)
		tmax = 2.0;
	graph.cmd("view telemetry telemetry");
	graph.cmd(sys->sprint("scale telemetry x 0 %.8g", tmax));
	graph.cmd(sys->sprint("scale telemetry y 0 %.8g reverse", speedmaximum));
	graph.cmd("axis telemetry x time");
	graph.cmd("axis telemetry y speed");
	graph.cmd("line telemetry history x time y speed colour speed width 2");
	graph.draw();
	status := "in flight";
	if(groundimpact)
		status = "landed";
	else if(finished)
		status = "complete";
	im.text(im.r.min.add((10,18)), fg, Point(0,0), font,
		sys->sprint("%s   %s   t %.3g   range %.3g   speed %.3g",
			title, status, t, state[0], speed()));
	for(i := 0; i < len model.parameter; i++)
		drawparameter(im, i, model.paramlabels[i],
			model.parameter[i], model.maxima[i]);
	im.flush(Draw->Flushnow);
}

drawparameter(im: ref Image, index: int, name: string, value, maximum: real)
{
	width := im.r.dx()/len model.parameter;
	x := im.r.min.x+index*width;
	bandtop := im.r.max.y-ControlBandH;
	y := bandtop+24;
	im.line((x+4,y),(x+width-6,y), 0, 0, 2, grid, Point(0,0));
	knob := x+4+int(value/maximum*real(width-10));
	im.ellipse((knob,y), 4, 4, 0, fg, Point(0,0));
	maxchars := (width-10)/8;
	if(maxchars < 6)
		maxchars = 6;
	im.text((x+4,bandtop+47), fg, Point(0,0), font,
		sys->sprint("%s %.3g", fitlabel(label(name), maxchars), value));
}

fitlabel(name: string, maxchars: int): string
{
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

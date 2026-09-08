implement Aerobraking;

# aerobraking - one file, nothing else: no plugin, no library, no
# harness.  The pieces are:
#
#	SPEC		the whole model, as a script
#	loadspec()	runs it, producing a dynsys(2) Model (the
#			equations) and a Config (the picture)
#	Sim		everything that changes as time runs
#	the rest	Tk controls, an event loop, and a redraw that
#			draws the orbits and the graph
#
# The script is run, not parsed: cmd() tokenises a line and offers the
# words to dynsys(2) first, which owns param/maxtime/state/derivative/
# eq/observable, and to appcmd() otherwise, which owns the four lines
# that really are this application's own data:
#
#	title TEXT			rest of the line, verbatim
#	bodylabels WORD WORD ...
#	mass NUM NUM ...		one per body, same order
#	graph TEXT			plot(2)'s own language, verbatim
#
# The graph lines are collected rather than forwarded live only because
# WHEN each runs - once at setup, or after every "clear" - is this
# application's business; loadspec() decides that once, so redraw() does
# not have to ask again forty times a second.  See doc/danby-tks-plan.md
# for why "table" is the line that must not be reissued.

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Font, Point, Rect: import draw;
include "tk.m";
	tk: Tk;
	Toplevel: import tk;
include "tkclient.m";
	tkclient: Tkclient;
include "numerics.m";
	numerics: Numerics;
include "plot.m";
	plot: Plot;
	Plotter: import plot;
include "string.m";
	str: String;
include "dynsys.m";
	dynsys: Dynsys;
	Model: import dynsys;

Aerobraking: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);

	# Two in-process test seams, for the reason hoc(2)'s own run() has
	# (see appl/lib/hoc.b): a test gets to check the SAME spec string
	# this command runs, not a copy that could drift from it.  Nothing
	# else loads this file - it is still the whole application.
	#
	# run() runs the script and hands it back with whether it was well
	# formed.  viewtest() drives the model forward with no window at
	# all and checks the property draworbits() was rewritten for: the
	# focus body's projected point is exactly view centre on every
	# step, and the scale genuinely changes across the run.  nil on
	# success, else what failed and where.
	run: fn(argv: list of string): (string, int);
	viewtest: fn(): string;
};

SPEC: con
	"title Aerobraking the orbit of a spacecraft\n" +
	"bodylabels planet craft\n" +
	"mass 1.0 0.0\n" +
	"param apoapsis 1.18 1.02 2.0\n" +
	"param speed 0.88 0.3 1.5\n" +
	"param atmosphere 0.025 0.0 0.2\n" +
	"param scaleheight 0.08 0.01 0.3\n" +
	"param gravity 1.0 0.2 2.0\n" +
	"param dragarea 0.012 0.0 0.08\n" +
	"maxtime 30.0\n" +
	"state x0 0.0\n" +
	"state y0 0.0\n" +
	"state vx0 0.0\n" +
	"state vy0 0.0\n" +
	"state x apoapsis\n" +
	"state y 0.0\n" +
	"state vx 0.0\n" +
	"state vy speed\n" +
	"derivative x0 0.0\n" +
	"derivative y0 0.0\n" +
	"derivative vx0 0.0\n" +
	"derivative vy0 0.0\n" +
	"derivative x vx\n" +
	"derivative y vy\n" +
	"derivative vx - gravity x inversecube + axdrag\n" +
	"derivative vy - gravity y inversecube + aydrag\n" +
	"eq r sqrt { x sup 2 + y sup 2 }\n" +
	"eq inversecube 1.0 over { r sup 3 }\n" +
	"eq altitude r - 1.0\n" +
	"eq rho atmosphere exp { - altitude over scaleheight }\n" +
	"eq speed2 sqrt { vx sup 2 + vy sup 2 }\n" +
	"eq factor - 0.5 rho dragarea speed2 over 1.0\n" +
	"eq axdrag factor vx\n" +
	"eq aydrag factor vy\n" +
	"observable radius r\n" +
	"observable speedobs speed2\n" +
	"graph table history time first second -capacity 20000\n" +
	"graph colour foreground 16re7edf7ff\n" +
	"graph colour grid 16r394457ff\n" +
	"graph colour first 16r4ec9b0ff\n" +
	"graph colour second 16rf2b84bff\n" +
	"graph axis diagnostics x time\n" +
	"graph axis diagnostics y value\n" +
	"graph line diagnostics history x time y first colour first width 2\n" +
	"graph line diagnostics history x time y second colour second width 2\n";


Dt: con 0.0025;		# one integration step
Ntrail: con 1600;	# how much trail a body keeps
Panelw: con 900;
Panelh: con 520;

# A line of plot(2)'s own language, and whether it survives a "clear".
# "table" does not survive being reissued - plot(2)'s bind() replaces a
# table with a fresh empty one - so it runs once and never again;
# everything else is reissued after every clear.
Graphcmd: adt {
	text:	string;
	every:	int;
};

# What the script says that dynsys(2) does not claim: the model is the
# equations, the config is the picture.
Config: adt {
	title:		string;
	bodylabels:	array of string;
	mass:		array of real;
	graphcmds:	array of Graphcmd;
};

# Everything that changes as time runs, and nothing that does not.  The
# three methods return the observables they had to compute anyway, so a
# caller that wants to plot them does not compute them twice - and a
# caller that has no window, which is what viewtest() is, simply drops
# them.  That is the whole reason this used to be six functions.
Sim: adt {
	state:		array of real;
	work:		ref Numerics->Workspace;
	t:		real;
	paused:		int;
	finished:	int;
	trail:		array of array of real;
	trailcount:	int;
	trailnext:	int;
	obsmax:		array of real;

	reset:		fn(s: self ref Sim): array of real;
	step:		fn(s: self ref Sim): array of real;
	record:		fn(s: self ref Sim): array of real;
	trailat:	fn(s: self ref Sim, k: int): array of real;
};

model: ref Model;
cfg: ref Config;
sim: ref Sim;

top: ref Toplevel;
cmdch: chan of string;
font: ref Font;
bg, fg: ref Image;
bodycolour: array of ref Image;
buffer: ref Image;
graph: ref Plotter;


# ---------------------------------------------------------------- the script

# Three loads, not one, because the three seams need different amounts
# of the system: run() reads a script, viewtest() also integrates and
# projects, and only init() opens a window.  All three are idempotent,
# so a seam called without init() loads what it needs and no more.
loadspecmods(): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(str == nil)
		str = load String String->PATH;
	if(dynsys == nil)
		dynsys = load Dynsys Dynsys->PATH;
	if(sys == nil || str == nil || dynsys == nil)
		return "aerobraking: cannot load the script modules";
	return nil;
}

loadsimmods(): string
{
	if(numerics == nil)
		numerics = load Numerics Numerics->PATH;
	if(draw == nil)
		draw = load Draw Draw->PATH;
	if(numerics == nil || draw == nil)
		return "aerobraking: cannot load the simulation modules";
	return nil;
}

loaduimods(): string
{
	if(tk == nil)
		tk = load Tk Tk->PATH;
	if(tkclient == nil)
		tkclient = load Tkclient Tkclient->PATH;
	if(plot == nil)
		plot = load Plot Plot->PATH;
	if(tk == nil || tkclient == nil || plot == nil)
		return "aerobraking: cannot load the window modules";
	return nil;
}

# loadspec: run the script, one line at a time, into a brand-new model
# and config; then check what can only be known once the whole script
# has run.  Sets the module's own model and cfg on success.
loadspec(spec: string): string
{
	if((e := loadspecmods()) != nil)
		return e;
	m := dynsys->newmodel();
	c := ref Config;
	(model, cfg) = (m, c);

	for(rest := spec; rest != nil;){
		(line, tail) := str->splitl(rest, "\n");
		if(tail != nil)
			tail = tail[1:];
		rest = tail;
		if((err := cmd(line)) != nil)
			return err;
	}

	if(c.title == nil)
		return "spec has no title command";
	if(len c.mass != len c.bodylabels)
		return "mass: must have exactly one value per bodylabels word";
	if((err := dynsys->check(m)) != nil)
		return err;
	if(len m.observablelabels != 2)
		return "spec must have exactly two observable commands";
	if(len m.statenames != 4*len c.mass)
		return sys->sprint("%d bodies need %d states - x, y and the two "+
			"velocities each - and this spec has %d",
			len c.mass, 4*len c.mass, len m.statenames);
	return nil;
}

# cmd: tokenise, then offer the words to whichever parser owns the
# vocabulary, dynsys(2) first.  Nothing here recognises an equation
# keyword, and nothing here ever touches a ref Hoc->Expr.
cmd(line: string): string
{
	a := specwords(line);
	if(len a == 0)
		return nil;
	(claimed, err) := dynsys->cmd(model, a);
	if(claimed)
		return err;
	(claimed, err) = appcmd(a);
	if(claimed)
		return err;
	return "unknown command: "+a[0];
}

appcmd(a: array of string): (int, string)
{
	case a[0] {
	"title" =>
		cfg.title = joinwords(a, 1);
		return (1, nil);
	"bodylabels" =>
		cfg.bodylabels = wordslice(a, 1);
		return (1, nil);
	"mass" =>
		cfg.mass = realwords(a, 1);
		return (1, nil);
	"graph" =>
		if(len a < 2)
			return (1, "graph: usage: graph TEXT...");
		text := joinwords(a, 1);
		g := cfg.graphcmds;
		n := len g;
		r := array[n+1] of Graphcmd;
		for(i := 0; i < n; i++)
			r[i] = g[i];
		r[n] = Graphcmd(text, !str->prefix("table ", text));
		cfg.graphcmds = r;
		return (1, nil);
	}
	return (0, nil);
}

specwords(line: string): array of string
{
	l := str->fields(line);
	a := array[len l] of string;
	i := 0;
	for(; l != nil; l = tl l)
		a[i++] = hd l;
	return a;
}

# The rest of the line, verbatim, as "title" and "graph" both want it.
joinwords(a: array of string, from: int): string
{
	s := "";
	for(i := from; i < len a; i++){
		if(i > from)
			s += " ";
		s += a[i];
	}
	return s;
}

wordslice(a: array of string, from: int): array of string
{
	r := array[len a - from] of string;
	for(i := from; i < len a; i++)
		r[i-from] = a[i];
	return r;
}

realwords(a: array of string, from: int): array of real
{
	r := array[len a - from] of real;
	for(i := from; i < len a; i++)
		r[i-from] = real a[i];
	return r;
}


# ------------------------------------------------------------ the simulation

# numerics(2)'s Rhs type has no room for a model argument, so this
# one-line closure over the module's own model is all rk4 needs.
rhs(rhsTime: real, values, derivative: array of real)
{
	dynsys->rhs(model, rhsTime, values, derivative);
}

Sim.reset(s: self ref Sim): array of real
{
	s.state = dynsys->initialstate(model);
	s.work = numerics->workspace(len s.state);
	s.t = 0.0;
	s.paused = 0;
	s.finished = 0;
	s.trail = array[Ntrail] of array of real;
	s.trailcount = 0;
	s.trailnext = 0;
	s.obsmax = array[] of {1.0, 1.0};
	return s.record();
}

Sim.step(s: self ref Sim): array of real
{
	numerics->rk4(s.work, rhs, s.t, Dt, s.state);
	s.t += Dt;
	if(s.t >= model.maxtime){
		s.finished = 1;
		s.paused = 1;
	}
	return s.record();
}

# The trail and the axis maxima: what the picture needs remembered, and
# nothing the graph needs, so this runs with or without a window.
Sim.record(s: self ref Sim): array of real
{
	positions := array[2*len cfg.mass] of real;
	for(i := 0; i < len cfg.mass; i++){
		positions[2*i] = s.state[4*i];
		positions[2*i+1] = s.state[4*i+1];
	}
	s.trail[s.trailnext] = positions;
	s.trailnext = (s.trailnext+1)%Ntrail;
	if(s.trailcount < Ntrail)
		s.trailcount++;
	values := dynsys->observables(model, s.state);
	for(i = 0; i < 2; i++)
		s.obsmax[i] = maxreal(s.obsmax[i], absreal(values[i])*1.15);
	return values;
}

# The k'th oldest sample still in the ring.
Sim.trailat(s: self ref Sim, k: int): array of real
{
	index := s.trailnext-s.trailcount+k;
	if(index < 0)
		index += Ntrail;
	return s.trail[index];
}

absreal(x: real): real
{
	if(x < 0.0)
		return -x;
	return x;
}

maxreal(a, b: real): real
{
	if(b > a)
		return b;
	return a;
}

# The two the application uses, which are the same two the simulation
# offers plus the one line that needs a graph.
restart()
{
	values := sim.reset();
	graph.cmd("history clear");
	graphsample(values);
}

advance()
{
	graphsample(sim.step());
}

graphsample(values: array of real)
{
	graph.cmd(sys->sprint("history append %.17g %.17g %.17g",
		sim.t, values[0], values[1]));
}


# ---------------------------------------------------------------- the window

init(ctxt: ref Draw->Context, nil: list of string)
{
	if((e := loadspecmods()) != nil || (e = loadsimmods()) != nil ||
			(e = loaduimods()) != nil)
		raise "fail:Aerobraking: "+e;
	if((e = loadspec(SPEC)) != nil)
		raise "fail:Aerobraking: bad spec: "+e;

	sys->pctl(Sys->NEWPGRP, nil);
	menu := initwindow(ctxt);
	initgraph();
	sim = ref Sim;
	restart();
	redraw();
	ticks := chan of int;
	spawn timer(ticks);
	eventloop(menu, ticks);
}

initwindow(ctxt: ref Draw->Context): chan of string
{
	tkclient->init();
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	menu: chan of string;
	(top, menu) = tkclient->toplevel(ctxt, "", cfg.title, 0);
	font = Font.open(top.display, "/fonts/lucida/unicode.8.font");
	bg = top.display.color(int 16r080d18ff);
	fg = top.display.color(int 16re7edf7ff);
	bodycolour = array[] of {
		top.display.color(int 16rf2b84bff),
		top.display.color(int 16r4ec9b0ff),
		top.display.color(int 16r70a5ffff),
		top.display.color(int 16re77c8eff),
		top.display.color(int 16rc792eaff),
		top.display.color(int 16r9dd274ff)
	};

	cmdch = chan of string;
	tk->namechan(top, cmdch, "cmd");
	tkcmd("frame .f");
	tkcmd("frame .c");
	tkcmd(sys->sprint("panel .f.p -bd 2 -relief flat -width %d -height %d",
		Panelw, Panelh));
	tkcmd("pack .f.p -fill both -expand 1");
	tkcmd("pack .f -side top -fill both -expand 1");
	tkcmd("button .c.Pause -text Pause -command {send cmd pause}");
	tkcmd("button .c.Reset -text Reset -command {send cmd reset}");
	tkcmd("pack .c.Pause .c.Reset -side left");
	for(i := 0; i < len model.parameter; i++){
		w := sys->sprint(".c.p%d", i);
		res := (model.maxima[i]-model.minima[i])/200.0;
		if(res <= 0.0)
			res = 0.001;
		tkcmd(sys->sprint("scale %s -label {%s} -from %g -to %g -resolution %g"+
			" -orient horizontal -showvalue 1 -command {send cmd p%d}",
			w, model.paramlabels[i], model.minima[i], model.maxima[i], res, i));
		tkcmd(sys->sprint("%s set %g", w, model.parameter[i]));
		tkcmd(sys->sprint("pack %s -side left -fill x -expand 1", w));
	}
	tkcmd("pack .c -side bottom -fill x");
	tk->cmd(top, "update");
	tkclient->startinput(top, "kbd"::"ptr"::nil);
	tkclient->onscreen(top, nil);
	if(top.image == nil)
		raise "fail:Aerobraking: onscreen left nil image";
	return menu;
}

initgraph()
{
	buffer = top.display.newimage(Rect((0,0),(Panelw,Panelh)),
		top.image.chans, 0, Draw->White);
	if(buffer == nil)
		raise "fail:Aerobraking: cannot allocate drawing buffer";
	tk->putimage(top, ".f.p", buffer, nil);
	graph = plot->new(buffer, font);
	# only the lines that are NOT reissued after every clear.  The rest
	# are tied to a view that drawgraph() has not created yet, and
	# issuing them here printed "no such view diagnostics" to stderr on
	# every start - harmless, because drawgraph() issued them again a
	# moment later, but two errors nobody had a use for.
	for(i := 0; i < len cfg.graphcmds; i++)
		if(!cfg.graphcmds[i].every)
			gerr(graph.cmd(cfg.graphcmds[i].text));
}

gerr(e: string)
{
	if(e != nil)
		sys->fprint(sys->fildes(2), "aerobraking graph: %s\n", e);
}

tkcmd(s: string)
{
	e := tk->cmd(top, s);
	if(len e > 0 && e[0] == '!')
		sys->fprint(sys->fildes(2), "aerobraking tk: %s: %s\n", s, e);
}


# --------------------------------------------------------------- the picture

redraw()
{
	im := buffer;
	im.draw(im.r, bg, nil, Point(0,0));
	content := Rect(im.r.min.add((10,10)), im.r.max.sub((10,50)));
	middle := content.min.x+(content.dx()*3)/5;
	draworbits(im, Rect(content.min, (middle-20, content.max.y)));
	drawgraph(im);
	drawstatus(im);
	im.flush(Draw->Flushnow);
	tkcmd(".f.p dirty");
	tk->cmd(top, "update");
}

drawgraph(im: ref Image)
{
	graph.image = im;
	gerr(graph.cmd("clear"));
	gerr(graph.cmd("content margin 10 10 10 50\n"+
		"split content x orbitview 3 plotview 2 gutter 55\n"+
		"view diagnostics plotview"));
	# "clear" above wipes plot(2)'s view and layer state, so every graph
	# line that is tied to a view has to be reissued.  Which those are
	# was decided once, when the script ran.
	for(i := 0; i < len cfg.graphcmds; i++)
		if(cfg.graphcmds[i].every)
			gerr(graph.cmd(cfg.graphcmds[i].text));
	tmax := maxreal(sim.t, 2.0);
	ymax := maxreal(sim.obsmax[0], sim.obsmax[1]);
	gerr(graph.cmd(sys->sprint("scale diagnostics x 0 %.8g", tmax)));
	gerr(graph.cmd(sys->sprint("scale diagnostics y %.8g %.8g reverse",
		-ymax, ymax)));
	graph.draw();
}

drawstatus(im: ref Image)
{
	values := dynsys->observables(model, sim.state);
	status := "running";
	if(sim.paused)
		status = "paused";
	if(sim.finished)
		status = "complete";
	im.text(im.r.min.add((6,6)), fg, Point(0,0), font,
		sys->sprint("%s   %s   t %.3g   %s %.4g   %s %.4g",
			cfg.title, status, sim.t,
			model.observablelabels[0], values[0],
			model.observablelabels[1], values[1]));
}

# viewgeometry keeps the most massive body - the "planet" - pinned at
# the centre of the view and lets the SCALE do all the work as drag
# decays the orbit.  An independent x/y bounding box mapped onto the
# view rect was the bug: that box's own centre drifts as the trail's
# extent changes even though the planet has not moved, so the planet
# visibly wandered around the screen instead of staying put while the
# view zoomed.  A single uniform scale, not separate x and y ranges,
# also keeps a circular orbit looking circular.
#
# It has no drawing in it so that viewtest() can call the exact code a
# real redraw does, rather than a copy that could drift from it.
viewgeometry(view: Rect): (int, real, Point)
{
	focus := 0;
	for(i := 1; i < len cfg.mass; i++)
		if(cfg.mass[i] > cfg.mass[focus])
			focus = i;

	# extent: the largest distance any trail point sits from the FOCUS
	# body's own position at that same instant - not from its current
	# position, so a system whose "planet" is not perfectly fixed still
	# reads correctly.
	extent := 0.1;
	for(k := 0; k < sim.trailcount; k++){
		positions := sim.trailat(k);
		(fx, fy) := (positions[2*focus], positions[2*focus+1]);
		for(i = 0; i < len cfg.mass; i++){
			extent = maxreal(extent, absreal(positions[2*i]-fx));
			extent = maxreal(extent, absreal(positions[2*i+1]-fy));
		}
	}
	extent *= 1.24;		# the padding the old x/y-range version used

	half := view.dx();
	if(view.dy() < half)
		half = view.dy();
	return (focus, real(half)/(2.0*extent),
		Point((view.min.x+view.max.x)/2, (view.min.y+view.max.y)/2));
}

draworbits(im: ref Image, view: Rect)
{
	(focus, scale, centre) := viewgeometry(view);
	for(i := 0; i < len cfg.mass; i++){
		colour := bodycolour[i%len bodycolour];
		haveprevious := 0;
		previous := Point(0,0);
		for(k := 0; k < sim.trailcount; k++){
			positions := sim.trailat(k);
			point := project(centre, scale, positions[2*i], positions[2*i+1],
				positions[2*focus], positions[2*focus+1]);
			if(haveprevious)
				im.line(previous, point, 0, 0, 1, colour, Point(0,0));
			previous = point;
			haveprevious = 1;
		}
		point := project(centre, scale, sim.state[4*i], sim.state[4*i+1],
			sim.state[4*focus], sim.state[4*focus+1]);
		radius := 4;
		if(cfg.mass[i] > 0.1)
			radius = 7;
		im.ellipse(point, radius, radius, 0, colour, Point(0,0));
		im.text(point.add((radius+3,-3)), fg, Point(0,0), font,
			cfg.bodylabels[i]);
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


# ------------------------------------------------------------------ the loop

eventloop(menu: chan of string, ticks: chan of int)
{
	for(;;) alt {
	s := <-top.ctxt.kbd =>
		tk->keyboard(top, s);
		keyevent(s);
		redraw();
	p := <-top.ctxt.ptr =>
		tk->pointer(top, *p);
	s := <-top.ctxt.ctl or s = <-top.wreq or s = <-menu =>
		tkclient->wmctl(top, s);
	s := <-cmdch =>
		control(s);
		redraw();
	<-ticks =>
		tick();
		redraw();
	}
}

tick()
{
	if(sim.paused || sim.finished)
		return;
	for(k := 0; k < 4 && !sim.finished; k++)
		advance();
}

keyevent(key: int)
{
	case key {
	16r1b or 'q' or 'Q' =>
		tkclient->wmctl(top, "exit");
	' ' =>
		if(!sim.finished)
			sim.paused = !sim.paused;
	'r' or 'R' =>
		restart();
	'.' =>
		if(sim.paused && !sim.finished)
			advance();
	}
}

# A Tk message: one of the two buttons, or a scale's own "pN VALUE".
control(s: string)
{
	(nil, w) := sys->tokenize(s, " ");
	if(w == nil)
		return;
	case hd w {
	"pause" =>
		if(!sim.finished)
			sim.paused = !sim.paused;
	"reset" =>
		restart();
	* =>
		setparam(hd w, tl w);
	}
}

setparam(word0: string, rest: list of string)
{
	if(len word0 == 0 || word0[0] != 'p' || rest == nil)
		return;
	(idx, ok) := str->toint(word0[1:], 10);
	if(ok != nil || idx < 0 || idx >= len model.parameter)
		return;
	# the model's own live array, so this rebinds the running model
	model.parameter[idx] = real hd rest;
	# every state is an expression in the parameters, so a new parameter
	# is a new problem rather than a nudge to this one
	restart();
}

timer(ticks: chan of int)
{
	for(;;){
		sys->sleep(25);
		ticks <-= 1;
	}
}


# ------------------------------------------------------------- the test seams

run(nil: list of string): (string, int)
{
	# a seam that handed back a spec it never ran would be testing
	# nothing, so this actually runs it; nil says the script was never
	# reached at all, which is not the same as a spec that is wrong
	if(loadspecmods() != nil)
		return (nil, 0);
	return (SPEC, loadspec(SPEC) == nil);
}

# Drives the model forward with no window - Sim needs none, which is why
# it does not have one - and checks, at three view sizes:
#
#	centre is exactly the view rect's own midpoint, computed here
#		independently rather than by a second copy of
#		viewgeometry()'s formula
#	focus is the index of the largest mass
#	scale is strictly positive throughout, and changes at least once
#		across the run - a fixed scale would mean the zoom half of
#		the fix had silently stopped happening
viewtest(): string
{
	if((e := loadspecmods()) != nil || (e = loadsimmods()) != nil)
		return "viewtest: "+e;
	if((e = loadspec(SPEC)) != nil)
		return "viewtest: bad spec: "+e;

	wantfocus := 0;
	for(i := 1; i < len cfg.mass; i++)
		if(cfg.mass[i] > cfg.mass[wantfocus])
			wantfocus = i;

	views := array[] of {
		Rect((0,0),(400,300)), Rect((0,0),(800,600)), Rect((50,20),(450,320))
	};
	for(v := 0; v < len views; v++){
		view := views[v];
		wantcentre := Point((view.min.x+view.max.x)/2,
			(view.min.y+view.max.y)/2);
		sim = ref Sim;
		sim.reset();
		firstscale := 0.0;
		scalechanged := 0;
		# maxtime is 30.0 at a 0.0025 step, so a full run is ~12000
		# steps.  300 - tried first - covered 2.5% of one, nowhere near
		# enough for drag to shrink the orbit, so the scale never
		# changed and the test failed for a reason that had nothing to
		# do with draworbits().
		for(n := 0; n < 15000 && !sim.finished; n++){
			(focus, scale, centre) := viewgeometry(view);
			if(focus != wantfocus)
				return sys->sprint("viewtest: view %d step %d: focus %d, "+
					"want %d (largest mass)", v, n, focus, wantfocus);
			if(centre.x != wantcentre.x || centre.y != wantcentre.y)
				return sys->sprint("viewtest: view %d step %d: centre "+
					"(%d,%d), want (%d,%d)", v, n, centre.x, centre.y,
					wantcentre.x, wantcentre.y);
			if(scale <= 0.0)
				return sys->sprint("viewtest: view %d step %d: scale %g, "+
					"want > 0", v, n, scale);
			if(n == 0)
				firstscale = scale;
			else if(scale != firstscale)
				scalechanged = 1;
			sim.step();
		}
		if(!scalechanged)
			return sys->sprint("viewtest: view %d: scale never changed "+
				"across the run - not exercising the zoom", v);
	}
	return nil;
}

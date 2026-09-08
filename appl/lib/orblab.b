implement Orblab;

# See module/orblab.m for the script vocabulary and why this is a library
# the model calls rather than a module that loads the model back.
# The model side comes from dynsys(2) instead of from eleven entry points
# on a loaded module.  draworbits() is unchanged in behaviour - its own
# comment explains why the focus body is pinned at view centre.
#
# Tk owns the window's structure; Draw owns only the pixels of the two
# views.  The parameter sliders are Tk scales, the buttons are Tk
# buttons, the status line is a Tk label, and the geometry is Tk's - so
# the 55-pixel control band, the arithmetic that divided it into columns,
# and the "three fifths of the content, less twenty" that placed the
# orbit diagram are gone.
#
# The orbits and the graph are two "panel" widgets, each holding an image
# this library owns, the same arrangement appl/wm/coffee.b uses for its
# animation.  This family draws on a night sky rather than on paper, so
# the widgets are configured to match rather than sitting in a bright
# frame around a dark picture.

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

top: ref Toplevel;
cmdch: chan of string;
buffer: ref Image;	# the graph's pixels
orb: ref Image;		# the orbit diagram's pixels
font: ref Font;
bg, fg: ref Image;
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
	if(tk == nil)
		tk = load Tk Tk->PATH;
	if(tkclient == nil)
		tkclient = load Tkclient Tkclient->PATH;
	if(draw == nil || numerics == nil || plot == nil ||
			tk == nil || tkclient == nil)
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


Sky: con "#080d18";	# the night the diagram is drawn on
Ink: con "#e7edf7";	# and what is legible on it

# The window: a panel for the orbits, a panel for the graph, a grid of
# scales for the parameters, a row of buttons.  Nothing here knows a
# pixel offset - Tk works out where everything goes, and tk->rect() says
# afterwards where each panel ended up.
tkcfg := array[] of {
	". configure -background "+Sky,
	"frame .plot -background "+Sky,
	"panel .plot.orb -bd 0 -relief flat -width 520 -height 420",
	"panel .plot.g -bd 0 -relief flat -width 360 -height 420",
	"pack .plot.orb -side left -fill both -expand 1",
	"pack .plot.g -side right -fill both -expand 1",
	"frame .par -background "+Sky,
	"frame .but -background "+Sky,
	"button .but.reset -text Reset -command {send cmd reset}",
	"button .but.pause -text Pause -command {send cmd pause}",
	"label .but.at -text {} -background "+Sky+" -foreground "+Ink,
	"pack .but.reset .but.pause -side left",
	"pack .but.at -side left -padx 10",
	"pack .but -side bottom -fill x",
	"pack .par -side bottom -fill x",
	"pack .plot -side top -fill both -expand 1",
	"bind . <Key> {send cmd key %K}",
	"bind .plot.orb <Key> {send cmd key %K}",
	"focus .plot.orb",
};

cmd(s: string): string
{
	r := tk->cmd(top, s);
	if(r != nil && r[0] == '!')
		sys->fprint(sys->fildes(2), "orblab: %s: %s\n", s, r);
	return r;
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
	tkclient->init();
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	menu: chan of string;
	(top, menu) = tkclient->toplevel(ctxt, "", title, Tkclient->Appl);
	cmdch = chan[64] of string;	# tk drops what it cannot queue, so leave room
	tk->namechan(top, cmdch, "cmd");
	for(i := 0; i < len tkcfg; i++)
		cmd(tkcfg[i]);
	buildparams();
	cmd("update");
	tkclient->startinput(top, "kbd"::"ptr"::nil);
	tkclient->onscreen(top, nil);

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
	graph = plot->new(nil, font);
	graph.cmd("table history time first second -capacity 20000");
	graph.cmd("colour foreground 16re7edf7ff\n"+
		"colour grid 16r394457ff\n"+
		"colour first 16r4ec9b0ff\n"+
		"colour second 16rf2b84bff");
	trail = array[Ntrail] of array of real;
	reset();
	resize();
	ticks := chan of int;
	spawn timer(ticks);
	redraw();
	for(;;) alt {
	s := <-top.ctxt.kbd =>
		tk->keyboard(top, s);
	p := <-top.ctxt.ptr =>
		tk->pointer(top, *p);
	s := <-top.ctxt.ctl or s = <-top.wreq or s = <-menu =>
		tkclient->wmctl(top, s);
		if(s == "exit")
			return nil;
		resize();
		redraw();
	s := <-cmdch =>
		if(control(s))
			return nil;
		redraw();
	<-ticks =>
		if(!paused && !finished)
			for(k := 0; k < 4 && !finished; k++)
				step();
		redraw();
	}
}

# One label and one scale per parameter, three parameters to a line.  A
# scale's own -command reports the new value, so nothing here has to work
# out which slider the pointer was over.  In this family a slider is
# usually a mass, and a mass may have a non-zero minimum.
buildparams()
{
	for(j := 0; j < len model.parameter; j++){
		(lo, hi) := (model.minima[j], model.maxima[j]);
		if(lo >= hi)
			lo = hi*0.01;
		cmd(sys->sprint("label .par.l%d -text {%s} -background %s -foreground %s",
			j, label(model.paramlabels[j]), Sky, Ink));
		# -bigincrement defaults to zero, and a scale with a zero big
		# increment answers a click in its trough by re-sending the
		# value it already had: the slider looks live and does nothing
		cmd(sys->sprint("scale .par.s%d -from %g -to %g -resolution %g"+
			" -bigincrement %g -orient horizontal -length 150"+
			" -showvalue 1 -command {send cmd param %d}",
			j, lo, hi, (hi-lo)/200.0, (hi-lo)/20.0, j));
		cmd(sys->sprint(".par.s%d set %g", j, model.parameter[j]));
		row := j/3;
		col := (j%3)*2;
		cmd(sys->sprint("grid .par.l%d -row %d -column %d -sticky w -padx 4",
			j, row, col));
		cmd(sys->sprint("grid .par.s%d -row %d -column %d -sticky w",
			j, row, col+1));
	}
}

# Tk says where each panel went; this library only has to keep images of
# those sizes.  Does nothing at all unless a size actually changed.
resize()
{
	if(top.image == nil)
		return;
	orb = refit(orb, ".plot.orb");
	buffer = refit(buffer, ".plot.g");
	graph.image = buffer;
}

refit(im: ref Image, widget: string): ref Image
{
	r := tk->rect(top, widget, 0);
	(w, h) := (r.dx(), r.dy());
	if(w <= 0 || h <= 0)
		return im;
	if(im != nil && im.r.dx() == w && im.r.dy() == h)
		return im;
	new := top.display.newimage(Rect((0,0),(w,h)), top.image.chans, 0, Draw->White);
	if(new == nil)
		return im;
	tk->putimage(top, widget, new, nil);
	return new;
}

# A Tk message.  Returns non-zero if the window is finished.
control(s: string): int
{
	(nil, w) := sys->tokenize(s, " \t");
	if(w == nil)
		return 0;
	case hd w {
	"reset" =>
		reset();
	"pause" =>
		if(finished)
			return 0;
		paused = !paused;
		lbl := "Pause";
		if(paused)
			lbl = "Go";
		cmd(sys->sprint(".but.pause configure -text %s", lbl));
	"param" =>
		# read every scale rather than trust one message: tk drops
		# queued messages silently, and a dropped last drag event
		# would otherwise leave a parameter behind the slider
		for(j := 0; j < len model.parameter; j++)
			model.parameter[j] = real cmd(sys->sprint(".par.s%d get", j));
		# masses and initial positions are expressions in the
		# parameters, so a new parameter is a new system
		reset();
	"key" =>
		if(len w != 2)
			return 0;
		case int ("16r"+hd tl w) {
		16r1b or 'q' or 'Q' =>
			tkclient->wmctl(top, "exit");
			return 1;
		' ' =>
			return control("pause");
		'r' or 'R' =>
			reset();
		'.' =>
			if(paused && !finished)
				step();
		}
	}
	return 0;
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
	if(top != nil)
		cmd(".but.pause configure -text Pause");
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

readout := "";

redraw()
{
	if(buffer == nil || orb == nil)
		return;
	buffer.draw(buffer.r, bg, nil, Point(0,0));
	draworbits();
	graph.cmd("clear");
	graph.cmd("content margin 45 22 18 30\nview diagnostics content");
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
	cmd(".plot.orb dirty; .plot.g dirty; update");
	values := dynsys->observables(model, state);
	status := "running";
	if(paused)
		status = "paused";
	if(finished)
		status = "complete";
	# the label is a widget, so only touch it when it would change
	now := sys->sprint("%s   t %.3g   %s %.4g   %s %.4g",
		status, t, label(model.observablelabels[0]), values[0],
		label(model.observablelabels[1]), values[1]);
	if(now != readout){
		readout = now;
		cmd(".but.at configure -text {"+now+"}");
	}
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
#
# The diagram has a panel to itself, so its view is that panel's whole
# image and there is no view rect to compute.
draworbits()
{
	orb.draw(orb.r, bg, nil, Point(0,0));
	view := orb.r.inset(8);
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
				orb.line(previous, point, 0, 0, 1,
					bodycolour[i%len bodycolour], Point(0,0));
			previous = point;
			haveprevious = 1;
		}
		point := project(centre, scale, state[4*i], state[4*i+1],
			state[4*focus], state[4*focus+1]);
		radius := 4;
		if(mass[i] > 0.1)
			radius = 7;
		orb.ellipse(point, radius, radius, 0, bodycolour[i%len bodycolour], Point(0,0));
		orb.text(point.add((radius+3,-3)), fg, Point(0,0), font, label(bodylabels[i]));
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

timer(ticks: chan of int)
{
	for(;;){
		sys->sleep(25);
		ticks <-= 1;
	}
}

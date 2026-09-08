implement Mechlab;

# See module/mechlab.m for the script vocabulary and why this is a
# library the model calls rather than a module that loads the model
# back.  The model side of it comes from dynsys(2) instead of from
# thirteen entry points on a loaded module.
#
# Tk owns the window's structure; Draw owns only the pixels of the two
# views.  The parameter sliders are Tk scales, the buttons are Tk
# buttons, the status line is a Tk label, and the geometry is Tk's - so
# the 76-pixel control band, the arithmetic that divided it into columns,
# the "three fifths of the content, less twenty" that placed the
# mechanism, and the routine that truncated a name to fit a column it had
# guessed the width of are all gone.
#
# The mechanism and the graph are two "panel" widgets, each holding an
# image this library owns, the same arrangement appl/wm/coffee.b uses for
# its animation.  The mechanism is projected into its panel's whole
# rectangle, so there is no view rect to compute and none to get wrong.

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
# mechlab.m includes dynsys.m itself, so that a model file needs only
# sys.m, draw.m and this one - do NOT include dynsys.m here as well,
# Limbo has no include guard and would see Hoc and Dynsys twice.
include "mechlab.m";
	dynsys: Dynsys;
	Model: import dynsys;

top: ref Toplevel;
cmdch: chan of string;
buffer: ref Image;	# the graph's pixels
mech: ref Image;	# the mechanism diagram's pixels
font: ref Font;
bg, fg, bodycolour: ref Image;
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
	if(tk == nil)
		tk = load Tk Tk->PATH;
	if(tk == nil)
		return sys->sprint("mechlab: cannot load %s: %r", Tk->PATH);
	if(tkclient == nil)
		tkclient = load Tkclient Tkclient->PATH;
	if(tkclient == nil)
		return sys->sprint("mechlab: cannot load %s: %r", Tkclient->PATH);
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

# The window: a panel for the mechanism, a panel for the graph, a grid of
# scales for the parameters, a row of buttons.  Nothing here knows a
# pixel offset - Tk works out where everything goes, and tk->rect() says
# afterwards where each panel ended up.
tkcfg := array[] of {
	"frame .plot",
	"panel .plot.mech -bd 0 -relief flat -width 460 -height 400",
	"panel .plot.g -bd 0 -relief flat -width 380 -height 400",
	"pack .plot.mech -side left -fill both -expand 1",
	"pack .plot.g -side right -fill both -expand 1",
	"frame .par",
	"frame .but",
	"button .but.reset -text Reset -command {send cmd reset}",
	"button .but.pause -text Pause -command {send cmd pause}",
		# A label's requested size follows its text, and a frame that gets a
	# new requested size asks the window manager to reshape the window.
	# This text changes forty times a second, so without a fixed width
	# the window renegotiates its own geometry forty times a second too:
	# a measured 36 reshape requests per 200 frames, against 1 with the
	# width nailed down.
	"label .but.at -text {} -anchor w -width 460",
	"pack .but.reset .but.pause -side left",
	"pack .but.at -side left -padx 10",
	"pack .but -side bottom -fill x",
	"pack .par -side bottom -fill x",
	"pack .plot -side top -fill both -expand 1",
	"bind . <Key> {send cmd key %K}",
	"bind .plot.mech <Key> {send cmd key %K}",
	"focus .plot.mech",
};

cmd(s: string): string
{
	r := tk->cmd(top, s);
	if(r != nil && r[0] == '!')
		sys->fprint(sys->fildes(2), "mechlab: %s: %s\n", s, r);
	return r;
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
	bg = top.display.color(int 16rf4f0e7ff);
	fg = top.display.color(int 16r20272cff);
	bodycolour = top.display.color(int 16rb85c38ff);
	graph = plot->new(nil, font);
	graph.cmd("table history time first second -capacity 20000");
	graph.cmd("colour foreground 16r20272cff\n"+
		"colour grid 16rd6d0c4ff\n"+
		"colour first 16r178f86ff\n"+
		"colour second 16r7b5aa6ff");
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
# out which slider the pointer was over or truncate a name to fit.  A
# mechanism parameter may have a non-zero minimum, and the scale carries
# it: a length of zero is not a mechanism.
buildparams()
{
	for(j := 0; j < len model.parameter; j++){
		(lo, hi) := (model.minima[j], model.maxima[j]);
		if(lo >= hi)
			lo = hi*0.01;
		cmd(sys->sprint("label .par.l%d -text {%s}", j, label(model.paramlabels[j])));
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
	mech = refit(mech, ".plot.mech");
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
		# the state lines are expressions in the parameters, so a new
		# parameter is a new mechanism, not a nudge to this one
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
	work = numerics->workspace(len state);
	t = 0.0;
	paused = 0;
	finished = 0;
	observationmaximum[0] = 1.0;
	observationmaximum[1] = 1.0;
	graph.cmd("history clear");
	record();
	if(top != nil)
		cmd(".but.pause configure -text Pause");
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

readout := "";

redraw()
{
	if(buffer == nil || mech == nil)
		return;
	buffer.draw(buffer.r, bg, nil, Point(0,0));
	drawmechanism();
	graph.cmd("clear");
	graph.cmd("content margin 45 22 18 30\nview quantities content");
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
	cmd(".plot.mech dirty; .plot.g dirty; update");
	values := dynsys->observables(model, state);
	status := "running";
	if(paused)
		status = "paused";
	if(finished)
		status = "complete";
	# the label is a widget, so only touch it when it would change
	now := sys->sprint("%s   t %.3g   %s %.3g   %s %.3g",
		status, t, label(model.observablelabels[0]), values[0],
		label(model.observablelabels[1]), values[1]);
	if(now != readout){
		readout = now;
		cmd(".but.at configure -text {"+now+"}");
	}
}

# The mechanism has a panel to itself, so its view is that panel's whole
# image, inset a little so a body on the edge is still drawn whole.
drawmechanism()
{
	mech.draw(mech.r, bg, nil, Point(0,0));
	points := dynsys->points(model, state);
	if(len points == 0)
		return;
	view := mech.r.inset(8);
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
		mech.line(pa, pb, Draw->Endsquare, Draw->Endsquare, 3, bodycolour, Point(0,0));
	}
	for(i = 0; i < len points/2; i++){
		p := project(view, points[2*i], points[2*i+1], xmin, xmax, ymin, ymax);
		mech.ellipse(p, 4, 4, 0, fg, Point(0,0));
	}
}

project(view: Rect, x, y, xmin, xmax, ymin, ymax: real): Point
{
	px := view.min.x+int((x-xmin)/(xmax-xmin)*real(view.dx()));
	py := view.max.y-int((y-ymin)/(ymax-ymin)*real(view.dy()));
	return (px,py);
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

timer(ticks: chan of int)
{
	for(;;){
		sys->sleep(25);
		ticks <-= 1;
	}
}

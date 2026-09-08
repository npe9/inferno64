implement Trajlab;

# See module/trajlab.m for the script vocabulary and why this is a
# library the model calls rather than a module that loads the model back.
# Tk owns the window's structure; Draw owns only the pixels of the two
# plots.  The parameter sliders are Tk scales, the buttons are Tk
# buttons, the status line is a Tk label, and the geometry is Tk's - so
# the 76-pixel control band, the arithmetic that divided it into columns,
# and the routine that truncated a label to fit a column it had guessed
# the width of are all gone.  What is left in Draw is the flight path and
# the speed trace, redrawn wholesale every 25ms.
#
# The plot lives in a "panel" widget holding an image this library owns,
# the same arrangement appl/wm/coffee.b uses for its animation.

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
# trajlab.m includes dynsys.m itself, so a model needs only sys.m, draw.m
# and this one; do NOT include dynsys.m here as well.
include "trajlab.m";
	dynsys: Dynsys;
	Model: import dynsys;

top: ref Toplevel;
cmdch: chan of string;
buffer: ref Image;	# the plot's pixels, handed to the panel widget
font: ref Font;
bg: ref Image;
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
	if(tk == nil)
		tk = load Tk Tk->PATH;
	if(tkclient == nil)
		tkclient = load Tkclient Tkclient->PATH;
	if(draw == nil || numerics == nil || plot == nil ||
			tk == nil || tkclient == nil)
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

# The window: a panel for the plots, a grid of scales for the parameters,
# a row of buttons.  Nothing here knows a pixel offset - Tk works out
# where everything goes, and tk->rect() says afterwards where the plot
# ended up.
tkcfg := array[] of {
	"frame .plot",
	"panel .plot.p -bd 0 -relief flat -width 700 -height 380",
	"pack .plot.p -fill both -expand 1",
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
	"bind .plot.p <Key> {send cmd key %K}",
	"focus .plot.p",
};

cmd(s: string): string
{
	r := tk->cmd(top, s);
	if(r != nil && r[0] == '!')
		sys->fprint(sys->fildes(2), "trajlab: %s: %s\n", s, r);
	return r;
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
	graph = plot->new(nil, font);
	graph.cmd("table history time x y speed -capacity 20000");
	graph.cmd("colour foreground 16r20272cff\n"+
		"colour grid 16rd6d0c4ff\n"+
		"colour path 16rb85c38ff\n"+
		"colour speed 16r178f86ff");
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
			for(k := 0; k < 5 && !finished; k++)
				step();
		redraw();
	}
}

# One label and one scale per parameter, three parameters to a line.  A
# scale's own -command reports the new value, so nothing here has to work
# out which slider the pointer was over or truncate a name to fit.
buildparams()
{
	for(j := 0; j < len model.parameter; j++){
		max := model.maxima[j];
		cmd(sys->sprint("label .par.l%d -text {%s}", j, label(model.paramlabels[j])));
		# -bigincrement defaults to zero, and a scale with a zero big
		# increment answers a click in its trough by re-sending the
		# value it already had: the slider looks live and does nothing
		cmd(sys->sprint("scale .par.s%d -from %g -to %g -resolution %g"+
			" -bigincrement %g -orient horizontal -length 150"+
			" -showvalue 1 -command {send cmd param %d}",
			j, max*0.01, max, max/200.0, max/20.0, j));
		cmd(sys->sprint(".par.s%d set %g", j, model.parameter[j]));
		row := j/3;
		col := (j%3)*2;
		cmd(sys->sprint("grid .par.l%d -row %d -column %d -sticky w -padx 4",
			j, row, col));
		cmd(sys->sprint("grid .par.s%d -row %d -column %d -sticky w",
			j, row, col+1));
	}
}

# Tk says where the plot went; this library only has to keep an image of
# that size.  Does nothing at all unless the size actually changed.
resize()
{
	r := tk->rect(top, ".plot.p", 0);
	(w, h) := (r.dx(), r.dy());
	if(w <= 0 || h <= 0 || top.image == nil)
		return;
	if(buffer != nil && buffer.r.dx() == w && buffer.r.dy() == h)
		return;
	new := top.display.newimage(Rect((0,0),(w,h)), top.image.chans, 0, Draw->White);
	if(new == nil)
		return;
	buffer = new;
	graph.image = buffer;
	tk->putimage(top, ".plot.p", buffer, nil);
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
		# a flight is launched, not steered: a new parameter is a new
		# flight, which is what this family's controls always did
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
	groundimpact = 0;
	xmaximum = 10.0;
	ymaximum = 5.0;
	speedmaximum = speed();
	if(speedmaximum < 10.0)
		speedmaximum = 10.0;
	graph.cmd("history clear");
	record();
	if(top != nil)
		cmd(".but.pause configure -text Pause");
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

readout := "";

redraw()
{
	if(buffer == nil)
		return;
	buffer.draw(buffer.r, bg, nil, Point(0,0));
	graph.cmd("clear");
	graph.cmd("content margin 48 22 18 30\n"+
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
	cmd(".plot.p dirty; update");
	status := "in flight";
	if(groundimpact)
		status = "landed";
	else if(finished)
		status = "complete";
	# the label is a widget, so only touch it when it would change
	now := sys->sprint("%s   t %.3g   range %.3g   speed %.3g",
		status, t, state[0], speed());
	if(now != readout){
		readout = now;
		cmd(".but.at configure -text {"+now+"}");
	}
}

timer(ticks: chan of int)
{
	for(;;){
		sys->sleep(25);
		ticks <-= 1;
	}
}

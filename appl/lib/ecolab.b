implement Ecolab;

# See module/ecolab.m for the script vocabulary and why this is a library
# the model calls rather than a module that loads the model back.
#
# Tk owns the window's structure; Draw owns only the pixels of the plot.
# The parameter sliders are Tk scales, the buttons are Tk buttons, the
# readout is a Tk label, and the geometry is Tk's - so there is no
# hand-rolled hit testing here, and none of the magic offsets that used
# to encode where the bottom strip started (52) or how tall the axis
# furniture was (58, 93).  What is left in Draw is the phase portrait and
# the time series, which are redrawn wholesale every 25ms and are exactly
# the kind of thing Draw is better at than a widget tree.
#
# The plot lives in a "panel" widget holding an image this library owns,
# the same arrangement appl/wm/coffee.b uses for its animation.  A click
# in it arrives as a Tk binding with the coordinates already relative to
# the panel, and plot(2)'s own invert() turns those into species numbers
# through the same scales that drew them - so a click lands where it
# looks like it lands.  (It did not before: ecology.b took the FIRST
# species from the vertical position and the second from the horizontal,
# while the phase plot drew the first species along x.  Clicking the
# portrait therefore started the system at the transpose of the point
# under the pointer.  Inverting through plot(2) cannot get that wrong.)

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
# ecolab.m includes dynsys.m itself, so a model needs only sys.m, draw.m
# and this one; do NOT include dynsys.m here as well.
include "ecolab.m";
	dynsys: Dynsys;
	Model: import dynsys;
	Expr: import Hoc;

top: ref Toplevel;
cmdch: chan of string;
buffer: ref Image;	# the plot's pixels, handed to the panel widget
font: ref Font;
bg: ref Image;
model: ref Model;
eqx, eqy: ref Expr;
fixedscale := 0.0;
y: array of real;
work: ref Numerics->Workspace;
graph: ref Plotter;
t := 0.0;
paused := 0;
title := "";
manual := "";

loadparsemods(): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(sys == nil)
		return "ecolab: cannot load Sys";
	if(dynsys == nil)
		dynsys = load Dynsys Dynsys->PATH;
	if(dynsys == nil)
		return sys->sprint("ecolab: cannot load %s: %r", Dynsys->PATH);
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
		return "ecolab: a drawing module is missing";
	return nil;
}

parse(spec: string): (ref Model, ref Expr, ref Expr, real, string)
{
	if((e := loadparsemods()) != nil)
		return (nil, nil, nil, 0.0, e);
	m := dynsys->newmodel();
	ttl := "";
	man := "";
	ex, ey: ref Expr;
	scale := 0.0;
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
				return (nil, nil, nil, 0.0, lineerr(lineno, "title: usage: title TEXT..."));
			ttl = joinfrom(w, 1);
			continue;
		"manual" =>
			if(nwords != 2)
				return (nil, nil, nil, 0.0, lineerr(lineno, "manual: usage: manual PAGE"));
			man = w[1];
			continue;
		"scale" =>
			if(nwords != 2)
				return (nil, nil, nil, 0.0, lineerr(lineno, "scale: usage: scale NUM"));
			scale = real w[1];
			continue;
		"equilibrium" =>
			comma := -1;
			for(c := 1; c < nwords; c++)
				if(w[c] == ","){
					comma = c;
					break;
				}
			if(nwords < 4 || comma < 2 || comma == nwords-1)
				return (nil, nil, nil, 0.0, lineerr(lineno,
					"equilibrium: usage: equilibrium XEXPR , YEXPR"));
			(x1, e1) := m.hocmod->compileeqn(joinfrom(w[0:comma], 1));
			if(e1 != nil)
				return (nil, nil, nil, 0.0, lineerr(lineno, "equilibrium x: "+e1));
			(y1, e2) := m.hocmod->compileeqn(joinfrom(w, comma+1));
			if(e2 != nil)
				return (nil, nil, nil, 0.0, lineerr(lineno, "equilibrium y: "+e2));
			ex = x1;
			ey = y1;
			continue;
		}
		(claimed, err) := dynsys->cmd(m, w);
		if(err != nil)
			return (nil, nil, nil, 0.0, lineerr(lineno, err));
		if(!claimed)
			return (nil, nil, nil, 0.0, lineerr(lineno, "unknown command "+w[0]));
	}
	if((err := dynsys->check(m)) != nil)
		return (nil, nil, nil, 0.0, err);
	if(ttl == "")
		return (nil, nil, nil, 0.0, "spec has no title command");
	if(ex == nil)
		return (nil, nil, nil, 0.0,
			"spec has no equilibrium command, which is what this family shows");
	if(len m.statenames != 2)
		return (nil, nil, nil, 0.0, sys->sprint(
			"two species means two states, and this spec has %d",
			len m.statenames));
	for(i := 0; i < len m.parameter; i++)
		if(m.minima[i] != 0.0)
			return (nil, nil, nil, 0.0, sys->sprint(
				"param %s: this family's sliders run from zero, so its minimum must be 0.0",
				m.paramlabels[i]));
	title = ttl;
	manual = man;
	return (m, ex, ey, scale, nil);
}

# The parameters must already be bound, which dynsys->initialstate() and
# rhs() both do.
equilibrium(m: ref Model, ex, ey: ref Expr): (real, real)
{
	return (m.hocmod->eval(ex), m.hocmod->eval(ey));
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


# The window: a panel for the plot, a grid of scales for the parameters,
# a row of buttons.  Nothing here knows a pixel offset - Tk works out
# where everything goes, and tk->rect() says afterwards where the plot
# ended up.
tkcfg := array[] of {
	"frame .plot",
	"panel .plot.p -bd 0 -relief flat -width 640 -height 380",
	"pack .plot.p -fill both -expand 1",
	"frame .par",
	"frame .but",
	"button .but.reset -text Reset -command {send cmd reset}",
	"button .but.pause -text Pause -command {send cmd pause}",
	"label .but.at -text {}",
	"pack .but.reset .but.pause -side left",
	"pack .but.at -side left -padx 10",
	"pack .but -side bottom -fill x",
	"pack .par -side bottom -fill x",
	"pack .plot -side top -fill both -expand 1",
	"bind .plot.p <Button-1> {send cmd plot %x %y}",
	"bind . <Key> {send cmd key %K}",
	"bind .plot.p <Key> {send cmd key %K}",
	"focus .plot.p",
};

cmd(s: string): string
{
	r := tk->cmd(top, s);
	if(r != nil && r[0] == '!')
		sys->fprint(sys->fildes(2), "ecolab: %s: %s\n", s, r);
	return r;
}

run(ctxt: ref Draw->Context, name, spec: string): string
{
	err: string;
	(model, eqx, eqy, fixedscale, err) = parse(spec);
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
	y = dynsys->initialstate(model);
	work = numerics->workspace(len y);
	graph = plot->new(nil, font);
	graph.cmd("table history time first second -capacity 12000");
	graph.cmd("table equilibrium first second -capacity 1");
	graph.cmd("table current first second -capacity 1");
	graph.cmd("colour foreground 16r20272cff\n"+
		"colour grid 16rd6d0c4ff\n"+
		"colour live 16r178f86ff\n"+
		"colour accent 16rb85c38ff");
	restart(-1.0, -1.0);
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
		if(!paused)
			for(k := 0; k < 4; k++)
				step();
		redraw();
	}
}

# One row per parameter, two rows to a line, laid out by Tk.  A scale's
# own -command reports the new value, so nothing here has to work out
# which slider the pointer was over.
buildparams()
{
	n := len model.parameter;
	for(j := 0; j < n; j++){
		max := model.maxima[j];
		# the old strip clamped a click at 2% of the range rather than
		# let a parameter reach exactly zero; the scale's own -from
		# says the same thing, and says it where the user can see it
		cmd(sys->sprint("label .par.l%d -text {%s}", j, label(model.paramlabels[j])));
		# -bigincrement defaults to zero, and a scale with a zero big
		# increment answers a click in its trough by re-sending the
		# value it already had: the slider looks live and does nothing
		cmd(sys->sprint("scale .par.s%d -from %g -to %g -resolution %g"+
			" -bigincrement %g -orient horizontal -length 170"+
			" -showvalue 1 -command {send cmd param %d}",
			j, max*0.02, max, max/200.0, max/20.0, j));
		cmd(sys->sprint(".par.s%d set %g", j, model.parameter[j]));
		row := j/2;
		col := (j%2)*2;
		cmd(sys->sprint("grid .par.l%d -row %d -column %d -sticky w -padx 4",
			j, row, col));
		cmd(sys->sprint("grid .par.s%d -row %d -column %d -sticky w",
			j, row, col+1));
	}
}

# Tk says where the plot went; this library only has to keep an image of
# that size.  Called after every window-manager message, and does nothing
# at all unless the size actually changed.
resize()
{
	r := tk->rect(top, ".plot.p", 0);
	(w, h) := (r.dx(), r.dy());
	if(w <= 0 || h <= 0)
		return;
	if(buffer != nil && buffer.r.dx() == w && buffer.r.dy() == h)
		return;
	if(top.image == nil)
		return;
	buffer = top.display.newimage(Rect((0,0),(w,h)), top.image.chans, 0, Draw->White);
	if(buffer == nil)
		return;
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
		restart(-1.0, -1.0);
	"pause" =>
		paused = !paused;
		lbl := "Pause";
		if(paused)
			lbl = "Go";
		cmd(sys->sprint(".but.pause configure -text %s", lbl));
	"step" =>
		if(paused)
			step();
	"quit" =>
		tkclient->wmctl(top, "exit");
		return 1;
	"param" =>
		# read every scale rather than trust one message: tk drops
		# queued messages silently, and a dropped last drag event
		# would otherwise leave a parameter behind the slider
		for(j := 0; j < len model.parameter; j++)
			model.parameter[j] = real cmd(sys->sprint(".par.s%d get", j));
	"plot" =>
		if(len w != 3 || buffer == nil)
			return 0;
		p := Point(int hd tl w, int hd tl tl w);
		(a, b, err) := graph.invert("phase", p);
		if(err != nil)
			return 0;	# the click was in the time series, which is a readout
		restart(a, b);
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
			restart(-1.0, -1.0);
		'.' =>
			if(paused)
				step();
		}
	}
	return 0;
}

derivs(rhsTime: real, q, d: array of real)
{
	dynsys->rhs(model, rhsTime, q, d);
}

# Start again from time zero with an empty history, either at the spec's
# own initial state (a negative argument) or at a point the user picked.
# Every path that clears the history goes through here, so none of them
# can forget to record the first sample.
restart(a, b: real)
{
	if(a < 0.0 || b < 0.0)
		y = dynsys->initialstate(model);
	else
		(y[0], y[1]) = (a, b);
	t = 0.0;
	graph.cmd("history clear");
	record();
}

step()
{
	numerics->rk4(work, derivs, t, 0.008, y);
	t += 0.008;
	# neither species can go negative, which is this family's own rule
	for(i := 0; i < len y; i++)
		if(y[i] < 0.0)
			y[i] = 0.0;
	record();
}

record()
{
	graph.cmd(sys->sprint("history append %.17g %.17g %.17g", t, y[0], y[1]));
}

# Both phase axes share one maximum, so the portrait stays square in
# units and a circling trajectory looks like one.
phasetop(): real
{
	if(fixedscale > 0.0)
		return fixedscale;
	maximum := 1.5;
	if(y[0]*1.15 > maximum)
		maximum = y[0]*1.15;
	if(y[1]*1.15 > maximum)
		maximum = y[1]*1.15;
	return maximum;
}

readout := "";

redraw()
{
	if(buffer == nil)
		return;
	buffer.draw(buffer.r, bg, nil, Point(0,0));
	maximum := phasetop();
	graph.cmd("clear");
	graph.cmd("content margin 45 22 18 30\n"+
		"split content x phase 1 time 1 gutter 54\n"+
		"view phase phase");
	graph.cmd(sys->sprint("scale phase x 0 %.8g", maximum));
	graph.cmd(sys->sprint("scale phase y 0 %.8g reverse", maximum));
	graph.cmd("axis phase x "+model.statenames[0]);
	graph.cmd("axis phase y "+model.statenames[1]);
	graph.cmd("equilibrium clear");
	deriv := array[len y] of real;
	dynsys->rhs(model, t, y, deriv);	# binds the parameters
	(ex, ey) := equilibrium(model, eqx, eqy);
	graph.cmd(sys->sprint("equilibrium append %.17g %.17g", ex, ey));
	graph.cmd("current clear");
	graph.cmd(sys->sprint("current append %.17g %.17g", y[0], y[1]));
	graph.cmd("line phase history x first y second colour foreground width 2");
	graph.cmd("point phase equilibrium x first y second colour accent radius 5");
	graph.cmd("point phase current x first y second colour live radius 4");
	tmax := t;
	if(tmax < 10.0)
		tmax = 10.0;
	graph.cmd("view time time");
	graph.cmd(sys->sprint("scale time x 0 %.8g", tmax));
	graph.cmd(sys->sprint("scale time y 0 %.8g reverse", maximum));
	graph.cmd("axis time x time");
	graph.cmd("axis time y population");
	graph.cmd("line time history x time y first colour live width 2");
	graph.cmd("line time history x time y second colour accent width 2");
	graph.draw();
	cmd(".plot.p dirty; update");
	# the label is a widget, so only touch it when it would change
	now := sys->sprint("t %.1f   %s %.3g   %s %.3g   equilibrium %.3g, %.3g",
		t, label(model.statenames[0]), y[0],
		label(model.statenames[1]), y[1], ex, ey);
	if(now != readout){
		readout = now;
		cmd(".but.at configure -text {"+now+"}");
	}
}

timer(c: chan of int)
{
	for(;;){
		sys->sleep(25);
		c <-= 1;
	}
}

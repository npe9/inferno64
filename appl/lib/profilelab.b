implement Profilelab;

# See module/profilelab.m for the script vocabulary and why this is a
# library the model calls rather than a module that loads the model back.
# Tk owns the window's structure; Draw owns only the pixels of the graph.
# The parameter sliders are Tk scales, the buttons are Tk buttons, the
# legend is a Tk label, and the geometry is Tk's - so the 70-pixel
# control band and the arithmetic that divided it into columns are gone.
#
# The graph lives in a "panel" widget holding an image this library owns,
# the same arrangement appl/wm/coffee.b uses for its animation.  Nothing
# here runs on a timer: a profile is computed once when a parameter
# changes and then just sits there, so redraw happens on an event and not
# forty times a second.

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
include "plot.m";
	plot: Plot;
	Plotter: import plot;
include "env.m";
	env: Env;
# profilelab.m includes dynsys.m itself, so a model needs only sys.m, draw.m
# and this one; do NOT include dynsys.m here as well.
include "profilelab.m";
	dynsys: Dynsys;
	Model: import dynsys;
	Expr: import Hoc;

top: ref Toplevel;
cmdch: chan of string;
buffer: ref Image;	# the plot's pixels, handed to the panel widget
font: ref Font;
bg: ref Image;
model: ref Model;
graph: ref Plotter;
startexpr, spanexpr: ref Expr;
samples := 320;
normalised := -1;
data: array of real;
defaults: array of real;
title := "";
manual := "";

loadparsemods(): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(sys == nil)
		return "profilelab: cannot load Sys";
	if(dynsys == nil)
		dynsys = load Dynsys Dynsys->PATH;
	if(dynsys == nil)
		return sys->sprint("profilelab: cannot load %s: %r", Dynsys->PATH);
	return nil;
}

loaddrawmods(): string
{
	if(draw == nil)
		draw = load Draw Draw->PATH;
	if(plot == nil)
		plot = load Plot Plot->PATH;
	if(tk == nil)
		tk = load Tk Tk->PATH;
	if(tkclient == nil)
		tkclient = load Tkclient Tkclient->PATH;
	if(draw == nil || plot == nil ||
			tk == nil || tkclient == nil)
		return "profilelab: a drawing module is missing";
	return nil;
}

parse(spec: string): (ref Model, ref Expr, ref Expr, int, int, string)
{
	if((e := loadparsemods()) != nil)
		return (nil, nil, nil, 0, -1, e);
	m := dynsys->newmodel();
	ttl := "";
	man := "";
	start, span: ref Expr;
	nsamples := 320;
	normname := "";
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
				return bad(lineno, "title: usage: title TEXT...");
			ttl = joinfrom(w, 1);
			continue;
		"manual" =>
			if(nwords != 2)
				return bad(lineno, "manual: usage: manual PAGE");
			man = w[1];
			continue;
		"samples" =>
			if(nwords != 2)
				return bad(lineno, "samples: usage: samples N");
			nsamples = int w[1];
			if(nsamples < 2)
				return bad(lineno, "samples: a profile needs at least two");
			continue;
		"normalise" =>
			if(nwords != 2)
				return bad(lineno, "normalise: usage: normalise NAME");
			normname = w[1];
			continue;
		"radius" =>
			comma := -1;
			for(c := 1; c < nwords; c++)
				if(w[c] == ","){
					comma = c;
					break;
				}
			if(nwords < 4 || comma < 2 || comma == nwords-1)
				return bad(lineno, "radius: usage: radius STARTEXPR , SPANEXPR");
			(s1, e1) := m.hocmod->compileeqn(joinfrom(w[0:comma], 1));
			if(e1 != nil)
				return bad(lineno, "radius start: "+e1);
			(s2, e2) := m.hocmod->compileeqn(joinfrom(w, comma+1));
			if(e2 != nil)
				return bad(lineno, "radius span: "+e2);
			start = s1;
			span = s2;
			continue;
		}
		(claimed, err) := dynsys->cmd(m, w);
		if(err != nil)
			return bad(lineno, err);
		if(!claimed)
			return bad(lineno, "unknown command "+w[0]);
	}
	# there is no time in a profile; dynsys wants a maxtime all the same
	if(m.maxtime <= 0.0)
		dynsys->cmd(m, array[] of {"maxtime", "1.0"});
	if((err := dynsys->check(m)) != nil)
		return (nil, nil, nil, 0, -1, err);
	if(ttl == "")
		return (nil, nil, nil, 0, -1, "spec has no title command");
	if(start == nil)
		return (nil, nil, nil, 0, -1,
			"spec has no radius command, and a profile has to start somewhere");
	if(len m.observablelabels != 2)
		return (nil, nil, nil, 0, -1, sys->sprint(
			"this family draws two curves, and this spec has %d observable lines",
			len m.observablelabels));
	which := -1;
	if(normname != ""){
		for(i := 0; i < len m.observablelabels; i++)
			if(m.observablelabels[i] == normname)
				which = i;
		if(which < 0)
			return (nil, nil, nil, 0, -1,
				"normalise "+normname+": no observable of that name");
	}
	title = ttl;
	manual = man;
	return (m, start, span, nsamples, which, nil);
}

bad(n: int, s: string): (ref Model, ref Expr, ref Expr, int, int, string)
{
	return (nil, nil, nil, 0, -1, lineerr(n, s));
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

# The window: a panel for the graph, a grid of scales for the parameters,
# a row of buttons.  Nothing here knows a pixel offset - Tk works out
# where everything goes, and tk->rect() says afterwards where the plot
# ended up.
tkcfg := array[] of {
	"frame .plot",
	"panel .plot.p -bd 0 -relief flat -width 700 -height 420",
	"pack .plot.p -fill both -expand 1",
	"frame .par",
	"frame .but",
	"button .but.reset -text Reset -command {send cmd reset}",
	"label .but.at -text {}",
	"pack .but.reset -side left",
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
		sys->fprint(sys->fildes(2), "profilelab: %s: %s\n", s, r);
	return r;
}

run(ctxt: ref Draw->Context, name, spec: string): string
{
	err: string;
	(model, startexpr, spanexpr, samples, normalised, err) = parse(spec);
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
	graph.cmd("table profile radius first second -capacity 4096");
	graph.cmd("colour foreground 16r20272cff\n"+
		"colour grid 16rd6d0c4ff\n"+
		"colour first 16r178f86ff\n"+
		"colour second 16rb85c38ff");
	cmd(".but.at configure -text {"+label(model.observablelabels[0])+" / "+
		label(model.observablelabels[1])+"}");
	defaults = array[len model.parameter] of real;
	for(i = 0; i < len defaults; i++)
		defaults[i] = model.parameter[i];
	recompute();
	resize();
	redraw();
	# a profile does not move: nothing is redrawn until something asks
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
	}
}

# One label and one scale per parameter, three parameters to a line.  A
# scale's own -command reports the new value, so nothing here has to work
# out which slider the pointer was over.  A central density does not
# start at zero, so the scale runs from the spec's own minimum.
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
			j, lo, hi, (hi-lo)/400.0, (hi-lo)/20.0, j));
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
		for(j := 0; j < len model.parameter; j++)
			cmd(sys->sprint(".par.s%d set %g", j, defaults[j]));
		for(j = 0; j < len model.parameter; j++)
			model.parameter[j] = defaults[j];
		recompute();
	"param" =>
		# read every scale rather than trust one message: tk drops
		# queued messages silently, and a dropped last drag event
		# would otherwise leave a parameter behind the slider
		for(j := 0; j < len model.parameter; j++)
			model.parameter[j] = real cmd(sys->sprint(".par.s%d get", j));
		recompute();
	"key" =>
		if(len w != 2)
			return 0;
		case int ("16r"+hd tl w) {
		16r1b or 'q' or 'Q' =>
			tkclient->wmctl(top, "exit");
			return 1;
		'r' or 'R' =>
			return control("reset");
		}
	}
	return 0;
}

recompute()
{
	data = march(model, startexpr, spanexpr, samples, normalised);
	graph.cmd("profile clear");
	for(i := 0; i < samples; i++)
		graph.cmd(sys->sprint("profile append %.17g %.17g %.17g",
			data[3*i], data[3*i+1], data[3*i+2]));
}

# The march: explicit Euler outward in radius, recording the observables
# before each step, then dividing one column by its outermost value.
# This is the whole model - there is no window in it, and profilelabtest(1)
# calls it directly.
march(m: ref Model, start, span: ref Expr, samples, normalised: int): array of real
{
	state := dynsys->initialstate(m);	# also binds the parameters
	r := m.hocmod->eval(start);
	dr := m.hocmod->eval(span)/real(samples-1);
	deriv := array[len state] of real;
	out := array[3*samples] of real;
	for(i := 0; i < samples; i++){
		m.hocmod->setvar("r", r);
		values := dynsys->observables(m, state);
		out[3*i] = r;
		out[3*i+1] = values[0];
		out[3*i+2] = values[1];
		dynsys->rhs(m, r, state, deriv);
		for(j := 0; j < len state; j++){
			state[j] += dr*deriv[j];
			if(state[j] < 0.0)
				state[j] = 0.0;
		}
		r += dr;
	}
	if(normalised >= 0){
		outer := out[3*(samples-1)+1+normalised];
		if(outer > 0.0)
			for(i = 0; i < samples; i++)
				out[3*i+1+normalised] /= outer;
	}
	return out;
}

redraw()
{
	if(buffer == nil || data == nil)
		return;
	buffer.draw(buffer.r, bg, nil, Point(0,0));
	ymax := 1.0;
	for(i := 0; i < samples; i++){
		if(data[3*i+1] > ymax)
			ymax = data[3*i+1];
		if(data[3*i+2] > ymax)
			ymax = data[3*i+2];
	}
	graph.cmd("clear");
	graph.cmd("content margin 55 24 20 32\nview radial content");
	graph.cmd(sys->sprint("scale radial x 0 %.8g", data[3*(samples-1)]));
	graph.cmd(sys->sprint("scale radial y 0 %.8g reverse", ymax));
	graph.cmd("axis radial x radius");
	graph.cmd("axis radial y value");
	graph.cmd("line radial profile x radius y first colour first width 2");
	graph.cmd("line radial profile x radius y second colour second width 2");
	graph.draw();
	cmd(".plot.p dirty; update");
}

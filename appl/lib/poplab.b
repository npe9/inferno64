implement Poplab;

# See module/poplab.m for the script vocabulary and why this is a library
# the model calls rather than a module that loads the model back.
# Tk owns the window's structure; Draw owns only the pixels of the two
# plots.  The parameter sliders are Tk scales, the buttons are Tk
# buttons, the readout is a Tk label, and the geometry is Tk's, so the
# row-of-six parameter arithmetic and the hand-placed 180-pixel bar strip
# are gone along with every offset that went with them (42, 12, 35, 30).
# What is left in Draw is the history plot and the state bars, both
# redrawn wholesale every 25ms.
#
# Each of those is a "panel" widget holding an image this library owns,
# the same arrangement appl/wm/coffee.b uses for its animation.  A click
# in either arrives as a Tk binding with coordinates already relative to
# that panel, so the hit test is the panel's own size and nothing else.

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
# poplab.m includes dynsys.m itself, so a model needs only sys.m, draw.m
# and this one; do NOT include dynsys.m here as well.
include "poplab.m";
	dynsys: Dynsys;
	Model: import dynsys;

top: ref Toplevel;
cmdch: chan of string;
buffer: ref Image;	# the history plot's pixels
bars: ref Image;	# the state bars' pixels
font: ref Font;
bg, fg, grid: ref Image;
palette: array of ref Image;
palettevalue := array[] of {
	int 16r178f86ff, int 16rb85c38ff, int 16r526fa8ff,
	int 16r9673a6ff, int 16rd49a32ff, int 16r6f8f3dff
};
model: ref Model;
initial: array of real;
state: array of real;
work: ref Numerics->Workspace;
graph: ref Plotter;
t := 0.0;
paused := 0;
displaymax := 1.0;
title := "";
manual := "";

loadparsemods(): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(sys == nil)
		return "poplab: cannot load Sys";
	if(dynsys == nil)
		dynsys = load Dynsys Dynsys->PATH;
	if(dynsys == nil)
		return sys->sprint("poplab: cannot load %s: %r", Dynsys->PATH);
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
		return "poplab: a drawing module is missing";
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

# The window: one panel for the history plot, another for the state bars,
# a grid of scales for the parameters, a row of buttons.  Nothing here
# knows a pixel offset - Tk works out where everything goes, and
# tk->rect() says afterwards where each panel ended up.
tkcfg := array[] of {
	"frame .plot",
	"panel .plot.p -bd 0 -relief flat -width 600 -height 380",
	"panel .plot.bars -bd 0 -relief flat -width 180 -height 380",
	"pack .plot.bars -side right -fill y",
	"pack .plot.p -side left -fill both -expand 1",
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
	"bind .plot.bars <Button-1> {send cmd bar %x %y}",
	"bind . <Key> {send cmd key %K}",
	"bind .plot.p <Key> {send cmd key %K}",
	"focus .plot.p",
};

cmd(s: string): string
{
	r := tk->cmd(top, s);
	if(r != nil && r[0] == '!')
		sys->fprint(sys->fildes(2), "poplab: %s: %s\n", s, r);
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
	fg = top.display.color(int 16r20272cff);
	grid = top.display.color(int 16rd6d0c4ff);
	palette = array[len palettevalue] of ref Image;
	for(i = 0; i < len palette; i++)
		palette[i] = top.display.color(palettevalue[i]);
	initial = dynsys->initialstate(model);
	state = array[len initial] of real;
	work = numerics->workspace(len state);
	graph = plot->new(nil, font);
	table := "table history time";
	for(i = 0; i < len state; i++)
		table += " state" + string i;
	graph.cmd(table + " -capacity 16000");
	colours := "colour grid 16rd6d0c4ff";
	for(i = 0; i < len palettevalue; i++)
		colours += sys->sprint("\ncolour state%d 16r%ux", i, palettevalue[i]);
	graph.cmd(colours);
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
		if(!paused)
			for(k := 0; k < 4; k++)
				step();
		redraw();
	}
}

# One label and one scale per parameter, three parameters to a line.  A
# scale's own -command reports the new value, so nothing here has to work
# out which slider the pointer was over, or how many fit in a row.
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

# Tk says where each panel went; this library only has to keep images of
# those sizes.  Does nothing at all unless a size actually changed.
resize()
{
	if(top.image == nil)
		return;
	buffer = refit(buffer, ".plot.p");
	bars = refit(bars, ".plot.bars");
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
		# the state lines are expressions in the parameters, so a
		# parameter change is a new problem, not a nudge to this one
		reset();
	"bar" =>
		if(len w != 3 || bars == nil)
			return 0;
		(px, py) := (int hd tl w, int hd tl tl w);
		height := bars.r.dy()/len state;
		if(height <= 0)
			return 0;
		which := py/height;
		if(which < 0 || which >= len state)
			return 0;
		state[which] = displaymax*real px/real bars.r.dx();
		if(state[which] < 0.0)
			state[which] = 0.0;
		t = 0.0;
		graph.cmd("history clear");
		record();
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
			if(paused)
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
	# the initial values are the state lines' own expressions, so they
	# follow the parameters a slider has just changed
	initial = dynsys->initialstate(model);
	for(i := 0; i < len state; i++)
		state[i] = initial[i];
	t = 0.0;
	displaymax = 1.0;
	for(i = 0; i < len state; i++)
		if(state[i]*1.15 > displaymax)
			displaymax = state[i]*1.15;
	graph.cmd("history clear");
	record();
}

step()
{
	numerics->rk4(work, rhs, t, 0.008, state);
	t += 0.008;
	for(i := 0; i < len state; i++){
		if(state[i] < 0.0)
			state[i] = 0.0;
		if(state[i]*1.15 > displaymax)
			displaymax = state[i]*1.15;
	}
	record();
}

record()
{
	command := sys->sprint("history append %.17g", t);
	for(i := 0; i < len state; i++)
		command += sys->sprint(" %.17g", state[i]);
	graph.cmd(command);
}

readout := "";

redraw()
{
	if(buffer == nil || bars == nil)
		return;
	buffer.draw(buffer.r, bg, nil, Point(0,0));
	tmax := t;
	if(tmax < 10.0)
		tmax = 10.0;
	graph.cmd("clear");
	graph.cmd("content margin 48 22 18 30\nview historyplot content");
	graph.cmd(sys->sprint("scale historyplot x 0 %.8g", tmax));
	graph.cmd(sys->sprint("scale historyplot y 0 %.8g reverse", displaymax));
	graph.cmd("axis historyplot x time");
	graph.cmd("axis historyplot y quantity");
	for(i := 0; i < len state; i++)
		graph.cmd(sys->sprint(
			"line historyplot history x time y state%d colour state%d width 2",
			i, i%len palette));
	graph.draw();
	drawstatebars();
	cmd(".plot.p dirty; .plot.bars dirty; update");
	# the label is a widget, so only touch it when it would change
	now := sys->sprint("t %.2f", t);
	if(now != readout){
		readout = now;
		cmd(".but.at configure -text {"+now+"}");
	}
}

# The bars are their own panel, so a bar's height is the panel's height
# divided by the number of states and nothing else.
drawstatebars()
{
	bars.draw(bars.r, bg, nil, Point(0,0));
	r := bars.r.inset(6);
	height := r.dy()/len state;
	for(i := 0; i < len state; i++){
		y := r.min.y+i*height;
		bars.text((r.min.x,y+font.height), fg, Point(0,0), font,
			sys->sprint("%s %.4g", label(model.statenames[i]), state[i]));
		track := Rect((r.min.x,y+font.height+4), (r.max.x,y+height-5));
		bars.draw(track, grid, nil, Point(0,0));
		filled := track;
		filled.max.x = filled.min.x+
			int(real(track.dx())*state[i]/displaymax);
		bars.draw(filled, palette[i%len palette], nil, Point(0,0));
	}
}

timer(ticks: chan of int)
{
	for(;;){
		sys->sleep(25);
		ticks <-= 1;
	}
}

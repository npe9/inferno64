implement Danbylab;

# See module/danbylab.m for the split this file implements: dynsys(2)
# owns the equations, Config owns the picture, and the spec's "family"
# line says which of the seven pictures it is.
#
# The shape of the file follows the shape of the program:
#
#	the script	parse() and the family words it does not hand
#			to dynsys(2)
#	the window	Tk owns the structure - the sliders are scales,
#			the buttons are buttons, the status line is a
#			label, and the geometry is Tk's.  Draw owns only
#			the pixels inside the panels.
#	the simulation	Sim: everything that changes as time runs, and
#			nothing that does not
#	the picture	one redraw(), and the per-family drawing it calls
#	the loop	one event loop for all seven families
#
# Where the families differ, they differ inside a single function, so
# the difference is visible in one place rather than spread over seven
# files.  Where they do not differ there is one copy.

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
include "danbylab.m";
	dynsys: Dynsys;
	Model: import dynsys;
	Expr: import Hoc;

Ntrail: con 1600;	# Orbit: how much trail a body keeps

# The two themes.  Paper for the six families drawn on a page, sky for
# the orbits, which are not.
Paper, Sky: con iota;

themebg := array[] of {int 16rf4f0e7ff, int 16r080d18ff};
themefg := array[] of {int 16r20272cff, int 16re7edf7ff};
themegrid := array[] of {int 16rd6d0c4ff, int 16r394457ff};

# The same value in the two notations the two languages want: plot(2)
# reads 16rRRGGBBAA, Tk reads #RRGGBB.  %ux and not %x, because a colour
# whose red is above 0x7f is a negative int.
plotcolour(v: int): string
{
	return sys->sprint("16r%.8ux", v);
}

tkcolour(v: int): string
{
	return sys->sprint("#%.6ux", (v>>8)&16rffffff);
}

# A panel widget and the image this library draws into it.  The panel is
# where Tk stops and Draw starts.
Pane: adt {
	w:	string;		# the widget, ".plot.g"
	req:	string;		# its requested size
	pack:	string;		# how it is packed
	im:	ref Image;	# its pixels, ours to draw on
};

# The furniture: what the family wants the window to look like and how
# fast it wants time to run.  Derived from the family, never from the
# spec, which is why it is not in Config.
Look: adt {
	panes:		array of ref Pane;
	graphpane:	int;	# which pane the plotter draws in
	diagpane:	int;	# and which the family's own diagram goes in, -1 for none
	focus:		string;	# the pane that takes the keyboard
	theme:		int;
	pause:		int;	# a Pause button, and time to pause
	atwidth:	int;	# the status label's fixed width
	percol:		int;	# parameter sliders to a row
	sliderlen:	int;
	steps:		int;	# slider positions across a parameter's range
	click:		string;	# the pane that reports Button-1, nil for none
	clickcmd:	string;	# and what it reports it as
	dt:		real;	# one integration step
	perframe:	int;	# and how many to a frame, 0 for a still picture
};

# Everything that changes as time runs.  A family uses the fields it
# needs and leaves the rest alone: obsmax belongs to Mechanism and Orbit,
# dispmax to Population, xmax/ymax/latmax/vmax to Trajectory and Flight,
# mass and the trail to Orbit, data and home to Profile.
Sim: adt {
	state:		array of real;
	work:		ref Numerics->Workspace;
	t:		real;
	paused:		int;
	finished:	int;
	grounded:	int;

	obsmax:		array of real;
	dispmax:	real;
	xmax, ymax, latmax, vmax: real;

	mass:		array of real;
	trail:		array of array of real;
	trailcount:	int;
	trailnext:	int;

	data:		array of real;
	home:		array of real;

	reset:		fn(s: self ref Sim);
	step:		fn(s: self ref Sim);
	record:		fn(s: self ref Sim);
	land:		fn(s: self ref Sim, old: array of real, oldt: real, h: int);
	grow:		fn(s: self ref Sim);
	pushtrail:	fn(s: self ref Sim);
	trailat:	fn(s: self ref Sim, k: int): array of real;
	speed:		fn(s: self ref Sim): real;
};

model: ref Model;
cfg: ref Config;
look: ref Look;
sim: ref Sim;

top: ref Toplevel;
cmdch: chan of string;
font: ref Font;
bg, fg, gridcolour: ref Image;
palette: array of ref Image;
graph: ref Plotter;
readout := "";

# The palette both Population's bars and Orbit's bodies index into.
palettevalue := array[] of {
	int 16r178f86ff, int 16rb85c38ff, int 16r7b5aa6ff,
	int 16r4ec9b0ff, int 16rf2b84bff, int 16r70a5ffff
};

# Orbit draws on a night sky, so its bodies need their own, brighter set.
bodyvalue := array[] of {
	int 16rf2b84bff, int 16r4ec9b0ff, int 16r70a5ffff,
	int 16re77c8eff, int 16rc792eaff, int 16r9dd274ff
};
bodycolour: array of ref Image;


# ---------------------------------------------------------------- the script

# Idempotent: parse() needs only these two, and calls this itself so a
# test can call parse() without calling anything else first.
loadcore(): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(sys == nil)
		return "danbylab: cannot load Sys";
	if(dynsys == nil)
		dynsys = load Dynsys Dynsys->PATH;
	if(dynsys == nil)
		return sys->sprint("danbylab: cannot load %s: %r", Dynsys->PATH);
	return nil;
}

# Also idempotent, and also not needed to read a script: a test that
# checks a model's numbers runs where there is no display at all.
loadui(): string
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
	if(math == nil)
		math = load Math Math->PATH;
	if(draw == nil || numerics == nil || plot == nil ||
			tk == nil || tkclient == nil || math == nil)
		return "danbylab: a drawing module is missing";
	return nil;
}

familynames := array[] of {
	"mechanism", "population", "trajectory", "orbit",
	"ecology", "flight", "profile"
};

familyof(name: string): int
{
	for(i := 0; i < len familynames; i++)
		if(familynames[i] == name)
			return i;
	return -1;
}

# Four families have words of their own.  A spec that uses one belongs
# to that family and to no other, which is what the seven separate
# libraries used to say by not implementing each other's vocabulary.
ownwords := array[] of {
	"link", "body", "scale", "equilibrium", "radius", "samples", "normalise"
};
ownfamily := array[] of {
	Mechanism, Orbit, Ecology, Ecology, Profile, Profile, Profile
};

ownedby(word: string): int
{
	for(i := 0; i < len ownwords; i++)
		if(ownwords[i] == word)
			return ownfamily[i];
	return -1;
}

parse(spec: string): (ref Model, ref Config, string)
{
	if((e := loadcore()) != nil)
		return (nil, nil, e);
	m := dynsys->newmodel();
	c := ref Config;
	c.family = -1;
	c.normalised = -1;
	c.samples = 320;
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
		err: string;
		claimed := 0;
		if((owner := ownedby(w[0])) >= 0){
			if(c.family < 0)
				return (nil, nil, lineerr(lineno,
					w[0]+": the family command must come first"));
			if(c.family != owner)
				return (nil, nil, lineerr(lineno, sys->sprint(
					"%s: only the %s family has a %s command, and this is a %s",
					w[0], familynames[owner], w[0], familynames[c.family])));
		}
		case w[0] {
		"family" =>
			claimed = 1;
			if(nwords != 2)
				err = "family: usage: family "+joinwith(familynames, "|");
			else if((c.family = familyof(w[1])) < 0)
				err = "family: no family called "+w[1];
		"title" =>
			claimed = 1;
			if(nwords < 2)
				err = "title: usage: title TEXT...";
			else
				c.title = joinfrom(w, 1);
		"manual" =>
			claimed = 1;
			if(nwords != 2)
				err = "manual: usage: manual PAGE";
			else
				c.manual = w[1];
		"link" =>
			claimed = 1;
			err = link(m, c, w, nwords);
		"body" =>
			claimed = 1;
			err = body(m, c, w, nwords);
		"scale" =>
			claimed = 1;
			if(nwords != 2)
				err = "scale: usage: scale NUM";
			else
				c.fixedscale = real w[1];
		"equilibrium" =>
			claimed = 1;
			(c.equilx, c.equily, err) = pair(m, w, nwords,
				"equilibrium: usage: equilibrium XEXPR , YEXPR");
		"radius" =>
			claimed = 1;
			(c.radius, c.span, err) = pair(m, w, nwords,
				"radius: usage: radius STARTEXPR , SPANEXPR");
		"samples" =>
			claimed = 1;
			if(nwords != 2)
				err = "samples: usage: samples N";
			else if((c.samples = int w[1]) < 2)
				err = "samples: a profile needs at least two";
		"normalise" =>
			claimed = 1;
			if(nwords != 2)
				err = "normalise: usage: normalise NAME";
			else
				normname = w[1];
		}
		if(err != nil)
			return (nil, nil, lineerr(lineno, err));
		if(claimed)
			continue;
		(claimed, err) = dynsys->cmd(m, w);
		if(err != nil)
			return (nil, nil, lineerr(lineno, err));
		if(!claimed)
			return (nil, nil, lineerr(lineno, "unknown command "+w[0]));
	}

	if(c.family < 0)
		return (nil, nil, "spec has no family command, so nothing knows what to draw");
	# there is no time in a profile; dynsys wants a maxtime all the same
	if(c.family == Profile && m.maxtime <= 0.0)
		dynsys->cmd(m, array[] of {"maxtime", "1.0"});
	if((err := dynsys->check(m)) != nil)
		return (nil, nil, err);
	if(c.title == "")
		return (nil, nil, "spec has no title command");
	if(normname != ""){
		if((c.normalised = nameindex(m.observablelabels, normname)) < 0)
			return (nil, nil, "normalise "+normname+": no observable of that name");
	}
	if((err = checkspec(m, c)) != nil)
		return (nil, nil, err);
	return (m, c, nil);
}

# "link NAME NAME": a rod between two of the mechanism's points.
link(m: ref Model, c: ref Config, w: array of string, nwords: int): string
{
	if(nwords != 3)
		return "link: usage: link NAME NAME";
	for(i := 1; i <= 2; i++)
		if(nameindex(m.pointnames, w[i]) < 0)
			return "link: no point named "+w[i];
	n := len c.links;
	l := array[n+2] of int;
	for(i = 0; i < n; i++)
		l[i] = c.links[i];
	l[n] = nameindex(m.pointnames, w[1]);
	l[n+1] = nameindex(m.pointnames, w[2]);
	c.links = l;
	return nil;
}

# "body NAME EXPR": a mass, which is an expression because in this
# family a slider usually IS a mass.
body(m: ref Model, c: ref Config, w: array of string, nwords: int): string
{
	if(nwords < 3)
		return "body: usage: body NAME EXPR...";
	(e, err) := m.hocmod->compileeqn(joinfrom(w, 2));
	if(err != nil)
		return "body "+w[1]+": "+err;
	n := len c.bodies;
	names := array[n+1] of string;
	for(i := 0; i < n; i++)
		names[i] = c.bodies[i];
	names[n] = w[1];
	c.bodies = names;
	exprs := array[n+1] of ref Expr;
	for(i = 0; i < n; i++)
		exprs[i] = c.massexprs[i];
	exprs[n] = e;
	c.massexprs = exprs;
	return nil;
}

# "WORD XEXPR , YEXPR": the two families that name a point in the plane
# write it with a comma, because either half may be an expression with
# spaces in it.
pair(m: ref Model, w: array of string, nwords: int, usage: string):
		(ref Expr, ref Expr, string)
{
	comma := -1;
	for(c := 1; c < nwords; c++)
		if(w[c] == ","){
			comma = c;
			break;
		}
	if(nwords < 4 || comma < 2 || comma == nwords-1)
		return (nil, nil, usage);
	(x, e1) := m.hocmod->compileeqn(joinfrom(w[0:comma], 1));
	if(e1 != nil)
		return (nil, nil, w[0]+" x: "+e1);
	(y, e2) := m.hocmod->compileeqn(joinfrom(w, comma+1));
	if(e2 != nil)
		return (nil, nil, w[0]+" y: "+e2);
	return (x, y, nil);
}

# What each family needs that dynsys->check() cannot know.
checkspec(m: ref Model, c: ref Config): string
{
	case c.family {
	Mechanism =>
		if((e := wantobservables(m, 2)) != nil)
			return e;
		if(len m.pointnames == 0)
			return "spec has no point commands";
	Population =>
		return zerominima(m);
	Trajectory =>
		# a launch angle is signed - a pitch is thrown downward - so a
		# negative minimum is meaningful here, the same reason it is
		# meaningful in Flight
		if(len m.statenames != 4)
			return sys->sprint("a flight has four states - position, "+
				"height, and the two velocities - and this spec has %d",
				len m.statenames);
		if(m.maxtime <= 0.0)
			return "spec has no maxtime command";
	Orbit =>
		if(len c.bodies == 0)
			return "spec has no body commands";
		if(len m.statenames != 4*len c.bodies)
			return sys->sprint("%d bodies need %d states - x, y and the "+
				"two velocities each - and this spec has %d",
				len c.bodies, 4*len c.bodies, len m.statenames);
		return wantobservables(m, 2);
	Ecology =>
		if(c.equilx == nil)
			return "spec has no equilibrium command, which is what this family shows";
		if(len m.statenames != 2)
			return sys->sprint("two species means two states, and this spec has %d",
				len m.statenames);
		return zerominima(m);
	Flight =>
		# unlike the flat families, an aim or a crosswind is signed, so
		# a negative minimum is meaningful here and is not rejected
		if(len m.statenames != 6)
			return sys->sprint("a three-dimensional flight has six states - "+
				"downrange, lateral and height, then their three velocities - "+
				"and this spec has %d", len m.statenames);
		if(m.maxtime <= 0.0)
			return "spec has no maxtime command";
	Profile =>
		if(c.radius == nil)
			return "spec has no radius command, and a profile has to start somewhere";
		return wantobservables(m, 2);
	}
	return nil;
}

wantobservables(m: ref Model, n: int): string
{
	if(len m.observablelabels != n)
		return sys->sprint("spec has %d observable commands, needs exactly %d",
			len m.observablelabels, n);
	return nil;
}

zerominima(m: ref Model): string
{
	for(i := 0; i < len m.parameter; i++)
		if(m.minima[i] != 0.0)
			return sys->sprint("param %s: this family's sliders run from zero, "+
				"so its minimum must be 0.0", m.paramlabels[i]);
	return nil;
}

masses(m: ref Model, c: ref Config): array of real
{
	r := array[len c.massexprs] of real;
	for(i := 0; i < len r; i++)
		r[i] = m.hocmod->eval(c.massexprs[i]);
	return r;
}

equilibrium(m: ref Model, c: ref Config): (real, real)
{
	return (m.hocmod->eval(c.equilx), m.hocmod->eval(c.equily));
}

# The march: explicit Euler outward in radius, recording the observables
# before each step, then dividing one column by its outermost value.
# This is the whole of the Profile family - there is no window in it,
# and danbylabtest(1) calls it directly.
march(m: ref Model, c: ref Config): array of real
{
	state := dynsys->initialstate(m);	# also binds the parameters
	r := m.hocmod->eval(c.radius);
	dr := m.hocmod->eval(c.span)/real(c.samples-1);
	deriv := array[len state] of real;
	out := array[3*c.samples] of real;
	for(i := 0; i < c.samples; i++){
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
	if(c.normalised >= 0){
		outer := out[3*(c.samples-1)+1+c.normalised];
		if(outer > 0.0)
			for(i = 0; i < c.samples; i++)
				out[3*i+1+c.normalised] /= outer;
	}
	return out;
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

joinwith(a: array of string, sep: string): string
{
	s := "";
	for(i := 0; i < len a; i++){
		if(i > 0)
			s += sep;
		s += a[i];
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

# A label is one word in the script, because a parameter label is also
# the symbol its expressions use; an underscore displays as a space, so
# "support_mass" reads as "support mass" without being two tokens.
label(name: string): string
{
	s := name;
	for(i := 0; i < len s; i++)
		if(s[i] == '_')
			s[i] = ' ';
	return s;
}


# ---------------------------------------------------------------- the window

pane(w, req, pack: string): ref Pane
{
	return ref Pane(w, req, pack, nil);
}

# The furniture, per family.  Everything a reader might go looking for
# in seven different files is in this one function.
lookof(family: int): ref Look
{
	l := ref Look;
	l.theme = Paper;
	l.pause = 1;
	l.atwidth = 460;
	l.percol = 3;
	l.sliderlen = 150;
	l.steps = 200;
	l.dt = 0.005;
	l.perframe = 4;
	l.graphpane = 0;
	l.diagpane = -1;
	left := "-side left -fill both -expand 1";
	right := "-side right -fill both -expand 1";
	whole := "-fill both -expand 1";
	case family {
	Mechanism =>
		l.panes = array[] of {
			pane(".plot.mech", "-width 460 -height 400", left),
			pane(".plot.g", "-width 380 -height 400", right)
		};
		(l.diagpane, l.graphpane) = (0, 1);
		l.focus = ".plot.mech";
	Population =>
		# the bars are packed first, so the plot gets what is left
		l.panes = array[] of {
			pane(".plot.bars", "-width 180 -height 380", "-side right -fill y"),
			pane(".plot.p", "-width 600 -height 380", left)
		};
		(l.diagpane, l.graphpane) = (0, 1);
		l.focus = ".plot.p";
		l.atwidth = 240;
		l.dt = 0.008;
		(l.click, l.clickcmd) = (".plot.bars", "bar");
	Trajectory =>
		l.panes = array[] of {pane(".plot.p", "-width 700 -height 380", whole)};
		l.focus = ".plot.p";
		l.perframe = 5;
	Orbit =>
		l.panes = array[] of {
			pane(".plot.orb", "-width 520 -height 420", left),
			pane(".plot.g", "-width 360 -height 420", right)
		};
		(l.diagpane, l.graphpane) = (0, 1);
		l.focus = ".plot.orb";
		l.theme = Sky;
		l.dt = 0.0025;
	Ecology =>
		l.panes = array[] of {pane(".plot.p", "-width 640 -height 380", whole)};
		l.focus = ".plot.p";
		l.percol = 2;
		l.sliderlen = 170;
		l.dt = 0.008;
		(l.click, l.clickcmd) = (".plot.p", "plot");
	Flight =>
		l.panes = array[] of {pane(".plot.p", "-width 700 -height 440", whole)};
		l.focus = ".plot.p";
		l.atwidth = 520;
		l.perframe = 5;
	Profile =>
		l.panes = array[] of {pane(".plot.p", "-width 700 -height 420", whole)};
		l.focus = ".plot.p";
		l.atwidth = 300;
		l.pause = 0;		# a profile does not move
		l.perframe = 0;
		l.steps = 400;		# so it can afford a finer slider
	}
	return l;
}

cmd(s: string): string
{
	r := tk->cmd(top, s);
	if(r != nil && r[0] == '!')
		sys->fprint(sys->fildes(2), "danbylab: %s: %s\n", s, r);
	return r;
}

run(ctxt: ref Draw->Context, name, spec: string): string
{
	err: string;
	(model, cfg, err) = parse(spec);
	if(err != nil)
		return err;
	if((err = loadui()) != nil)
		return err;
	look = lookof(cfg.family);
	manpage(name);
	sys->pctl(Sys->NEWPGRP, nil);
	menu := initwindow(ctxt);
	initgraph();
	sim = ref Sim;
	sim.reset();
	resize();

	# a still picture wants no clock, but an alt on a nil channel is a
	# nil dereference (libinterp/alt.c), so it gets a real channel that
	# nothing ever writes to
	ticks := chan of int;
	if(look.perframe > 0)
		spawn timer(ticks);
	redraw();
	return eventloop(menu, ticks);
}

# The window manager's Help menu opens a man page; a model that does not
# name one is assumed to have a page of its own name.
manpage(name: string)
{
	env = load Env Env->PATH;
	if(env == nil)
		return;
	env->clone();
	page := cfg.manual;
	if(page == "")
		page = "danby-"+name;
	env->setenv("wmman", page);
}

# The whole of the window: two frames of controls under however many
# panes the family draws in.  Nothing here knows a pixel offset - Tk
# works out where everything goes, and tk->rect() says afterwards where
# each pane ended up.
initwindow(ctxt: ref Draw->Context): chan of string
{
	tkclient->init();
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	menu: chan of string;
	(top, menu) = tkclient->toplevel(ctxt, "", cfg.title, Tkclient->Appl);
	cmdch = chan[64] of string;	# tk drops what it cannot queue, so leave room
	tk->namechan(top, cmdch, "cmd");

	# the six paper families take Tk's own colours; the orbits do not,
	# because a bright frame around a night sky reads as a mistake
	paint := "";
	inkpaint := "";
	if(look.theme == Sky){
		paint = " -background "+tkcolour(themebg[Sky]);
		inkpaint = paint+" -foreground "+tkcolour(themefg[Sky]);
		cmd(". configure"+paint);
	}
	cmd("frame .plot"+paint);
	for(i := 0; i < len look.panes; i++){
		p := look.panes[i];
		cmd("panel "+p.w+" -bd 0 -relief flat "+p.req);
		cmd("pack "+p.w+" "+p.pack);
	}
	cmd("frame .par"+paint);
	cmd("frame .but"+paint);
	cmd("button .but.reset -text Reset -command {send cmd reset}");
	buttons := ".but.reset";
	if(look.pause){
		cmd("button .but.pause -text Pause -command {send cmd pause}");
		buttons += " .but.pause";
	}
	# A label's requested size follows its text, and a frame that gets a
	# new requested size asks the window manager to reshape the window.
	# This text changes forty times a second, so without a fixed width
	# the window renegotiates its own geometry forty times a second too:
	# a measured 36 reshape requests per 200 frames, against 1 with the
	# width nailed down.
	cmd(sys->sprint("label .but.at -text {} -anchor w -width %d%s",
		look.atwidth, inkpaint));
	cmd("pack "+buttons+" -side left");
	cmd("pack .but.at -side left -padx 10");
	cmd("pack .but -side bottom -fill x");
	cmd("pack .par -side bottom -fill x");
	cmd("pack .plot -side top -fill both -expand 1");
	buildparams(inkpaint);	# a parameter label is text, and needs the ink too
	if(look.click != nil)
		cmd("bind "+look.click+" <Button-1> {send cmd "+look.clickcmd+" %x %y}");
	cmd("bind . <Key> {send cmd key %K}");
	cmd("bind "+look.focus+" <Key> {send cmd key %K}");
	cmd("focus "+look.focus);
	cmd("update");
	# a widget created after the window is on screen never receives a
	# pointer event, so every widget above exists before this line
	tkclient->startinput(top, "kbd"::"ptr"::nil);
	tkclient->onscreen(top, nil);

	font = Font.open(top.display, "/fonts/lucida/unicode.8.font");
	bg = top.display.color(themebg[look.theme]);
	fg = top.display.color(themefg[look.theme]);
	gridcolour = top.display.color(themegrid[look.theme]);
	palette = array[len palettevalue] of ref Image;
	for(i = 0; i < len palette; i++)
		palette[i] = top.display.color(palettevalue[i]);
	bodycolour = array[len bodyvalue] of ref Image;
	for(i = 0; i < len bodycolour; i++)
		bodycolour[i] = top.display.color(bodyvalue[i]);
	return menu;
}

# One label and one scale per parameter, laid out in a grid by Tk.  A
# scale's own -command reports the new value, so nothing here has to
# work out which slider the pointer was over, or how many fit in a row.
buildparams(paint: string)
{
	for(j := 0; j < len model.parameter; j++){
		(lo, hi) := (model.minima[j], model.maxima[j]);
		if(lo >= hi)
			lo = hi*0.01;
		cmd(sys->sprint("label .par.l%d -text {%s}%s",
			j, label(model.paramlabels[j]), paint));
		# -bigincrement defaults to zero, and a scale with a zero big
		# increment answers a click in its trough by re-sending the
		# value it already had: the slider looks live and does nothing
		cmd(sys->sprint("scale .par.s%d -from %g -to %g -resolution %g"+
			" -bigincrement %g -orient horizontal -length %d"+
			" -showvalue 1 -command {send cmd param %d}",
			j, lo, hi, (hi-lo)/real look.steps, (hi-lo)/20.0,
			look.sliderlen, j));
		cmd(sys->sprint(".par.s%d set %g", j, model.parameter[j]));
		row := j/look.percol;
		col := (j%look.percol)*2;
		cmd(sys->sprint("grid .par.l%d -row %d -column %d -sticky w -padx 4",
			j, row, col));
		cmd(sys->sprint("grid .par.s%d -row %d -column %d -sticky w",
			j, row, col+1));
	}
}

# The static half of the plot(2) program: the tables the simulation
# appends to, and the colours the lines are drawn in.
initgraph()
{
	graph = plot->new(nil, font);
	colours := "colour foreground "+plotcolour(themefg[look.theme])+
		"\ncolour grid "+plotcolour(themegrid[look.theme]);
	case cfg.family {
	Mechanism =>
		graph.cmd("table history time first second -capacity 20000");
		colours += "\ncolour first 16r178f86ff\ncolour second 16r7b5aa6ff";
	Population =>
		table := "table history time";
		for(i := 0; i < len model.statenames; i++)
			table += " state" + string i;
		graph.cmd(table + " -capacity 16000");
		for(i = 0; i < len palettevalue; i++)
			colours += sys->sprint("\ncolour state%d %s", i, plotcolour(palettevalue[i]));
	Trajectory =>
		graph.cmd("table history time x y speed -capacity 20000");
		colours += "\ncolour path 16rb85c38ff\ncolour speed 16r178f86ff";
	Orbit =>
		graph.cmd("table history time first second -capacity 20000");
		colours += "\ncolour first 16r4ec9b0ff\ncolour second 16rf2b84bff";
	Ecology =>
		graph.cmd("table history time first second -capacity 12000");
		graph.cmd("table equilibrium first second -capacity 1");
		graph.cmd("table current first second -capacity 1");
		colours += "\ncolour live 16r178f86ff\ncolour accent 16rb85c38ff";
	Flight =>
		graph.cmd("table history time x lateral height speed -capacity 20000");
		colours += "\ncolour side 16rb85c38ff\ncolour plan 16r178f86ff";
	Profile =>
		graph.cmd("table profile radius first second -capacity 4096");
		colours += "\ncolour first 16r178f86ff\ncolour second 16rb85c38ff";
		cmd(".but.at configure -text {"+label(model.observablelabels[0])+" / "+
			label(model.observablelabels[1])+"}");
	}
	graph.cmd(colours);
}

# Tk says where each pane went; this library only has to keep images of
# those sizes.  Does nothing at all unless a size actually changed.
resize()
{
	if(top == nil || top.image == nil)
		return;
	for(i := 0; i < len look.panes; i++){
		p := look.panes[i];
		r := tk->rect(top, p.w, 0);
		(w, h) := (r.dx(), r.dy());
		if(w <= 0 || h <= 0)
			continue;
		if(p.im != nil && p.im.r.dx() == w && p.im.r.dy() == h)
			continue;
		new := top.display.newimage(Rect((0,0),(w,h)), top.image.chans,
			0, Draw->White);
		if(new == nil)
			continue;
		p.im = new;
		tk->putimage(top, p.w, new, nil);
	}
	graph.image = look.panes[look.graphpane].im;
}


# ------------------------------------------------------------ the simulation

rhs(rhsTime: real, values, derivative: array of real)
{
	dynsys->rhs(model, rhsTime, values, derivative);
}

# Back to time zero with an empty history.  Every path that clears the
# history comes through here, so none of them can forget to record the
# first sample.
Sim.reset(s: self ref Sim)
{
	# the initial values are the state lines' own expressions, so they
	# follow a parameter a slider has just changed
	s.state = dynsys->initialstate(model);
	s.work = numerics->workspace(len s.state);
	s.t = 0.0;
	s.paused = 0;
	s.finished = 0;
	s.grounded = 0;
	s.obsmax = array[] of {1.0, 1.0};
	s.dispmax = 1.0;
	(s.xmax, s.ymax, s.latmax) = (10.0, 5.0, 1.0);
	s.vmax = 10.0;

	case cfg.family {
	Orbit =>
		# the parameters are bound by initialstate() above, which a
		# mass expression needs
		s.mass = masses(model, cfg);
		s.trail = array[Ntrail] of array of real;
		s.trailcount = 0;
		s.trailnext = 0;
	Profile =>
		# where the Reset button puts the sliders back to
		if(s.home == nil){
			s.home = array[len model.parameter] of real;
			s.home[0:] = model.parameter;
		}
		recompute(s);
		return;
	}
	graph.cmd("history clear");
	s.grow();	# the first sample sets the axes, like every one after it
	s.record();
	if(top != nil && look.pause)
		cmd(".but.pause configure -text Pause");
}

# One integration step, and whatever the family says ends a run.
Sim.step(s: self ref Sim)
{
	old := array[len s.state] of real;
	old[0:] = s.state;
	oldt := s.t;
	numerics->rk4(s.work, rhs, s.t, look.dt, s.state);
	s.t += look.dt;

	case cfg.family {
	Population or Ecology =>
		# neither a population nor a species can go negative, which is
		# these families' own rule
		for(i := 0; i < len s.state; i++)
			if(s.state[i] < 0.0)
				s.state[i] = 0.0;
	Trajectory =>
		s.land(old, oldt, 1);
	Flight =>
		s.land(old, oldt, 2);
	}

	if(model.maxtime > 0.0 && s.t >= model.maxtime && endsontime(cfg.family)){
		s.finished = 1;
		s.paused = 1;
	}
	s.grow();
	s.record();
}

# Population and Ecology run until the window closes; the rest stop at
# the spec's own maxtime.
endsontime(family: int): int
{
	return family != Population && family != Ecology;
}

# The flight ends where the height crosses zero, interpolated to the
# crossing rather than to the end of the step.  h is the height's index.
Sim.land(s: self ref Sim, old: array of real, oldt: real, h: int)
{
	if(s.state[h] >= 0.0 || old[h] < 0.0 || oldt <= 0.0)
		return;
	fraction := old[h]/(old[h]-s.state[h]);
	for(i := 0; i < len s.state; i++)
		s.state[i] = old[i]+fraction*(s.state[i]-old[i]);
	s.state[h] = 0.0;
	s.t = oldt+fraction*look.dt;
	s.finished = 1;
	s.grounded = 1;
	s.paused = 1;
}

# The axes grow to hold what has been drawn, and never shrink, so the
# picture does not jitter as the trajectory turns back on itself.
Sim.grow(s: self ref Sim)
{
	case cfg.family {
	Mechanism or Orbit =>
		values := dynsys->observables(model, s.state);
		for(i := 0; i < 2; i++)
			if(absreal(values[i])*1.15 > s.obsmax[i])
				s.obsmax[i] = absreal(values[i])*1.15;
	Population =>
		for(i := 0; i < len s.state; i++)
			if(s.state[i]*1.15 > s.dispmax)
				s.dispmax = s.state[i]*1.15;
	Trajectory =>
		s.xmax = maxreal(s.xmax, s.state[0]*1.1);
		s.ymax = maxreal(s.ymax, s.state[1]*1.15);
		s.vmax = maxreal(s.vmax, s.speed()*1.1);
	Flight =>
		s.xmax = maxreal(s.xmax, s.state[0]*1.1);
		s.ymax = maxreal(s.ymax, s.state[2]*1.15);
		s.latmax = maxreal(s.latmax, absreal(s.state[1])*1.25);
	}
}

Sim.record(s: self ref Sim)
{
	case cfg.family {
	Mechanism or Orbit =>
		values := dynsys->observables(model, s.state);
		if(cfg.family == Orbit)
			s.pushtrail();
		graph.cmd(sys->sprint("history append %.17g %.17g %.17g",
			s.t, values[0], values[1]));
	Population =>
		command := sys->sprint("history append %.17g", s.t);
		for(i := 0; i < len s.state; i++)
			command += sys->sprint(" %.17g", s.state[i]);
		graph.cmd(command);
	Trajectory =>
		graph.cmd(sys->sprint("history append %.17g %.17g %.17g %.17g",
			s.t, s.state[0], s.state[1], s.speed()));
	Ecology =>
		graph.cmd(sys->sprint("history append %.17g %.17g %.17g",
			s.t, s.state[0], s.state[1]));
	Flight =>
		graph.cmd(sys->sprint("history append %.17g %.17g %.17g %.17g %.17g",
			s.t, s.state[0], s.state[1], s.state[2], s.speed()));
	}
}

# Orbit keeps every body's position, in a ring, so the trail can be
# redrawn at whatever scale the view has grown to.
Sim.pushtrail(s: self ref Sim)
{
	positions := array[2*len s.mass] of real;
	for(i := 0; i < len s.mass; i++){
		positions[2*i] = s.state[4*i];
		positions[2*i+1] = s.state[4*i+1];
	}
	s.trail[s.trailnext] = positions;
	s.trailnext = (s.trailnext+1)%Ntrail;
	if(s.trailcount < Ntrail)
		s.trailcount++;
}

# The k'th oldest sample still in the ring.
Sim.trailat(s: self ref Sim, k: int): array of real
{
	index := s.trailnext-s.trailcount+k;
	if(index < 0)
		index += Ntrail;
	return s.trail[index];
}

# The velocity components are the second half of the state vector.
Sim.speed(s: self ref Sim): real
{
	half := len s.state/2;
	sum := 0.0;
	for(i := half; i < len s.state; i++)
		sum += s.state[i]*s.state[i];
	return math->sqrt(sum);
}

recompute(s: ref Sim)
{
	s.data = march(model, cfg);
	graph.cmd("profile clear");
	for(i := 0; i < cfg.samples; i++)
		graph.cmd(sys->sprint("profile append %.17g %.17g %.17g",
			s.data[3*i], s.data[3*i+1], s.data[3*i+2]));
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

minreal(a, b: real): real
{
	if(b < a)
		return b;
	return a;
}


# --------------------------------------------------------------- the picture

redraw()
{
	for(i := 0; i < len look.panes; i++)
		if(look.panes[i].im == nil)
			return;
	buffer := look.panes[look.graphpane].im;
	buffer.draw(buffer.r, bg, nil, Point(0,0));
	drawdiagram();
	graph.cmd("clear");
	drawgraph();
	graph.draw();
	dirty := "";
	for(i = 0; i < len look.panes; i++)
		dirty += look.panes[i].w + " dirty; ";
	cmd(dirty + "update");
	# the status line is a widget, so only touch it when it would change
	now := status();
	if(now != readout && now != nil){
		readout = now;
		cmd(".but.at configure -text {"+now+"}");
	}
}

# The per-frame half of the plot(2) program: the views, the scales that
# have grown since the last frame, and the lines.
drawgraph()
{
	s := sim;
	tmax := s.t;
	case cfg.family {
	Mechanism or Orbit =>
		name := "quantities";
		if(cfg.family == Orbit)
			name = "diagnostics";
		if(tmax < 2.0)
			tmax = 2.0;
		ymax := maxreal(s.obsmax[0], s.obsmax[1]);
		graph.cmd("content margin 45 22 18 30\nview "+name+" content");
		graph.cmd(sys->sprint("scale %s x 0 %.8g", name, tmax));
		graph.cmd(sys->sprint("scale %s y %.8g %.8g reverse", name, -ymax, ymax));
		graph.cmd("axis "+name+" x time");
		graph.cmd("axis "+name+" y value");
		graph.cmd("line "+name+" history x time y first colour first width 2");
		graph.cmd("line "+name+" history x time y second colour second width 2");
	Population =>
		if(tmax < 10.0)
			tmax = 10.0;
		graph.cmd("content margin 48 22 18 30\nview historyplot content");
		graph.cmd(sys->sprint("scale historyplot x 0 %.8g", tmax));
		graph.cmd(sys->sprint("scale historyplot y 0 %.8g reverse", s.dispmax));
		graph.cmd("axis historyplot x time");
		graph.cmd("axis historyplot y quantity");
		for(i := 0; i < len s.state; i++)
			graph.cmd(sys->sprint("line historyplot history x time "+
				"y state%d colour state%d width 2", i, i%len palette));
	Trajectory =>
		if(tmax < 2.0)
			tmax = 2.0;
		graph.cmd("content margin 48 22 18 30\n"+
			"split content x flight 2 telemetry 1 gutter 55\n"+
			"view flight flight");
		graph.cmd(sys->sprint("scale flight x 0 %.8g", s.xmax));
		graph.cmd(sys->sprint("scale flight y 0 %.8g reverse", s.ymax));
		graph.cmd("axis flight x distance");
		graph.cmd("axis flight y height");
		graph.cmd("line flight history x x y y colour path width 2");
		graph.cmd("view telemetry telemetry");
		graph.cmd(sys->sprint("scale telemetry x 0 %.8g", tmax));
		graph.cmd(sys->sprint("scale telemetry y 0 %.8g reverse", s.vmax));
		graph.cmd("axis telemetry x time");
		graph.cmd("axis telemetry y speed");
		graph.cmd("line telemetry history x time y speed colour speed width 2");
	Ecology =>
		maximum := phasetop();
		graph.cmd("content margin 45 22 18 30\n"+
			"split content x phase 1 time 1 gutter 54\n"+
			"view phase phase");
		graph.cmd(sys->sprint("scale phase x 0 %.8g", maximum));
		graph.cmd(sys->sprint("scale phase y 0 %.8g reverse", maximum));
		graph.cmd("axis phase x "+model.statenames[0]);
		graph.cmd("axis phase y "+model.statenames[1]);
		graph.cmd("equilibrium clear");
		deriv := array[len s.state] of real;
		dynsys->rhs(model, s.t, s.state, deriv);	# binds the parameters
		(ex, ey) := equilibrium(model, cfg);
		graph.cmd(sys->sprint("equilibrium append %.17g %.17g", ex, ey));
		graph.cmd("current clear");
		graph.cmd(sys->sprint("current append %.17g %.17g", s.state[0], s.state[1]));
		graph.cmd("line phase history x first y second colour foreground width 2");
		graph.cmd("point phase equilibrium x first y second colour accent radius 5");
		graph.cmd("point phase current x first y second colour live radius 4");
		if(tmax < 10.0)
			tmax = 10.0;
		graph.cmd("view time time");
		graph.cmd(sys->sprint("scale time x 0 %.8g", tmax));
		graph.cmd(sys->sprint("scale time y 0 %.8g reverse", maximum));
		graph.cmd("axis time x time");
		graph.cmd("axis time y population");
		graph.cmd("line time history x time y first colour live width 2");
		graph.cmd("line time history x time y second colour accent width 2");
	Flight =>
		graph.cmd("content margin 48 22 18 30\n"+
			"split content y side 1 plan 1 gutter 44\n"+
			"view side side");
		graph.cmd(sys->sprint("scale side x 0 %.8g", s.xmax));
		graph.cmd(sys->sprint("scale side y 0 %.8g reverse", s.ymax));
		graph.cmd("axis side x downrange");
		graph.cmd("axis side y height");
		graph.cmd("line side history x x y height colour side width 2");
		graph.cmd("view plan plan");
		graph.cmd(sys->sprint("scale plan x 0 %.8g", s.xmax));
		graph.cmd(sys->sprint("scale plan y %.8g %.8g reverse", -s.latmax, s.latmax));
		graph.cmd("axis plan x downrange");
		graph.cmd("axis plan y lateral");
		graph.cmd("line plan history x x y lateral colour plan width 2");
	Profile =>
		ymax := 1.0;
		for(i := 0; i < cfg.samples; i++){
			ymax = maxreal(ymax, s.data[3*i+1]);
			ymax = maxreal(ymax, s.data[3*i+2]);
		}
		graph.cmd("content margin 55 24 20 32\nview radial content");
		graph.cmd(sys->sprint("scale radial x 0 %.8g", s.data[3*(cfg.samples-1)]));
		graph.cmd(sys->sprint("scale radial y 0 %.8g reverse", ymax));
		graph.cmd("axis radial x radius");
		graph.cmd("axis radial y value");
		graph.cmd("line radial profile x radius y first colour first width 2");
		graph.cmd("line radial profile x radius y second colour second width 2");
	}
}

# Both phase axes share one maximum, so the portrait stays square in
# units and a circling trajectory looks like one.
phasetop(): real
{
	if(cfg.fixedscale > 0.0)
		return cfg.fixedscale;
	maximum := 1.5;
	maximum = maxreal(maximum, sim.state[0]*1.15);
	maximum = maxreal(maximum, sim.state[1]*1.15);
	return maximum;
}

# The three families that draw something besides a graph draw it in a
# pane of its own, so its view is that pane's whole image and there is
# no view rect to compute.
drawdiagram()
{
	if(look.diagpane < 0)
		return;
	im := look.panes[look.diagpane].im;
	case cfg.family {
	Mechanism =>
		drawmechanism(im);
	Population =>
		drawstatebars(im);
	Orbit =>
		draworbits(im);
	}
}

drawmechanism(im: ref Image)
{
	im.draw(im.r, bg, nil, Point(0,0));
	points := dynsys->points(model, sim.state);
	if(len points == 0)
		return;
	view := im.r.inset(8);
	(xmin, xmax) := (points[0], points[0]);
	(ymin, ymax) := (points[1], points[1]);
	for(i := 0; i < len points/2; i++){
		xmin = minreal(xmin, points[2*i]);
		xmax = maxreal(xmax, points[2*i]);
		ymin = minreal(ymin, points[2*i+1]);
		ymax = maxreal(ymax, points[2*i+1]);
	}
	# a mechanism that has not moved yet is a single point, and a view
	# one point across has no scale
	if(xmax-xmin < 1.0)
		(xmin, xmax) = (xmin-0.5, xmax+0.5);
	if(ymax-ymin < 1.0)
		(ymin, ymax) = (ymin-0.5, ymax+0.5);
	xpad := (xmax-xmin)*0.15;
	ypad := (ymax-ymin)*0.15;
	(xmin, xmax) = (xmin-xpad, xmax+xpad);
	(ymin, ymax) = (ymin-ypad, ymax+ypad);
	for(i = 0; i < len cfg.links/2; i++){
		(a, b) := (cfg.links[2*i], cfg.links[2*i+1]);
		if(2*a+1 >= len points || 2*b+1 >= len points)
			continue;
		pa := onview(view, points[2*a], points[2*a+1], xmin, xmax, ymin, ymax);
		pb := onview(view, points[2*b], points[2*b+1], xmin, xmax, ymin, ymax);
		im.line(pa, pb, Draw->Endsquare, Draw->Endsquare, 3,
			palette[1], Point(0,0));
	}
	for(i = 0; i < len points/2; i++)
		im.ellipse(onview(view, points[2*i], points[2*i+1],
			xmin, xmax, ymin, ymax), 4, 4, 0, fg, Point(0,0));
}

onview(view: Rect, x, y, xmin, xmax, ymin, ymax: real): Point
{
	px := view.min.x+int((x-xmin)/(xmax-xmin)*real(view.dx()));
	py := view.max.y-int((y-ymin)/(ymax-ymin)*real(view.dy()));
	return (px,py);
}

# The bars are their own pane, so a bar's height is the pane's height
# divided by the number of states and nothing else.
drawstatebars(im: ref Image)
{
	im.draw(im.r, bg, nil, Point(0,0));
	r := im.r.inset(6);
	height := r.dy()/len sim.state;
	for(i := 0; i < len sim.state; i++){
		y := r.min.y+i*height;
		im.text((r.min.x,y+font.height), fg, Point(0,0), font,
			sys->sprint("%s %.4g", label(model.statenames[i]), sim.state[i]));
		track := Rect((r.min.x,y+font.height+4), (r.max.x,y+height-5));
		im.draw(track, gridcolour, nil, Point(0,0));
		filled := track;
		filled.max.x = filled.min.x+
			int(real(track.dx())*sim.state[i]/sim.dispmax);
		im.draw(filled, palette[i%len palette], nil, Point(0,0));
	}
}

# The most massive body - the "planet" - is pinned at the centre of the
# view and the SCALE does all the work as the orbit grows or shrinks.
# An independent x/y bounding box mapped onto the view rect was the bug:
# that box's own centre drifts as the trail's extent changes even though
# the planet has not moved, so the planet visibly wandered around the
# screen instead of staying put while the view zoomed.  A single uniform
# scale, not separate x and y ranges, also keeps a circular orbit
# looking circular rather than stretched to fill the wider axis.
draworbits(im: ref Image)
{
	s := sim;
	im.draw(im.r, bg, nil, Point(0,0));
	view := im.r.inset(8);
	focus := 0;
	for(i := 1; i < len s.mass; i++)
		if(s.mass[i] > s.mass[focus])
			focus = i;

	# extent: the largest distance any trail point sits from the FOCUS
	# body's own position at that same instant - not from its current
	# position, so a system whose "planet" is not perfectly fixed still
	# reads correctly.
	extent := 0.1;
	for(k := 0; k < s.trailcount; k++){
		positions := s.trailat(k);
		(fx, fy) := (positions[2*focus], positions[2*focus+1]);
		for(i = 0; i < len s.mass; i++){
			extent = maxreal(extent, absreal(positions[2*i]-fx));
			extent = maxreal(extent, absreal(positions[2*i+1]-fy));
		}
	}
	extent *= 1.24;

	half := view.dx();
	if(view.dy() < half)
		half = view.dy();
	scale := real(half)/(2.0*extent);
	centre := Point((view.min.x+view.max.x)/2, (view.min.y+view.max.y)/2);

	for(i = 0; i < len s.mass; i++){
		colour := bodycolour[i%len bodycolour];
		haveprevious := 0;
		previous := Point(0,0);
		for(k = 0; k < s.trailcount; k++){
			positions := s.trailat(k);
			point := oncentre(centre, scale, positions[2*i], positions[2*i+1],
				positions[2*focus], positions[2*focus+1]);
			if(haveprevious)
				im.line(previous, point, 0, 0, 1, colour, Point(0,0));
			previous = point;
			haveprevious = 1;
		}
		point := oncentre(centre, scale, s.state[4*i], s.state[4*i+1],
			s.state[4*focus], s.state[4*focus+1]);
		radius := 4;
		if(s.mass[i] > 0.1)
			radius = 7;
		im.ellipse(point, radius, radius, 0, colour, Point(0,0));
		im.text(point.add((radius+3,-3)), fg, Point(0,0), font,
			label(cfg.bodies[i]));
	}
}

# (x,y) relative to the focus body's own position (cx,cy) at the SAME
# instant, scaled uniformly and offset from view centre - so (cx,cy)
# itself always lands exactly on centre, every frame, regardless of
# scale: the focus body never moves on screen, only the scale changes.
oncentre(centre: Point, scale: real, x, y, cx, cy: real): Point
{
	return centre.add((int((x-cx)*scale), -int((y-cy)*scale)));
}

# The status line.  nil leaves whatever is there alone, which is what a
# still picture wants.
status(): string
{
	s := sim;
	case cfg.family {
	Mechanism =>
		values := dynsys->observables(model, s.state);
		return sys->sprint("%s   t %.3g   %s %.3g   %s %.3g",
			runstate(), s.t, label(model.observablelabels[0]), values[0],
			label(model.observablelabels[1]), values[1]);
	Orbit =>
		values := dynsys->observables(model, s.state);
		return sys->sprint("%s   t %.3g   %s %.4g   %s %.4g",
			runstate(), s.t, label(model.observablelabels[0]), values[0],
			label(model.observablelabels[1]), values[1]);
	Population =>
		return sys->sprint("t %.2f", s.t);
	Trajectory =>
		return sys->sprint("%s   t %.3g   range %.3g   speed %.3g",
			flightstate(), s.t, s.state[0], s.speed());
	Ecology =>
		(ex, ey) := equilibrium(model, cfg);
		return sys->sprint("t %.1f   %s %.3g   %s %.3g   equilibrium %.3g, %.3g",
			s.t, label(model.statenames[0]), s.state[0],
			label(model.statenames[1]), s.state[1], ex, ey);
	Flight =>
		return sys->sprint("%s   t %.3g   downrange %.3g   lateral %.3g   speed %.3g",
			flightstate(), s.t, s.state[0], s.state[1], s.speed());
	}
	return nil;
}

runstate(): string
{
	if(sim.finished)
		return "complete";
	if(sim.paused)
		return "paused";
	return "running";
}

flightstate(): string
{
	if(sim.grounded)
		return "landed";
	if(sim.finished)
		return "complete";
	return "in flight";
}


# ------------------------------------------------------------------ the loop

eventloop(menu: chan of string, ticks: chan of int): string
{
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
		if(!sim.paused && !sim.finished)
			for(k := 0; k < look.perframe && !sim.finished; k++)
				sim.step();
		redraw();
	}
}

# A Tk message.  Returns non-zero if the window is finished.
control(s: string): int
{
	(nil, w) := sys->tokenize(s, " \t");
	if(w == nil)
		return 0;
	case hd w {
	"reset" =>
		if(cfg.family == Profile){
			for(j := 0; j < len model.parameter; j++){
				model.parameter[j] = sim.home[j];
				cmd(sys->sprint(".par.s%d set %g", j, sim.home[j]));
			}
			recompute(sim);
		} else
			sim.reset();
	"pause" =>
		if(!look.pause || sim.finished)
			return 0;
		sim.paused = !sim.paused;
		lbl := "Pause";
		if(sim.paused)
			lbl = "Go";
		cmd(sys->sprint(".but.pause configure -text %s", lbl));
	"param" =>
		# read every scale rather than trust one message: tk drops
		# queued messages silently, and a dropped last drag event
		# would otherwise leave a parameter behind the slider
		for(j := 0; j < len model.parameter; j++)
			model.parameter[j] = real cmd(sys->sprint(".par.s%d get", j));
		# a state line, a mass and a profile are all expressions in the
		# parameters, so a new parameter is a new problem rather than a
		# nudge to this one.  Ecology is the exception: there the point
		# of a slider is to bend the trajectory that is already running.
		if(cfg.family != Ecology)
			sim.reset();
	"plot" =>
		# Ecology: a click in the phase portrait starts again there
		if(len w != 3)
			return 0;
		(a, b, err) := graph.invert("phase",
			Point(int hd tl w, int hd tl tl w));
		if(err != nil)
			return 0;	# the click was in the time series, a readout
		sim.reset();
		(sim.state[0], sim.state[1]) = (a, b);
		graph.cmd("history clear");
		sim.record();
	"bar" =>
		# Population: a click in a bar sets that state directly
		bars := look.panes[look.diagpane].im;
		if(len w != 3 || bars == nil)
			return 0;
		(px, py) := (int hd tl w, int hd tl tl w);
		height := bars.r.dy()/len sim.state;
		if(height <= 0)
			return 0;
		which := py/height;
		if(which < 0 || which >= len sim.state)
			return 0;
		sim.state[which] = maxreal(0.0,
			sim.dispmax*real px/real bars.r.dx());
		sim.t = 0.0;
		graph.cmd("history clear");
		sim.record();
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
			return control("reset");
		'.' =>
			if(sim.paused && !sim.finished && look.perframe > 0)
				sim.step();
		}
	}
	return 0;
}

timer(ticks: chan of int)
{
	for(;;){
		sys->sleep(25);
		ticks <-= 1;
	}
}

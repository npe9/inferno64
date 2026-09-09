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
include "math/vsprite.m";
	vspr: Vsprite;
	Elem, Sprite: import vspr;
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
	endsontime:	int;	# the run stops at the spec's maxtime
	landing:	int;	# and sooner if the height crosses zero
	floor:		int;	# no state may go negative
};

# Everything that changes as time runs.  A family uses the fields it
# needs and leaves the rest alone: obsmax belongs to Mechanism and Orbit,
# dispmax to Population, xmax/ymax/latmax/vmax to Trajectory and Flight,
# mass and the trail to Orbit, data and home to Profile.
# ---------- the pictures ----------
#
# A model used to draw its moving parts as circles: a pendulum bob was
# an ellipse of radius 4, a planet an ellipse of radius 7.  They are
# sprites now, and vsprite(2) sprites rather than pictures, so the same
# file is drawn at whatever size the pane calls for and at whatever angle
# the thing is pointing - a rocket that flies nose-first does so because
# the sprite is turned, not because there are eight of it on disk.
#
# The files are element lists in /lib/danby/sprites, the same text form
# scripts/tos_extract_sprites.py writes and temple/spriteedit(1) edits,
# so a model's parts can be redrawn without touching this file.
SPRITEDIR: con "/lib/danby/sprites";

# One raster of one sprite, at one size and one angle.
Ras: adt {
	name:	string;
	deg:	int;		# tenths of a degree, so the key is exact
	sx, sy:	int;		# hundredths, separately: a link is stretched
	im:	ref Image;
	mask:	ref Image;
	r:	Rect;
};

display: ref Display;
fixedpt: array of int;			# Mechanism: which points never move
homept: array of real;			# and where they started
sprites: list of (string, ref Sprite);	# the element lists, read once
rasters: list of ref Ras;		# and what they were drawn to
rashit := 0;				# what the cache is worth, which the
rasmiss := 0;				# census reports: a link that misses
rasflush := 0;				# every frame is milliseconds a frame
nrasters := 0;

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
	land:		fn(s: self ref Sim, old: array of real, oldt: real);
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
	# The sprites are not required: a model without them draws the
	# circles it always drew, which is why this is not in the check
	# below.
	if(vspr == nil){
		vspr = load Vsprite Vsprite->PATH;
		if(vspr != nil)
			vspr->init();
	}
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
	# explicit, because a ref adt field that is never assigned has bitten
	# this library before - see Look.landing in doc/danby-models.md
	c.linkspr = array[0] of string;
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
		"sprite" =>
			claimed = 1;
			if(nwords != 2)
				err = "sprite: usage: sprite NAME";
			else
				c.sprite = w[1];
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
	if(nwords != 3 && nwords != 4)
		return "link: usage: link NAME NAME [COMPONENT]";
	for(i := 1; i <= 2; i++)
		if(nameindex(m.pointnames, w[i]) < 0)
			return "link: no point named "+w[i];
	comp := "";
	if(nwords == 4){
		comp = w[3];
		if(!islinkcomp(comp))
			return "link: no component named "+comp;
	}else
		comp = componentfor(w[1], w[2]);
	n := len c.links;
	l := array[n+2] of int;
	for(i = 0; i < n; i++)
		l[i] = c.links[i];
	l[n] = nameindex(m.pointnames, w[1]);
	l[n+1] = nameindex(m.pointnames, w[2]);
	c.links = l;
	sp := array[n/2+1] of string;
	for(i = 0; i < n/2; i++)
		sp[i] = c.linkspr[i];
	sp[n/2] = comp;
	c.linkspr = sp;
	return nil;
}

# The components a link may be drawn as.  Adding one is adding a .spr in
# /lib/danby/sprites drawn along +x from the origin to (100, 0), and its
# name here.
LINKCOMPS: con "rod beam string spring";

islinkcomp(s: string): int
{
	(nil, l) := sys->tokenize(LINKCOMPS, " ");
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

# Which component a link is, when the spec does not say.  Decided by
# watching the names, in the same spirit as which points are fixed: a
# spec that calls its endpoints rail_left and rail_right has said the
# thing is a rail, and making 214 links each name a component to say
# what their names already say would be worse than reading them.  A spec
# that disagrees writes the component as the third word.
componentfor(a, b: string): string
{
	n := a + " " + b;
	if(hasword(n, "spring"))
		return "spring";
	if(hasword(n, "string") || hasword(n, "cord") || hasword(n, "rope")
	|| hasword(n, "cable") || hasword(n, "wire"))
		return "string";
	if(hasword(n, "rail") || hasword(n, "bench") || hasword(n, "beam")
	|| hasword(n, "track") || hasword(n, "ground") || hasword(n, "floor")
	|| hasword(n, "wall"))
		return "beam";
	return "rod";
}

hasword(s, w: string): int
{
	for(i := 0; i + len w <= len s; i++)
		if(s[i:i+len w] == w)
			return 1;
	return 0;
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
	# A spec that says nothing about its picture gets its family's, so
	# the 151 that were written before there were any need no editing.
	# Most things that fly in this book are balls, and the four Flight
	# models that are not a ball say so.
	if(c.sprite == nil)
		case c.family {
		Trajectory or Flight =>
			c.sprite = "ball";
		}
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

# Every parameter of a population or an ecology is a rate or a capacity,
# and neither can be negative - so a slider that could reach below zero
# would be offering a state the model has no meaning for.  This is a
# statement about those two families' equations, not about their sliders,
# which is why it did not go when the sliders became Tk scales.  It does
# not hold for Trajectory or Flight, where an angle is signed.
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
# in seven different files is in this one function - and every field is
# set here, none left to whatever the allocation happened to hold.
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
	l.endsontime = 1;
	l.landing = 0;
	l.floor = 0;
	l.graphpane = 0;
	l.diagpane = -1;
	l.click = nil;
	l.clickcmd = nil;
	l.focus = nil;
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
		# a population runs until the window closes, and cannot go
		# negative, which are this family's rules and not the clock's
		(l.endsontime, l.floor) = (0, 1);
		(l.click, l.clickcmd) = (".plot.bars", "bar");
	Trajectory =>
		l.panes = array[] of {pane(".plot.p", "-width 700 -height 380", whole)};
		l.focus = ".plot.p";
		l.perframe = 5;
		l.landing = 1;
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
		(l.endsontime, l.floor) = (0, 1);
		(l.click, l.clickcmd) = (".plot.p", "plot");
	Flight =>
		l.panes = array[] of {pane(".plot.p", "-width 700 -height 440", whole)};
		l.focus = ".plot.p";
		l.atwidth = 520;
		l.perframe = 5;
		l.landing = 1;
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

	display = top.display;
	census = envint("#e/DANBY_PIXELS");
	if(census == 0)
		census = envint("/env/DANBY_PIXELS");
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
		# reused, not reallocated: a slider drag resets once per
		# resolution step, up to two hundred times across one drag
		if(s.trail == nil)
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
	old: array of real;
	oldt := s.t;
	if(look.landing){
		# land() interpolates back to the crossing, so it needs the
		# state on the near side of it; nothing else does
		old = array[len s.state] of real;
		old[0:] = s.state;
	}
	numerics->rk4(s.work, rhs, s.t, look.dt, s.state);
	s.t += look.dt;
	if(look.landing)
		s.land(old, oldt);
	if(look.floor)
		for(i := 0; i < len s.state; i++)
			if(s.state[i] < 0.0)
				s.state[i] = 0.0;
	if(look.endsontime && s.t >= model.maxtime){
		s.finished = 1;
		s.paused = 1;
	}
	s.grow();
	s.record();
}

# The flight ends where the height crosses zero, interpolated to the
# crossing rather than to the end of the step.
#
# Both flying families put the positions in the first half of the state
# vector and their velocities in the second, and in both the height is
# the LAST position - state[1] of four, state[2] of six.  So the index is
# derived rather than written down per family: there is no constant here
# to get the wrong way round, and parse() has already refused a spec
# whose state count is not the four or six this assumes.
Sim.land(s: self ref Sim, old: array of real, oldt: real)
{
	h := len s.state/2 - 1;
	# a state vector too short to have a height has no crossing to find,
	# and h would be negative.  Only the two flying families set
	# look.landing, so this cannot happen - but "cannot happen" is what
	# was said before a stray flag sent a one-state population in here
	# and indexed state[-1].
	if(h < 0)
		return;
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
	# after the plot, because it goes on top of it
	case cfg.family {
	Trajectory =>
		drawflier("flight", sim.state[0], sim.state[1],
			sim.state[2], sim.state[3]);
	Flight =>
		drawflier("side", sim.state[0], sim.state[2],
			sim.state[3], sim.state[5]);
	}
	dirty := "";
	for(i = 0; i < len look.panes; i++)
		dirty += look.panes[i].w + " dirty; ";
	cmd(dirty + "update");
	if(census > 0)
		takecensus();
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
		comp := "rod";
		if(i < len cfg.linkspr)
			comp = cfg.linkspr[i];
		if(!drawlink(im, pa, pb, comp, viewscale(view)))
			im.line(pa, pb, Draw->Endsquare, Draw->Endsquare, 3,
				palette[1], Point(0,0));
	}
	# A point that has never left where it started is what the mechanism
	# is bolted to, and is drawn as one; everything else is a mass.
	# Which is which is decided by watching rather than by a rule in the
	# spec, because no spec says: a hoop's centre and a pendulum's pivot
	# are both simply points that do not move.
	if(len fixedpt != len points/2){
		fixedpt = array[len points/2] of { * => 1 };
		homept = array[len points] of real;
		homept[0:] = points;
	}
	for(i = 0; i < len points/2; i++)
		if(absreal(points[2*i]-homept[2*i]) > 1e-9
		   || absreal(points[2*i+1]-homept[2*i+1]) > 1e-9)
			fixedpt[i] = 0;

	scale := viewscale(view);
	for(i = 0; i < len points/2; i++){
		at := onview(view, points[2*i], points[2*i+1],
			xmin, xmax, ymin, ymax);
		name := "bob";
		if(fixedpt[i])
			name = "anchor";
		if(!drawsprite(im, at, name, 0.0, scale))
			im.ellipse(at, 4, 4, 0, fg, Point(0,0));
	}
}

# The element list, read the first time it is asked for.  A model that
# has no sprite for something falls back to what it drew before, so a
# missing file costs a circle rather than a picture.
spritefor(name: string): ref Sprite
{
	for(l := sprites; l != nil; l = tl l){
		(nm, sp) := hd l;
		if(nm == name)
			return sp;
	}
	sp: ref Sprite;
	if(vspr != nil)
		(sp, nil) = vspr->read(SPRITEDIR + "/" + name + ".spr");
	sprites = (name, sp) :: sprites;
	return sp;
}

# The raster, kept.  The key is the angle in tenths of a degree and the
# scale in hundredths, both exact integers: two callers asking for the
# same picture get the same one, and a caller asking for a picture that
# is not there gets it drawn rather than the nearest one that is.  A
# cache that answers with the nearest is how temple/stadium nearly drew
# a knocked-over fan standing up.
rasterof(name: string, deg, sx, sy: real): ref Ras
{
	if(sx < 0.15)
		sx = 0.15;
	if(sy < 0.15)
		sy = 0.15;
	dk := int (deg*10.0);
	xk := int (sx*100.0);
	yk := int (sy*100.0);
	if(xk < 15)
		xk = 15;
	if(yk < 15)
		yk = 15;
	for(l := rasters; l != nil; l = tl l){
		ras := hd l;
		if(ras.name == name && ras.deg == dk
		&& ras.sx == xk && ras.sy == yk){
			rashit++;
			return ras;
		}
	}
	rasmiss++;
	sp := spritefor(name);
	if(sp == nil || display == nil)
		return nil;
	# A part that is twice as long is not twice as thick, so the two
	# axes are stretched in the sprite's own frame first and only the
	# turn is left to the sprite type.  Nothing but a link asks for
	# that, and a link asks for it every frame.
	if(xk != yk){
		sp = stretch(sp, real xk/100.0, real yk/100.0);
		if(sp == nil)
			return nil;
		if(dk != 0)
			sp = sp.transformed(real dk/10.0, 1.0);
	}else if(dk != 0 || xk != 100)
		sp = sp.transformed(real dk/10.0, real xk/100.0);
	(im, mask, r) := sp.raster(display);
	if(im == nil)
		return nil;
	ras := ref Ras(name, dk, xk, yk, im, mask, r);
	# The angles a model asks for are continuous, so this would grow
	# without bound; past a few hundred the oldest go.
	if(nrasters > 480){
		rasters = nil;
		nrasters = 0;
		rasflush++;
	}
	rasters = ras :: rasters;
	nrasters++;
	return ras;
}

# The four link components are lines, points, flood fills and a pen
# width, and those are the only kinds a stretch has an answer for: a
# circle would have to become an ellipse, a regular polygon is regular by
# construction, text and a bitmap do not stretch at all.  So a component
# holding anything else is refused rather than quietly distorted, and the
# caller falls back to the line it used to draw.  The pen follows y,
# which is the axis a link's thickness is in.
stretch(sp: ref Sprite, sx, sy: real): ref Sprite
{
	els := array[len sp.elems] of ref Elem;
	for(i := 0; i < len sp.elems; i++){
		e := vspr->copyelem(sp.elems[i]);
		case e.kind {
		Vsprite->SCOLOR or Vsprite->SDITHER =>
			;
		Vsprite->STHICK =>
			e.a[0] = int (real e.a[0]*sy);
			if(e.a[0] < 1)
				e.a[0] = 1;
		Vsprite->SLINE =>
			e.a[0] = int (real e.a[0]*sx);
			e.a[1] = int (real e.a[1]*sy);
			e.a[2] = int (real e.a[2]*sx);
			e.a[3] = int (real e.a[3]*sy);
		Vsprite->SPT or Vsprite->SFLOOD or Vsprite->SFLOODNOT =>
			e.a[0] = int (real e.a[0]*sx);
			e.a[1] = int (real e.a[1]*sy);
		* =>
			return nil;
		}
		els[i] = e;
	}
	t := ref Sprite;
	t.elems = els;
	return t;
}

# A link is a component drawn along +x from its own origin to (100, 0),
# turned to lie along the segment and scaled so that its 100 becomes the
# segment's length.  The scale is uniform because that is what the sprite
# type does and what TempleOS's SpriteTransformQue did, so a longer rod
# is also a thicker one; a rod is not a line with a width parameter, it
# is a part, and a part drawn twice the size is twice the size.
#
# The angle and the scale both move every frame - the view rescales to
# whatever the mechanism currently spans - so both are quantised before
# the cache is asked: a whole degree, and two per cent of the nominal
# length, which is two pixels in a hundred.  Quantising is not clamping.
# An angle or a scale outside what the cache holds is still drawn, just
# without a cached raster.
LINKNOMINAL: con 100.0;

# The size the parts are drawn at: a mechanism squeezed into a small pane
# gets small parts rather than parts that swamp it.  A link's thickness
# is this and its length is the segment, which is the whole reason the
# two axes are stretched separately.
viewscale(view: Rect): real
{
	s := real(view.dx())/460.0;
	if(s > 1.6)
		s = 1.6;
	if(s < 0.5)
		s = 0.5;
	return s;
}

drawlink(im: ref Image, pa, pb: Point, comp: string, thick: real): int
{
	if(comp == nil)
		return 0;
	dx := real(pb.x - pa.x);
	dy := real(pb.y - pa.y);
	dist := math->sqrt(dx*dx + dy*dy);
	if(dist < 1.0)
		return 0;
	deg := math->atan2(dy, dx)*180.0/Math->Pi;
	deg = real int(deg + 0.5*sgnreal(deg));
	sx := dist/LINKNOMINAL;
	sx = real int(sx*50.0 + 0.5)/50.0;
	if(sx < 0.02)
		return 0;
	ras := rasterof(comp, deg, sx, thick);
	if(ras == nil)
		return 0;
	im.draw(Rect((pa.x+ras.r.min.x, pa.y+ras.r.min.y),
		(pa.x+ras.r.max.x, pa.y+ras.r.max.y)),
		ras.im, ras.mask, ras.im.r.min);
	return 1;
}

sgnreal(v: real): real
{
	if(v < 0.0)
		return -1.0;
	return 1.0;
}

# Draw one, centred on the sprite's own origin at p.  Returns 0 if there
# was no sprite, so a caller can fall back to the circle it used to draw.
drawsprite(im: ref Image, p: Point, name: string, deg, scale: real): int
{
	ras := rasterof(name, deg, scale, scale);
	if(ras == nil)
		return 0;
	im.draw(Rect((p.x+ras.r.min.x, p.y+ras.r.min.y),
		(p.x+ras.r.max.x, p.y+ras.r.max.y)),
		ras.im, ras.mask, ras.im.r.min);
	return 1;
}

# plot(2) will say what data a pixel means but not what pixel a datum is,
# so the map is derived from two inversions.  It is affine, so two are
# enough, and taking it from the plotter rather than from the margins
# means a change to the layout cannot put the sprite in the wrong place.
viewpoint(view: string, x, y: real): (Point, int)
{
	im := look.panes[look.graphpane].im;
	if(im == nil)
		return (Point(0,0), 0);
	# A view is not the whole pane - a trajectory's pane is split with
	# its telemetry - and there is no way to ask where it is, so the
	# two points the map is derived from are found by asking: a pixel
	# the plotter will invert is a pixel inside the view.
	(p0, p1, found) := viewcorners(im, view);
	if(!found)
		return (Point(0,0), 0);
	(ax, ay, e0) := graph.invert(view, p0);
	(bx, by, e1) := graph.invert(view, p1);
	if(e0 != nil || e1 != nil || ax == bx || ay == by)
		return (Point(0,0), 0);
	px := p0.x + int((x-ax)*real(p1.x-p0.x)/(bx-ax));
	py := p0.y + int((y-ay)*real(p1.y-p0.y)/(by-ay));
	return (Point(px, py), 1);
}

# Two pixels inside the named view, as far apart as a coarse scan finds.
# The scan is 8x8 and its result depends only on the pane's size, so it
# is worked out once per pane rather than once per frame.
cornerview: string;
cornerrect: Rect;
corner0, corner1: Point;
cornerok := 0;

viewcorners(im: ref Image, view: string): (Point, Point, int)
{
	if(cornerok && cornerview == view && cornerrect.eq(im.r))
		return (corner0, corner1, 1);
	cornerview = view;
	cornerrect = im.r;
	cornerok = 0;
	lo := Point(0,0);
	hi := Point(0,0);
	n := 0;
	for(i := 0; i < 8; i++)
		for(j := 0; j < 8; j++){
			p := Point(im.r.min.x + (im.r.dx()*(2*i+1))/16,
				im.r.min.y + (im.r.dy()*(2*j+1))/16);
			(nil, nil, e) := graph.invert(view, p);
			if(e != nil)
				continue;
			if(n == 0){
				lo = p;
				hi = p;
			}else{
				if(p.x < lo.x) lo.x = p.x;
				if(p.y < lo.y) lo.y = p.y;
				if(p.x > hi.x) hi.x = p.x;
				if(p.y > hi.y) hi.y = p.y;
			}
			n++;
		}
	if(n < 4 || hi.x <= lo.x || hi.y <= lo.y)
		return (Point(0,0), Point(0,0), 0);
	corner0 = lo;
	corner1 = hi;
	cornerok = 1;
	return (lo, hi, 1);
}

# The thing that is flying, drawn where it is and pointing where it is
# going.  A trajectory used to be a line with nothing on the end of it.
drawflier(view: string, x, y, vx, vy: real)
{
	im := look.panes[look.graphpane].im;
	if(im == nil)
		return;
	(at, ok) := viewpoint(view, x, y);
	if(!ok || !at.in(im.r.inset(2)))
		return;
	deg := 0.0;
	if(vx != 0.0 || vy != 0.0)
		deg = -math->atan2(vy, vx)*180.0/Math->Pi;
	drawsprite(im, at, cfg.sprite, deg, 1.0);
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
		# What a body looks like is what it weighs: the heaviest is
		# the one everything else goes round, and the lightest is a
		# moon.  The spec never says which is which and does not have
		# to - it says the masses, and they are the same fact.
		name := "planet";
		if(i == focus)
			name = "sun";
		else if(s.mass[i] < s.mass[focus]*0.02)
			name = "moon";
		size := 1.0;
		if(s.mass[focus] > 0.0){
			ratio := s.mass[i]/s.mass[focus];
			size = 0.55 + 0.75*math->pow(ratio, 0.25);
			if(size > 1.5)
				size = 1.5;
			if(size < 0.55)
				size = 0.55;
		}
		if(drawsprite(im, point, name, 0.0, size))
			radius = 7;
		else
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

# In-process evidence that the sprites reached the pixels, which a
# screenshot cannot give and a reading of the code cannot either.  With
# /env/DANBY_PIXELS set to a frame number the library reads back the
# diagram pane at that frame and prints how many distinct colours are in
# it and how many pixels each holds.  A model drawing circles has three
# or four colours; one drawing a sprite has seven or more, and the counts
# say which sprite.  Nothing is read and nothing is printed when the
# variable is not set.
CENSUSFRAME: con 60;	# a second and a half in, with the model moving
census := 0;
censusn := 0;

# Zero when the file is not there at all.  When it is there but empty -
# which is what `echo -n 90 > /env/DANBY_PIXELS` leaves behind, the env
# device taking the create and not the write - the frame is the default
# rather than nothing, so that merely creating the file turns the census
# on.
envint(f: string): int
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return 0;
	b := array[32] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return CENSUSFRAME;
	v := int string b[0:n];
	if(v <= 0)
		return CENSUSFRAME;
	return v;
}

takecensus()
{
	if(++censusn < census)
		return;
	census = -1;
	i := look.diagpane;
	if(i < 0)
		i = look.graphpane;
	im := look.panes[i].im;
	if(im == nil)
		return;
	r := im.r;
	bpp := (im.depth+7)/8;
	buf := array[r.dx()*bpp] of byte;
	cols := array[64] of int;
	cnts := array[64] of int;
	n := 0;
	for(y := r.min.y; y < r.max.y; y++){
		if(im.readpixels(Rect((r.min.x, y), (r.max.x, y+1)), buf) < 0)
			return;
		for(x := 0; x < r.dx(); x++){
			b := buf[x*bpp:];
			# the pane is 32 bits deep and readpixels hands back
			# the channel bytes in red-first order, so this is the
			# RGB that grpalette(2) names and not its reverse.
			v := (int b[0]<<16)|(int b[1]<<8)|int b[2];
			for(k := 0; k < n; k++)
				if(cols[k] == v)
					break;
			if(k == n){
				if(n >= len cols)
					continue;
				cols[n] = v;
				cnts[n] = 0;
				n++;
			}
			cnts[k]++;
		}
	}
	sys->print("danby census %s: %d colours\n", cfg.title, n);
	# The picture is only half of it: a link's raster costs the best
	# part of a millisecond, so a cache that misses every frame is a
	# regression the colours cannot see.
	if(rashit+rasmiss > 0)
		sys->print("\trasters %d hit %d miss %d flush over %d frames\n",
			rashit, rasmiss, rasflush, censusn);
	for(k := 0; k < n; k++)
		sys->print("\t%.6x %d\n", cols[k], cnts[k]);
}

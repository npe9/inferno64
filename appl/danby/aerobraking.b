implement Aerobraking;

# aerobraking - one file, nothing else: no plugin, no library, no
# harness. The problem (central 1/r^3 gravity plus atmospheric drag -
# the same formula danbyeqnall(1) already verified against the real
# Atmosphere module) is specified in eqn(7); the diagnostic plot is
# specified in plot(2)'s own graph command language; the interface
# (parameter sliders, pause/reset) is real Tk, built directly from the
# same "param" declarations the physics uses.
#
# SPEC below is a SCRIPT, not a document parsed into a structure and
# then acted on: cmd() is a command dispatcher, the same shape as
# tk->cmd()/Plotter.cmd(), and execspec() just feeds SPEC to it one
# line at a time. But this file does NOT parse the model's own
# equation vocabulary itself - param/maxtime/state/derivative/eq/
# observable all mean "bind a name to a compiled expression in a
# symbol table", which is dynsys(2)'s OWN vocabulary (see
# module/dynsys.m), not this app's data, and NOT hoc(2)'s either: hoc
# is just an equation parser/evaluator (compile/compileeqn/eval/
# symbol/reset), nothing about named states, derivatives, or
# observables - that ODE-system concept is a different layer, built
# out of hoc expressions, the same way pde(2) is a different layer
# built out of hoc expressions for PDEs. cmd() below only ever handles
# the handful of lines that ARE this app's own concern - title/
# bodylabels/mass (plain data) and graph (plot(2)'s own language,
# collected here only because timing which graph commands run once vs.
# every redraw is this app's business, not dynsys's or plot's) - and
# routes every other line to dynsys->cmd(), the same way a shell
# dispatches its own builtins first and an external command otherwise:
#
#   title TEXT                      - rest of the line, verbatim
#   bodylabels WORD WORD ...
#   mass NUM NUM ...                - one per body, same count/order as bodylabels
#   graph TEXT                      - repeatable, rest of the line
#                                      verbatim, passed straight to
#                                      plot(2)'s own Plotter.cmd() -
#                                      table/colour once at setup,
#                                      axis/line reissued every redraw
#                                      (plot(2)'s own "clear" wipes
#                                      view/layer state, so anything
#                                      tied to a view must be reissued
#                                      after it; "table" must NOT be
#                                      reissued - plot(2)'s own bind()
#                                      unconditionally replaces a table
#                                      with a fresh, empty one, so
#                                      reissuing it every redraw
#                                      silently erased every appended
#                                      data point - found by screenshot,
#                                      chased to plot.b's own source,
#                                      not assumed)
#
# Everything else - param/maxtime/state/derivative/eq/observable - is
# dynsys(2)'s own command language; see module/dynsys.m for that
# vocabulary. This file never touches a ref Hoc->Expr, never compiles
# anything, and never loads or names eqn2hoc(2) - dynsys(2) (via
# hoc(2)) does all of that internally. The "planet" body's four state
# components (x0,y0,vx0,vy0) never move - a real property of this
# specific model (found by reading its original Limbo directly, not
# assumed from the Orbital family's usual N-body shape - see
# doc/danby-tks-plan.md's own correction), not something the command
# language requires.

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

Aerobraking: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);

	# in-process test seam only - matching hoc(2)'s own established
	# reason for one (see appl/lib/hoc.b's header comment): lets
	# eqnorbitaltest(1) verify the SAME spec string this command
	# actually runs, not a copy that could silently drift from it.
	# Not a second interface for anything else to load this by - this
	# file is still the whole application, nothing depends on run().
	run: fn(argv: list of string): (string, int);

	# a second test seam, same reason: drives the model forward through
	# viewgeometry() below - the SAME function draworbits() calls, not a
	# copy - and checks the property orbitviewtest(1) exists to guard:
	# the focus body's own projected point is exactly view centre on
	# every step, and the scale genuinely changes across the run (so a
	# future change that broke both the fix and this check by always
	# returning nil would still be caught). nil on success, else an
	# error string naming what failed and at which step.
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

Ntrail: con 1600;
Panelw: con 900;
Panelh: con 520;

top: ref Toplevel;
cmdch: chan of string;
font: ref Font;
bg, fg: ref Image;
bodycolour: array of ref Image;
buffer: ref Image;

# This app's OWN data - title/bodylabels/mass/graphcmds - plus the
# param/observable tables, which are dynsys(2)'s own live fields (see
# execspec() below: these are literally model.parameter/.minima/
# .maxima/etc, the SAME arrays dynsys->cmd() built and dynsys->rhs()/
# observables() read from - not copies, so writing parameter[i] from a
# Tk slider callback rebinds the running model's value directly).
# Nothing here is a ref Hoc->Expr/Sym - this file has no visibility
# into how any equation is represented, only into the plain data
# dynsys hands back once a script has finished running.
title: string;
bodylabels: array of string;
mass: array of real;
graphcmds: array of string;
paramlabels: array of string;
parameter, minima, maxima: array of real;
observablelabels: array of string;
maxtime: real;
model: ref Dynsys->Model;

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

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	numerics = load Numerics Numerics->PATH;
	plot = load Plot Plot->PATH;
	str = load String String->PATH;
	dynsys = load Dynsys Dynsys->PATH;
	if(sys == nil || draw == nil || tk == nil || tkclient == nil ||
			numerics == nil || plot == nil || str == nil || dynsys == nil)
		raise "fail:Aerobraking: missing support module";
	err := execspec(SPEC);
	if(err != nil)
		raise "fail:Aerobraking: bad spec: "+err;
	if(len paramlabels != len parameter || len minima != len parameter ||
			len maxima != len parameter || len bodylabels != len mass)
		raise "fail:Aerobraking: metadata count";
	if(len observablelabels != 2)
		raise "fail:Aerobraking: expected two observables";

	sys->pctl(Sys->NEWPGRP,nil);
	tkclient->init();
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	menubut: chan of string;
	(top, menubut) = tkclient->toplevel(ctxt, "", title, 0);
	font = Font.open(top.display,"/fonts/lucida/unicode.8.font");
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
	for(i := 0; i < len parameter; i++){
		w := sys->sprint(".c.p%d", i);
		res := (maxima[i]-minima[i])/200.0;
		if(res <= 0.0)
			res = 0.001;
		tkcmd(sys->sprint("scale %s -label {%s} -from %g -to %g -resolution %g"
			+ " -orient horizontal -showvalue 1 -command {send cmd p%d}",
			w, paramlabels[i], minima[i], maxima[i], res, i));
		tkcmd(sys->sprint("%s set %g", w, parameter[i]));
		tkcmd(sys->sprint("pack %s -side left -fill x -expand 1", w));
	}
	tkcmd("pack .c -side bottom -fill x");
	tk->cmd(top, "update");
	tkclient->startinput(top, "kbd"::"ptr"::nil);
	tkclient->onscreen(top, nil);
	if(top.image == nil)
		raise "fail:Aerobraking: onscreen left nil image";

	buffer = top.display.newimage(Rect((0,0),(Panelw,Panelh)), top.image.chans, 0, Draw->White);
	if(buffer == nil)
		raise "fail:Aerobraking: cannot allocate drawing buffer";
	tk->putimage(top, ".f.p", buffer, nil);
	graph = plot->new(buffer,font);
	for(j := 0; j < len graphcmds; j++)
		graph.cmd(graphcmds[j]);
	trail = array[Ntrail] of array of real;
	reset();
	redraw();
	ticks := chan of int;
	spawn timer(ticks);
	for(;;) alt {
	s := <-top.ctxt.kbd =>
		tk->keyboard(top, s);
		case s {
		16r1b or 'q' or 'Q' => tkclient->wmctl(top, "exit");
		' ' => if(!finished) paused = !paused;
		'r' or 'R' => reset();
		'.' => if(paused && !finished) step();
		}
		redraw();
	s := <-top.ctxt.ptr =>
		tk->pointer(top, *s);
	s := <-top.ctxt.ctl or
	s = <-top.wreq or
	s = <-menubut =>
		tkclient->wmctl(top, s);
	press := <-cmdch =>
		(nil, word) := sys->tokenize(press, " ");
		if(word == nil)
			continue;
		case hd word {
		"pause" =>
			if(!finished)
				paused = !paused;
			redraw();
		"reset" =>
			reset();
			redraw();
		* =>
			handleparam(hd word, tl word);
			redraw();
		}
	<-ticks =>
		if(!paused && !finished)
			for(k := 0; k < 4 && !finished; k++)
				step();
		redraw();
	}
}

run(argv: list of string): (string, int)
{
	# a test seam that hands back a spec it never actually ran would be
	# testing nothing - load whatever execspec() needs on its own
	# (eqnorbitaltest(1) calls run() directly, without init() first) and
	# actually run the script, so a caller gets to see whether SPEC is
	# well-formed, not just what it says.
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(str == nil)
		str = load String String->PATH;
	if(dynsys == nil)
		dynsys = load Dynsys Dynsys->PATH;
	if(sys == nil || str == nil || dynsys == nil)
		return (SPEC, 0);
	err := execspec(SPEC);
	return (SPEC, err == nil);
}

# viewtest: drives the model forward without ever opening a window
# (resetstate()/stepstate() skip graph(2) entirely, on purpose - see
# their own comments) and checks the property draworbits()'s rewrite
# exists for, calling the SAME viewgeometry() draworbits() itself
# calls, at three different view sizes:
#
#   - centre is exactly the given view rect's own geometric midpoint,
#     not view.min or anything else "close enough" (checked against an
#     independently computed midpoint, not a second copy of
#     viewgeometry()'s own formula)
#   - focus is the index of the largest mass (checked directly against
#     the model's own "mass" - this file's global, not exported, but
#     viewtest() lives in the same translation unit)
#   - scale is strictly positive throughout, and different AT LEAST
#     once across the run - a fixed scale would mean the "zoom" half
#     of the fix silently stopped happening
#
# Returns nil if every check passed at every step of a full run (or
# up to a generous cap) at all three view sizes, else an error string
# naming what failed, at which step, and at which view size.
viewtest(): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(draw == nil)
		draw = load Draw Draw->PATH;
	if(str == nil)
		str = load String String->PATH;
	if(dynsys == nil)
		dynsys = load Dynsys Dynsys->PATH;
	if(numerics == nil)
		numerics = load Numerics Numerics->PATH;
	if(sys == nil || draw == nil || str == nil || dynsys == nil || numerics == nil)
		return "viewtest: missing support module";
	err := execspec(SPEC);
	if(err != nil)
		return "viewtest: bad spec: "+err;

	wantfocus := 0;
	for(i := 1; i < len mass; i++)
		if(mass[i] > mass[wantfocus])
			wantfocus = i;

	views := array[] of {Rect((0,0),(400,300)), Rect((0,0),(800,600)), Rect((50,20),(450,320))};
	for(v := 0; v < len views; v++){
		view := views[v];
		wantcentre := Point((view.min.x+view.max.x)/2,(view.min.y+view.max.y)/2);
		trail = array[Ntrail] of array of real;
		resetstate();
		recordstate();
		firstscale := 0.0;
		scalechanged := 0;
		# maxtime is 30.0 at a 0.0025 step - a full run is ~12000 steps;
		# 300 (checked first) covered only the first 2.5% of one, nowhere
		# near enough for drag to visibly shrink the orbit, so scale
		# never changed and the test failed for a reason that had
		# nothing to do with draworbits() itself - a real instance of
		# this same repo's own "verify with a negative control" lesson.
		for(n := 0; n < 15000 && !finished; n++){
			(focus, scale, centre) := viewgeometry(view);
			if(focus != wantfocus)
				return sys->sprint("viewtest: view %d step %d: focus %d, want %d (largest mass)",
					v, n, focus, wantfocus);
			if(centre.x != wantcentre.x || centre.y != wantcentre.y)
				return sys->sprint("viewtest: view %d step %d: centre (%d,%d), want (%d,%d)",
					v, n, centre.x, centre.y, wantcentre.x, wantcentre.y);
			if(scale <= 0.0)
				return sys->sprint("viewtest: view %d step %d: scale %g, want > 0",
					v, n, scale);
			if(n == 0)
				firstscale = scale;
			else if(scale != firstscale)
				scalechanged = 1;
			stepstate();
		}
		if(!scalechanged)
			return sys->sprint("viewtest: view %d: scale never changed across the run "+
				"- not exercising the zoom", v);
	}
	return nil;
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

# handleparam: a scale widget's own -command sends "pN VALUE" - see the
# per-parameter tkcmd() calls in init() above.
handleparam(word0: string, rest: list of string)
{
	if(len word0 == 0 || word0[0] != 'p' || rest == nil)
		return;
	(idx, ok) := str->toint(word0[1:], 10);
	if(ok != nil || idx < 0 || idx >= len parameter)
		return;
	parameter[idx] = real hd rest;
	reset();
}

# --- running SPEC as a script: cmd() below does not parse anything -
# it tokenizes a line (the mechanical, generic act of splitting a
# string into words, not "the command language") and PASSES those
# words to whichever parser owns that vocabulary, stopping at the
# first that claims it. dynsys(2) tries first, since param/maxtime/
# state/derivative/eq/observable are its own vocabulary (see
# module/dynsys.m) - this file has no case/keyword recognition of that
# vocabulary anywhere, and never touches a ref Hoc->Expr/Sym. appcmd()
# owns the small remainder (title/bodylabels/mass/graph) that really is
# this app's own data, not equation semantics. Both parsers take the
# SAME already-tokenized words array cmd() built once - no line gets
# tokenized twice. ---

specwords(line: string): array of string
{
	l := str->fields(line);
	a := array[len l] of string;
	i := 0;
	for(; l != nil; l = tl l)
		a[i++] = hd l;
	return a;
}

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

# appcmd: this app's OWN small vocabulary - a window title, body
# labels, masses, and plot(2) graph commands (collected here, not
# forwarded to plot(2) live, only because WHEN each one should run -
# once at setup vs. every redraw - is this app's own business, worked
# out in redraw() below; the graph command text itself is entirely
# plot(2)'s language, untouched here). Same claimed/not-claimed shape
# modelcmd() uses, so cmd() above never needs to know which parser
# will end up handling a given line.
appcmd(a: array of string): (int, string)
{
	case a[0] {
	"title" =>
		title = joinwords(a, 1);
		return (1, nil);
	"bodylabels" =>
		for(i := 1; i < len a; i++)
			bodylabels = addstr(bodylabels, a[i]);
		return (1, nil);
	"mass" =>
		for(i := 1; i < len a; i++)
			mass = addreal(mass, real a[i]);
		return (1, nil);
	"graph" =>
		if(len a < 2)
			return (1, "graph: usage: graph TEXT...");
		graphcmds = addstr(graphcmds, joinwords(a, 1));
		return (1, nil);
	}
	return (0, nil);
}

# joinwords: rejoins already-tokenized words with single spaces - used
# for "title"'s and "graph"'s own "rest of the line, verbatim" rule.
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

addstr(a: array of string, s: string): array of string
{
	n := len a;
	r := array[n+1] of string;
	for(i := 0; i < n; i++)
		r[i] = a[i];
	r[n] = s;
	return r;
}

addreal(a: array of real, v: real): array of real
{
	n := len a;
	r := array[n+1] of real;
	for(i := 0; i < n; i++)
		r[i] = a[i];
	r[n] = v;
	return r;
}

# execspec: the shell that runs the script, one line at a time, via
# cmd() above. A brand-new dynsys Model (its own fresh hoc(2) instance,
# never shared - see module/dynsys.m) is allocated once, before the
# first line, exactly as a real shell starts with a fresh environment;
# everything else this function does is check conditions that can only
# be known once the WHOLE script has run (every state got its matching
# derivative - dynsys->check(), since only dynsys has visibility into
# its own tables; every param/observable count looks right - this
# app's own data, read directly from the model's own public fields
# once the script is done, the same read-only-field convention
# pde(2)'s own Problem already uses) - it does not reach into any one
# line's own effect.
execspec(spec: string): string
{
	model = dynsys->newmodel();
	title = nil;
	bodylabels = nil;
	mass = nil;
	graphcmds = nil;

	for(rest := spec; rest != nil;){
		(line, tail) := str->splitl(rest, "\n");
		if(tail != nil)
			tail = tail[1:];
		rest = tail;
		err := cmd(line);
		if(err != nil)
			return err;
	}

	if(title == nil)
		return "spec has no title command";
	if(len mass != len bodylabels)
		return "mass: must have exactly one value per bodylabels word";
	err := dynsys->check(model);
	if(err != nil)
		return err;
	if(len model.observablelabels != 2)
		return "spec must have exactly two observable commands";
	maxtime = model.maxtime;
	paramlabels = model.paramlabels;
	parameter = model.parameter;
	minima = model.minima;
	maxima = model.maxima;
	observablelabels = model.observablelabels;
	return nil;
}

# --- integration and drawing ---

# resetstate: the physics/trail part of reset(), with no graph(2)
# dependency - split out so viewtest() below can drive a real run
# without a live Plotter (which needs a real Draw->Image, which needs
# a window). reset() itself is unchanged for every real caller.
resetstate()
{
	state = dynsys->initialstate(model);
	if(len state != 4*len mass)
		raise "fail:Aerobraking: state size";
	work = numerics->workspace(len state);
	t = 0.0;
	paused = 0;
	finished = 0;
	trailcount = 0;
	trailnext = 0;
	observationmaximum[0] = 1.0;
	observationmaximum[1] = 1.0;
}

reset()
{
	resetstate();
	graph.cmd("history clear");
	record();
}

# rhs: numerics(2)'s own Rhs function type has no room for a model
# argument, so this one-line closure over the global "model" is all
# that's needed to hand numerics->rk4() a plain Rhs value - forwarding
# only, not parsing anything.
rhs(t: real, values, derivative: array of real)
{
	dynsys->rhs(model, t, values, derivative);
}

step()
{
	numerics->rk4(work,rhs,t,0.0025,state);
	t += 0.0025;
	if(t >= maxtime){
		finished = 1;
		paused = 1;
	}
	record();
}

# stepstate: step()'s own physics-advance, for viewtest() below - same
# reason resetstate()/recordstate() exist. step() itself is unchanged.
stepstate()
{
	numerics->rk4(work,rhs,t,0.0025,state);
	t += 0.0025;
	if(t >= maxtime){
		finished = 1;
		paused = 1;
	}
	recordstate();
}

# recordstate: the trail/observationmaximum bookkeeping part of
# record(), with no graph(2) dependency - same reason resetstate()
# exists (see reset()'s own comment). Returns the observables it just
# computed so record() doesn't compute them twice.
recordstate(): array of real
{
	positions := array[2*len mass] of real;
	i: int;
	for(i = 0; i < len mass; i++){
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
	return values;
}

record()
{
	values := recordstate();
	graph.cmd(sys->sprint("history append %.17g %.17g %.17g",
		t,values[0],values[1]));
}

redraw()
{
	im := buffer;
	im.draw(im.r,bg,nil,Point(0,0));
	content := Rect(im.r.min.add((10,10)),im.r.max.sub((10,50)));
	middle := content.min.x+(content.dx()*3)/5;
	orbitview := Rect(content.min,(middle-20,content.max.y));
	draworbits(im,orbitview);
	graph.image = im;
	gerr(graph.cmd("clear"));
	gerr(graph.cmd("content margin 10 10 10 50\n" +
		"split content x orbitview 3 plotview 2 gutter 55\n" +
		"view diagnostics plotview"));
	# "clear" (above) wipes plot(2)'s own view/layer state, so the
	# model's own "axis"/"line" graph lines (view-tied) must be
	# reissued here, every redraw. "table" must NOT be: plot(2)'s own
	# bind() unconditionally replaces a table with a brand-new, empty
	# one, so reissuing "table history ..." every redraw silently wiped
	# every appended data point right after record() had just added
	# one - draw() then had zero rows to draw, no error anywhere,
	# nothing visible (found by screenshot, chased via plot.b's own
	# source, not assumed). "colour" is idempotent and stays here for
	# simplicity, applied once at setup and harmlessly reapplied.
	for(i := 0; i < len graphcmds; i++)
		if(!str->prefix("table ", graphcmds[i]))
			gerr(graph.cmd(graphcmds[i]));
	tmax := t;
	if(tmax < 2.0)
		tmax = 2.0;
	ymax := observationmaximum[0];
	if(observationmaximum[1] > ymax)
		ymax = observationmaximum[1];
	gerr(graph.cmd(sys->sprint("scale diagnostics x 0 %.8g",tmax)));
	gerr(graph.cmd(sys->sprint("scale diagnostics y %.8g %.8g reverse",-ymax,ymax)));
	graph.draw();
	values := dynsys->observables(model, state);
	status := "running";
	if(paused)
		status = "paused";
	if(finished)
		status = "complete";
	im.text(im.r.min.add((6,6)),fg,Point(0,0),font,
		sys->sprint("%s   %s   t %.3g   %s %.4g   %s %.4g",
			title,status,t,observablelabels[0],values[0],
			observablelabels[1],values[1]));
	im.flush(Draw->Flushnow);
	tkcmd(".f.p dirty");
	tk->cmd(top, "update");
}

# draworbits keeps the most massive body (the "planet") pinned at the
# centre of view and lets the SCALE do all the work as the orbit grows
# or shrinks (drag decaying an apoapsis, say) - not an independent x/y
# bounding box mapped straight onto the view rect, which was the bug:
# that box's own centre drifts as the trail's extent changes even
# though the planet's own position hasn't moved, so the planet visibly
# wandered around the screen instead of staying put while the view
# zoomed. A single uniform scale (not separate x and y ranges) also
# keeps a circular orbit looking circular instead of stretched to fill
# whichever axis has more room.
# viewgeometry: the pure part of draworbits() - which body to focus on,
# and the single uniform scale/centre that follows from the CURRENT
# trail - with no drawing in it, so viewtest() below can call the
# exact same code a real redraw() does, not a copy that could silently
# drift from it.
viewgeometry(view: Rect): (int, real, Point)
{
	focus := 0;
	for(i := 1; i < len mass; i++)
		if(mass[i] > mass[focus])
			focus = i;

	# extent: the largest distance any trail point sits from the
	# FOCUS body's own position at that same instant - not from the
	# focus body's current position, so this still reads correctly
	# for a system whose "planet" isn't perfectly fixed (this specific
	# model's own planet happens to be, but the shared harness this
	# was copied from - since replaced by danbylab(2) - drove other
	# orbital models where it need not be).
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
	extent *= 1.24; # same total padding the old x/y-range version used

	half := view.dx();
	if(view.dy() < half)
		half = view.dy();
	scale := real(half)/(2.0*extent);
	centre := Point((view.min.x+view.max.x)/2,(view.min.y+view.max.y)/2);
	return (focus, scale, centre);
}

draworbits(im: ref Image, view: Rect)
{
	(focus, scale, centre) := viewgeometry(view);

	for(i := 0; i < len mass; i++){
		haveprevious := 0;
		previous := Point(0,0);
		for(k := 0; k < trailcount; k++){
			index := trailnext-trailcount+k;
			if(index < 0)
				index += Ntrail;
			positions := trail[index];
			point := project(centre,scale,positions[2*i],positions[2*i+1],
				positions[2*focus],positions[2*focus+1]);
			if(haveprevious)
				im.line(previous,point,0,0,1,bodycolour[i%len bodycolour],Point(0,0));
			previous = point;
			haveprevious = 1;
		}
		point := project(centre,scale,state[4*i],state[4*i+1],
			state[4*focus],state[4*focus+1]);
		radius := 4;
		if(mass[i] > 0.1)
			radius = 7;
		im.ellipse(point,radius,radius,0,bodycolour[i%len bodycolour],Point(0,0));
		im.text(point.add((radius+3,-3)),fg,Point(0,0),font,bodylabels[i]);
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

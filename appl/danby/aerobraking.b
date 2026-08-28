implement Aerobraking;

# aerobraking - one file, nothing else: no plugin, no library, no
# harness. The problem (central 1/r^3 gravity plus atmospheric drag -
# the same formula danbyeqnall(1) already verified against the real
# Atmosphere module) is specified in eqn(7) - this file never loads or
# names eqn2hoc(2) itself, it just hands eqn source straight to
# hoc->compileeqn(), which does the eqn(7)->hoc(2) translation
# internally (see module/hoc.m's own comment on it); the diagnostic
# plot is specified in plot(2)'s own graph command language; the
# interface (parameter sliders, pause/reset) is real Tk, built
# directly from the same "param" declarations the physics uses.
#
# SPEC below is not a document that gets parsed into a structure and
# then acted on - it is a SCRIPT: cmd() is a real command dispatcher,
# the same shape as tk->cmd()/Plotter.cmd() (one line in, an error
# string or nil out), and execspec() just feeds SPEC to it one line at
# a time, exactly as if it were a shell script being run - each line
# takes effect immediately (compiling its own eqn(7) expression right
# there, growing the running parameter/state/eq tables right there),
# not staged into lists for a separate validation pass at the end.
# There is no separate module interface, no separate parsing library,
# and no separate harness loaded by path - this command IS the whole
# thing, and its own command language is:
#
#   title TEXT                      - rest of the line, verbatim
#   bodylabels WORD WORD ...
#   mass NUM NUM ...                - one per body, same count/order as bodylabels
#   param LABEL DEFAULT MIN MAX     - repeatable; also becomes a real
#                                      Tk scale widget, live-adjustable
#   maxtime NUM
#   state NAME EXPR...              - repeatable; one named state
#                                      variable (declaration order is
#                                      its state[]/derivative[] index)
#                                      and EXPR, its initial value (may
#                                      reference any param)
#   derivative NAME EXPR...         - repeatable, one per state line,
#                                      matched by NAME - the matching
#                                      "state NAME ..." line must come
#                                      first, the same "define before
#                                      use" order an ordinary script
#                                      already requires
#   eq NAME EXPR...                 - repeatable; a named intermediate
#                                      quantity, evaluated in
#                                      declaration order before every
#                                      derivative, so a later eq or any
#                                      derivative may reference an
#                                      earlier eq by name
#   observable LABEL EXPR...        - repeatable; same binding, exactly
#                                      two required (the diagnostic
#                                      plot always shows two)
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
# Every EXPR is eqn(7) syntax, translated to hoc(2) source and compiled
# ONCE, when its command runs; every step only rebinds symbols and
# eval()s the already-compiled trees. The "planet" body's four state
# components (x0,y0,vx0,vy0) never move - a real property of this
# specific model (found by reading its original Limbo directly, not
# assumed from the Orbital family's usual N-body shape - see
# doc/danby-tks-plan.md's own correction), not something this command
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
include "hoc.m";
	hoc: Hoc;

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

title: string;
bodylabels: array of string;
mass: array of real;
paramlabels: array of string;
parameter, minima, maxima: array of real;
maxtime: real;
graphcmds: array of string;
nstate: int;
statenames: array of string;
initexprs, derivexprs: array of ref Hoc->Expr;
eqnames: array of string;
eqexprs: array of ref Hoc->Expr;
observablelabels: array of string;
obsexprs: array of ref Hoc->Expr;
statesyms, paramsyms, eqsyms: array of ref Hoc->Sym;

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
	if(sys == nil || draw == nil || tk == nil || tkclient == nil ||
			numerics == nil || plot == nil || str == nil)
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
	if(sys == nil || str == nil)
		return (SPEC, 0);
	err := execspec(SPEC);
	return (SPEC, err == nil);
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

# --- the spec's own command language: cmd() is a real dispatcher, the
# same shape as tk->cmd()/Plotter.cmd() elsewhere in this file, and
# execspec() just runs SPEC through it one line at a time, like a shell
# script - every command takes effect immediately, growing whatever
# tables it owns right there, instead of staging everything into lists
# for a second pass afterward. ---

specwords(line: string): array of string
{
	l := str->fields(line);
	a := array[len l] of string;
	i := 0;
	for(; l != nil; l = tl l)
		a[i++] = hd l;
	return a;
}

# joinwords: eqn(7)'s own grammar is whitespace-insensitive between
# tokens, so re-joining already-tokenized words with single spaces
# gives eqn2hoc an equivalent source string to whatever was actually
# written. Also used for "graph" lines, which aren't eqn(7) at all but
# benefit from the same "rest of the line, verbatim" handling.
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

# cmd: run one spec line, right now. Every branch either sets state
# that only ever has one legal value (title, maxtime) or grows one of
# the running tables by exactly one element - there is no separate
# "collect list, reverse into array" step: this IS the array, one
# element longer each time its command runs.
cmd(line: string): string
{
	a := specwords(line);
	if(len a == 0)
		return nil;
	case a[0] {
	"title" =>
		title = joinwords(a, 1);
	"bodylabels" =>
		for(i := 1; i < len a; i++)
			bodylabels = addstr(bodylabels, a[i]);
	"mass" =>
		for(i := 1; i < len a; i++)
			mass = addreal(mass, real a[i]);
	"param" =>
		if(len a != 5)
			return "param: usage: param LABEL DEFAULT MIN MAX";
		paramlabels = addstr(paramlabels, a[1]);
		parameter = addreal(parameter, real a[2]);
		minima = addreal(minima, real a[3]);
		maxima = addreal(maxima, real a[4]);
		paramsyms = addsym(paramsyms, hoc->symbol(a[1]));
	"maxtime" =>
		if(len a != 2)
			return "maxtime: usage: maxtime NUM";
		maxtime = real a[1];
	"state" =>
		if(len a < 3)
			return "state: usage: state NAME EXPR...";
		(e, err) := compileone(joinwords(a, 2));
		if(err != nil)
			return "state "+a[1]+": "+err;
		statenames = addstr(statenames, a[1]);
		statesyms = addsym(statesyms, hoc->symbol(a[1]));
		initexprs = addexpr(initexprs, e);
		derivexprs = addexpr(derivexprs, nil); # filled in by "derivative"
	"derivative" =>
		if(len a < 3)
			return "derivative: usage: derivative NAME EXPR...";
		idx := indexof(statenames, a[1]);
		if(idx < 0)
			return "derivative "+a[1]+": no \"state "+a[1]+" ...\" command yet - state must come first";
		(e, err) := compileone(joinwords(a, 2));
		if(err != nil)
			return "derivative "+a[1]+": "+err;
		derivexprs[idx] = e;
	"eq" =>
		if(len a < 3)
			return "eq: usage: eq NAME EXPR...";
		(e, err) := compileone(joinwords(a, 2));
		if(err != nil)
			return "eq "+a[1]+": "+err;
		eqnames = addstr(eqnames, a[1]);
		eqsyms = addsym(eqsyms, hoc->symbol(a[1]));
		eqexprs = addexpr(eqexprs, e);
	"observable" =>
		if(len a < 3)
			return "observable: usage: observable LABEL EXPR...";
		(e, err) := compileone(joinwords(a, 2));
		if(err != nil)
			return "observable "+a[1]+": "+err;
		observablelabels = addstr(observablelabels, a[1]);
		obsexprs = addexpr(obsexprs, e);
	"graph" =>
		if(len a < 2)
			return "graph: usage: graph TEXT...";
		graphcmds = addstr(graphcmds, joinwords(a, 1));
	* =>
		return "unknown command: "+a[0];
	}
	return nil;
}

# execspec: the shell that runs the script. hoc(2) is reset once,
# before the first command, exactly as a real shell starts with a
# fresh environment; everything else this function does is check
# conditions that can only be known once the whole script has run
# (every state line got its matching derivative, etc) - it does not
# reach into any one command's own effect.
execspec(spec: string): string
{
	hoc = load Hoc Hoc->PATH;
	if(hoc == nil)
		return "cannot load hoc(2)";
	hoc->reset();
	maxtime = 0.0;

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
	if(maxtime <= 0.0)
		return "spec has no maxtime command";
	nstate = len statenames;
	if(nstate == 0)
		return "spec has no state commands";
	for(i := 0; i < nstate; i++)
		if(derivexprs[i] == nil)
			return "state "+statenames[i]+": no matching derivative command";
	return nil;
}

# compileone: hoc(2) itself does the eqn(7)->hoc translation now (see
# hoc->compileeqn()'s own comment in module/hoc.m) - this app never
# loads or names eqn2hoc(2) at all, it just hands hoc the eqn source
# straight from the spec.
compileone(eqnsrc: string): (ref Hoc->Expr, string)
{
	return hoc->compileeqn(eqnsrc);
}

indexof(a: array of string, name: string): int
{
	for(i := 0; i < len a; i++)
		if(a[i] == name)
			return i;
	return -1;
}

# addstr/addreal/addexpr/addsym: grow an array by exactly one element.
# Limbo arrays are fixed-size, so this is the one place that pays for
# "the running table is always exactly as long as the script has run
# so far" - a copy per command, not per redraw or per step.
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

addexpr(a: array of ref Hoc->Expr, e: ref Hoc->Expr): array of ref Hoc->Expr
{
	n := len a;
	r := array[n+1] of ref Hoc->Expr;
	for(i := 0; i < n; i++)
		r[i] = a[i];
	r[n] = e;
	return r;
}

addsym(a: array of ref Hoc->Sym, s: ref Hoc->Sym): array of ref Hoc->Sym
{
	n := len a;
	r := array[n+1] of ref Hoc->Sym;
	for(i := 0; i < n; i++)
		r[i] = a[i];
	r[n] = s;
	return r;
}

# --- driving the parsed spec: bind, eval, exactly hoc(2)'s own
# "compile once, resolve symbols once" usage ---

bindparams()
{
	for(i := 0; i < len paramsyms; i++)
		paramsyms[i].val = parameter[i];
}

modelinitialstate(): array of real
{
	bindparams();
	r := array[nstate] of real;
	for(i := 0; i < nstate; i++)
		r[i] = hoc->eval(initexprs[i]);
	return r;
}

rhs(nil: real, values, derivative: array of real)
{
	bindparams();
	i: int;
	for(i = 0; i < nstate; i++)
		statesyms[i].val = values[i];
	for(i = 0; i < len eqexprs; i++)
		eqsyms[i].val = hoc->eval(eqexprs[i]);
	for(i = 0; i < nstate; i++)
		derivative[i] = hoc->eval(derivexprs[i]);
}

modelobservables(values: array of real): array of real
{
	bindparams();
	i: int;
	for(i = 0; i < nstate; i++)
		statesyms[i].val = values[i];
	for(i = 0; i < len eqexprs; i++)
		eqsyms[i].val = hoc->eval(eqexprs[i]);
	r := array[len obsexprs] of real;
	for(i = 0; i < len obsexprs; i++)
		r[i] = hoc->eval(obsexprs[i]);
	return r;
}

# --- integration and drawing ---

reset()
{
	state = modelinitialstate();
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
	graph.cmd("history clear");
	record();
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

record()
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
	values := modelobservables(state);
	for(i = 0; i < 2; i++){
		magnitude := values[i];
		if(magnitude < 0.0)
			magnitude = -magnitude;
		if(magnitude*1.15 > observationmaximum[i])
			observationmaximum[i] = magnitude*1.15;
	}
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
	values := modelobservables(state);
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

draworbits(im: ref Image, view: Rect)
{
	xmin := state[0];
	xmax := state[0];
	ymin := state[1];
	ymax := state[1];
	for(k := 0; k < trailcount; k++){
		index := trailnext-trailcount+k;
		if(index < 0)
			index += Ntrail;
		positions := trail[index];
		for(i := 0; i < len mass; i++){
			x := positions[2*i];
			y := positions[2*i+1];
			if(x < xmin)
				xmin = x;
			if(x > xmax)
				xmax = x;
			if(y < ymin)
				ymin = y;
			if(y > ymax)
				ymax = y;
		}
	}
	if(xmax-xmin < 0.2){
		xmin -= 0.1;
		xmax += 0.1;
	}
	if(ymax-ymin < 0.2){
		ymin -= 0.1;
		ymax += 0.1;
	}
	pad := 0.12;
	dx := xmax-xmin;
	dy := ymax-ymin;
	xmin -= pad*dx;
	xmax += pad*dx;
	ymin -= pad*dy;
	ymax += pad*dy;
	for(i := 0; i < len mass; i++){
		haveprevious := 0;
		previous := Point(0,0);
		for(k = 0; k < trailcount; k++){
			index := trailnext-trailcount+k;
			if(index < 0)
				index += Ntrail;
			positions := trail[index];
			point := project(view,positions[2*i],positions[2*i+1],
				xmin,xmax,ymin,ymax);
			if(haveprevious)
				im.line(previous,point,0,0,1,bodycolour[i%len bodycolour],Point(0,0));
			previous = point;
			haveprevious = 1;
		}
		point := project(view,state[4*i],state[4*i+1],xmin,xmax,ymin,ymax);
		radius := 4;
		if(mass[i] > 0.1)
			radius = 7;
		im.ellipse(point,radius,radius,0,bodycolour[i%len bodycolour],Point(0,0));
		im.text(point.add((radius+3,-3)),fg,Point(0,0),font,bodylabels[i]);
	}
}

project(view: Rect, x, y, xmin, xmax, ymin, ymax: real): Point
{
	return (view.min.x+int((x-xmin)/(xmax-xmin)*real(view.dx())),
		view.max.y-int((y-ymin)/(ymax-ymin)*real(view.dy())));
}

timer(ticks: chan of int)
{
	for(;;){
		sys->sleep(25);
		ticks <-= 1;
	}
}

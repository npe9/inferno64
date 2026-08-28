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
# symbol table", which is hoc(2)'s OWN vocabulary (see module/hoc.m's
# comment on modelcmd()), not this app's data. cmd() below only ever
# handles the handful of lines that ARE this app's own concern -
# title/bodylabels/mass (plain data) and graph (plot(2)'s own
# language, collected here only because timing which graph commands
# run once vs. every redraw is this app's business, not hoc's or
# plot's) - and routes every other line to hoc->modelcmd(), the same
# way a shell dispatches its own builtins first and an external
# command otherwise:
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
# hoc(2)'s own command language; see module/hoc.m for that vocabulary.
# This file never touches a ref Hoc->Expr, never compiles anything,
# and never loads or names eqn2hoc(2) - hoc(2) does all of that
# internally. The "planet" body's four state components (x0,y0,vx0,
# vy0) never move - a real property of this specific model (found by
# reading its original Limbo directly, not assumed from the Orbital
# family's usual N-body shape - see doc/danby-tks-plan.md's own
# correction), not something the command language requires.

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

# This app's OWN data - title/bodylabels/mass/graphcmds - plus the
# param/observable tables, which are hoc(2)'s own live arrays (see
# execspec() below: hoc->modelparams()/modelobslabels() hand back the
# SAME arrays hoc->modelcmd() built and hoc->modelrhs()/
# modelobservables() read from - not copies, so writing parameter[i]
# from a Tk slider callback rebinds hoc's own running value directly).
# Nothing here is a ref Hoc->Expr/Sym - this file has no visibility
# into how any equation is represented, only into the plain data hoc
# hands back once a script has finished running.
title: string;
bodylabels: array of string;
mass: array of real;
graphcmds: array of string;
paramlabels: array of string;
parameter, minima, maxima: array of real;
observablelabels: array of string;
maxtime: real;

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
	hoc = load Hoc Hoc->PATH;
	if(sys == nil || draw == nil || tk == nil || tkclient == nil ||
			numerics == nil || plot == nil || str == nil || hoc == nil)
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
	if(hoc == nil)
		hoc = load Hoc Hoc->PATH;
	if(sys == nil || str == nil || hoc == nil)
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

# --- running SPEC as a script: cmd() below does not parse anything -
# it tokenizes a line (the mechanical, generic act of splitting a
# string into words, not "the command language") and PASSES those
# words to whichever parser owns that vocabulary, stopping at the
# first that claims it. hoc(2) tries first, since param/maxtime/state/
# derivative/eq/observable are its own vocabulary (see module/hoc.m's
# comment on modelcmd()) - this file has no case/keyword recognition
# of that vocabulary anywhere, and never touches a ref Hoc->Expr/Sym.
# appcmd() owns the small remainder (title/bodylabels/mass/graph) that
# really is this app's own data, not equation semantics. Both parsers
# take the SAME already-tokenized words array cmd() built once - no
# line gets tokenized twice. ---

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
	(claimed, err) := hoc->modelcmd(a);
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
# cmd() above. hoc(2)'s own model-script tables are reset once, before
# the first line, exactly as a real shell starts with a fresh
# environment; everything else this function does is check conditions
# that can only be known once the WHOLE script has run (every state
# got its matching derivative - hoc->modelcheck(), since only hoc(2)
# has visibility into its own tables; every param/observable count
# looks right - this app's own data, fetched from hoc's accessors once
# the script is done) - it does not reach into any one line's own
# effect.
execspec(spec: string): string
{
	hoc->modelreset();
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
	maxtime = hoc->modelmaxtime();
	if(maxtime <= 0.0)
		return "spec has no maxtime command";
	if(len hoc->modelstatenames() == 0)
		return "spec has no state commands";
	err := hoc->modelcheck();
	if(err != nil)
		return err;
	(paramlabels, parameter, minima, maxima) = hoc->modelparams();
	observablelabels = hoc->modelobslabels();
	if(len observablelabels != 2)
		return "spec must have exactly two observable commands";
	return nil;
}

# --- integration and drawing ---

reset()
{
	state = hoc->modelinitialstate();
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
	numerics->rk4(work,hoc->modelrhs,t,0.0025,state);
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
	values := hoc->modelobservables(state);
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
	values := hoc->modelobservables(state);
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

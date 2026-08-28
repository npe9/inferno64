implement Eqnorbitalclient;

# eqnorbital - the Orbital family's harness, for models that are real
# COMMAND modules (see appl/danby/plugin/aerobraking.b), not a bespoke
# "Orbital"-typed plugin loaded via module/danby/orbital.m. A model
# needs no separate interface and no separate parsing library: it just
# prints its own spec text (below) when run, and this ONE file - the
# one place that actually drives a model - reads and drives it
# directly, inline. appl/temple/orbital.b (the ORIGINAL harness, and
# the other 11 hand-written Orbital plugins it drives) is untouched;
# this is a new, separate harness, not a replacement.
#
# The model command is loaded via a small LOCAL module type declaring
# both init AND run (matching hoc.b's own real, already-working
# precedent - see p9/cmd/hoctest.b's hocmod->run(argv): (string,int)
# in-process seam) - run(nil) returns the model's own spec text, which
# this file parses once at startup, the same little language pde.m's
# own newproblem() uses for its own problem spec:
#
#   title TEXT                      - rest of the line, verbatim
#   bodylabels WORD WORD ...
#   mass NUM NUM ...                - one per body, same count/order as bodylabels
#   param LABEL DEFAULT MIN MAX     - repeatable
#   maxtime NUM
#   state NAME EXPR...              - repeatable; one named state
#                                      variable (its declaration order
#                                      is its state[]/derivative[]
#                                      index) and EXPR, its initial
#                                      value (may reference any param)
#   derivative NAME EXPR...         - repeatable, one per state line,
#                                      matched by NAME (any order); may
#                                      reference any state, param, or eq
#   eq NAME EXPR...                 - repeatable; a named intermediate
#                                      quantity, evaluated in
#                                      declaration order before every
#                                      derivative, so a later eq or any
#                                      derivative may reference an
#                                      earlier eq by name
#   observable LABEL EXPR...        - repeatable; same binding, exactly
#                                      two required (this harness's own
#                                      diagnostic plot always shows two)
#
# Every EXPR is eqn(7) syntax (see eqn2hoc(2)), translated to hoc(2)
# source and compiled ONCE, at load time; every step only rebinds
# symbols and eval()s the already-compiled trees.

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Font, Point, Rect: import draw;
include "tk.m";
include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;
include "numerics.m";
	numerics: Numerics;
include "plot.m";
	plot: Plot;
	Plotter: import plot;
include "env.m";
	env: Env;
include "string.m";
	str: String;
include "eqn2hoc.m";
	eqn2hoc: Eqn2hoc;
include "hoc.m";
	hoc: Hoc;

Eqnorbitalclient: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

# the model command's own shape - init AND run, matching hoc.b's real
# implement-type (both functions actually declared as part of ONE
# type, the requirement Dis's own link typecheck enforces - see
# doc/danby-tks-plan.md's own note on why a bare "Command" (init only)
# could not be loaded this way).
Modelcmd: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
	run: fn(argv: list of string): (string, int);
};

Ntrail: con 1600;

win: ref Window;
font: ref Font;
bg, fg, grid, firstcolour, secondcolour: ref Image;
bodycolour: array of ref Image;
modelmodule: Modelcmd;

title: string;
bodylabels: array of string;
mass: array of real;
paramlabels: array of string;
parameter, minima, maxima: array of real;
maxtime: real;
nstate: int;
statenames: array of string;
initexprs, derivexprs: array of ref Hoc->Expr;
neq: int;
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
	wmclient = load Wmclient Wmclient->PATH;
	numerics = load Numerics Numerics->PATH;
	plot = load Plot Plot->PATH;
	env = load Env Env->PATH;
	str = load String String->PATH;
	eqn2hoc = load Eqn2hoc Eqn2hoc->PATH;
	if(sys == nil || draw == nil || wmclient == nil || numerics == nil ||
			plot == nil || str == nil || eqn2hoc == nil)
		raise "fail:Eqnorbital: missing support module";
	if(tl argv == nil){
		sys->print("usage: eqnorbital model.dis [manual]\n");
		return;
	}
	modelmodule = load Modelcmd hd tl argv;
	if(modelmodule == nil)
		raise "fail:Eqnorbital: cannot load model";
	(spec, ok) := modelmodule->run(nil);
	if(!ok)
		raise "fail:Eqnorbital: model's own run() failed";
	err := parsespec(spec);
	if(err != nil)
		raise "fail:Eqnorbital: bad spec: "+err;
	if(len paramlabels != len parameter || len minima != len parameter ||
			len maxima != len parameter || len bodylabels != len mass)
		raise "fail:Eqnorbital: metadata count";
	if(len observablelabels != 2)
		raise "fail:Eqnorbital: expected two observables";
	if(env != nil){
		env->clone();
		manual := "danby-"+hd argv;
		if(tl tl argv != nil)
			manual = hd tl tl argv;
		env->setenv("wmman",manual);
	}
	sys->pctl(Sys->NEWPGRP,nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt,title,Wmclient->Appl);
	font = Font.open(win.display,"/fonts/lucida/unicode.8.font");
	bg = win.display.color(int 16r080d18ff);
	fg = win.display.color(int 16re7edf7ff);
	grid = win.display.color(int 16r394457ff);
	firstcolour = win.display.color(int 16r4ec9b0ff);
	secondcolour = win.display.color(int 16rf2b84bff);
	bodycolour = array[] of {
		win.display.color(int 16rf2b84bff),
		win.display.color(int 16r4ec9b0ff),
		win.display.color(int 16r70a5ffff),
		win.display.color(int 16re77c8eff),
		win.display.color(int 16rc792eaff),
		win.display.color(int 16r9dd274ff)
	};
	graph = plot->new(win.image,font);
	graph.cmd("table history time first second -capacity 20000");
	graph.cmd("colour foreground 16re7edf7ff\n"+
		"colour grid 16r394457ff\n"+
		"colour first 16r4ec9b0ff\n"+
		"colour second 16rf2b84bff");
	trail = array[Ntrail] of array of real;
	reset();
	win.reshape(Rect((0,0),(920,580)));
	win.onscreen("place");
	win.startinput("kbd"::"ptr"::nil);
	ticks := chan of int;
	spawn timer(ticks);
	redraw();
	for(;;) alt {
	ctl := <-win.ctl or ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		redraw();
	pointer := <-win.ctxt.ptr =>
		win.pointer(*pointer);
		handlepointer(pointer);
		redraw();
	key := <-win.ctxt.kbd =>
		case key {
		16r1b or 'q' or 'Q' => win.wmctl("exit");
		' ' => if(!finished) paused = !paused;
		'r' or 'R' => reset();
		'.' => if(paused && !finished) step();
		}
	<-ticks =>
		if(!paused && !finished)
			for(i := 0; i < 4 && !finished; i++)
				step();
		redraw();
	}
}

# --- the spec's own little language ---

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
# written - the same trick pde.b's own "rhs" spec line uses.
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

parsespec(spec: string): string
{
	titles: list of string;
	bodies: list of string;
	masses: list of real;
	plabels: list of string;
	pdefaults: list of real;
	pmins: list of real;
	pmaxs: list of real;
	snames: list of string;
	isrcs: list of string;
	dnames: list of string;
	dsrcs: list of string;
	enames: list of string;
	esrcs: list of string;
	olabels: list of string;
	osrcs: list of string;
	maxtime = 0.0;

	for(rest := spec; rest != nil;){
		(line, tail) := str->splitl(rest, "\n");
		if(tail != nil)
			tail = tail[1:];
		rest = tail;
		a := specwords(line);
		if(len a == 0)
			continue;
		case a[0] {
		"title" =>
			titles = joinwords(a, 1) :: titles;
		"bodylabels" =>
			for(i := 1; i < len a; i++)
				bodies = a[i] :: bodies;
		"mass" =>
			for(i := 1; i < len a; i++)
				masses = real a[i] :: masses;
		"param" =>
			if(len a != 5)
				return "param: usage: param LABEL DEFAULT MIN MAX";
			plabels = a[1] :: plabels;
			pdefaults = real a[2] :: pdefaults;
			pmins = real a[3] :: pmins;
			pmaxs = real a[4] :: pmaxs;
		"maxtime" =>
			if(len a != 2)
				return "maxtime: usage: maxtime NUM";
			maxtime = real a[1];
		"state" =>
			if(len a < 3)
				return "state: usage: state NAME EXPR...";
			snames = a[1] :: snames;
			isrcs = joinwords(a, 2) :: isrcs;
		"derivative" =>
			if(len a < 3)
				return "derivative: usage: derivative NAME EXPR...";
			dnames = a[1] :: dnames;
			dsrcs = joinwords(a, 2) :: dsrcs;
		"eq" =>
			if(len a < 3)
				return "eq: usage: eq NAME EXPR...";
			enames = a[1] :: enames;
			esrcs = joinwords(a, 2) :: esrcs;
		"observable" =>
			if(len a < 3)
				return "observable: usage: observable LABEL EXPR...";
			olabels = a[1] :: olabels;
			osrcs = joinwords(a, 2) :: osrcs;
		* =>
			return "unknown spec line: "+a[0];
		}
	}

	if(titles == nil)
		return "spec has no title line";
	title = hd titles;
	bodylabels = revstrs(bodies);
	mass = revreals(masses);
	if(len mass != len bodylabels)
		return "mass: must have exactly one value per bodylabels word";
	paramlabels = revstrs(plabels);
	parameter = revreals(pdefaults);
	minima = revreals(pmins);
	maxima = revreals(pmaxs);
	if(maxtime <= 0.0)
		return "spec has no maxtime line";

	statenames = revstrs(snames);
	isrcsarr := revstrs(isrcs);
	nstate = len statenames;
	if(nstate == 0)
		return "spec has no state lines";

	dnamesarr := revstrs(dnames);
	dsrcsarr := revstrs(dsrcs);
	if(len dnamesarr != nstate)
		return "spec must have exactly one derivative line per state line";

	eqnames = revstrs(enames);
	esrcsarr := revstrs(esrcs);
	neq = len eqnames;

	observablelabels = revstrs(olabels);
	osrcsarr := revstrs(osrcs);

	hoc = load Hoc Hoc->PATH;
	if(hoc == nil)
		return "cannot load hoc(2)";
	hoc->reset();

	i: int;
	statesyms = array[nstate] of ref Hoc->Sym;
	for(i = 0; i < nstate; i++)
		statesyms[i] = hoc->symbol(statenames[i]);
	paramsyms = array[len paramlabels] of ref Hoc->Sym;
	for(i = 0; i < len paramlabels; i++)
		paramsyms[i] = hoc->symbol(paramlabels[i]);
	eqsyms = array[neq] of ref Hoc->Sym;
	for(i = 0; i < neq; i++)
		eqsyms[i] = hoc->symbol(eqnames[i]);

	initexprs = array[nstate] of ref Hoc->Expr;
	for(i = 0; i < nstate; i++){
		(e, err) := compileone(isrcsarr[i]);
		if(err != nil)
			return "state "+statenames[i]+": "+err;
		initexprs[i] = e;
	}

	derivexprs = array[nstate] of ref Hoc->Expr;
	for(i = 0; i < len dnamesarr; i++){
		idx := indexof(statenames, dnamesarr[i]);
		if(idx < 0)
			return "derivative "+dnamesarr[i]+": no matching state line";
		(e, err) := compileone(dsrcsarr[i]);
		if(err != nil)
			return "derivative "+dnamesarr[i]+": "+err;
		derivexprs[idx] = e;
	}

	eqexprs = array[neq] of ref Hoc->Expr;
	for(i = 0; i < neq; i++){
		(e, err) := compileone(esrcsarr[i]);
		if(err != nil)
			return "eq "+eqnames[i]+": "+err;
		eqexprs[i] = e;
	}

	obsexprs = array[len observablelabels] of ref Hoc->Expr;
	for(i = 0; i < len observablelabels; i++){
		(e, err) := compileone(osrcsarr[i]);
		if(err != nil)
			return "observable "+observablelabels[i]+": "+err;
		obsexprs[i] = e;
	}

	return nil;
}

compileone(eqnsrc: string): (ref Hoc->Expr, string)
{
	(hocsrc, err) := eqn2hoc->translate(eqnsrc);
	if(err != nil)
		return (nil, "eqn2hoc: "+eqnsrc+": "+err);
	e := hoc->compile(hocsrc);
	if(e == nil)
		return (nil, "hoc could not compile: "+hocsrc+" (from "+eqnsrc+")");
	return (e, nil);
}

indexof(a: array of string, name: string): int
{
	for(i := 0; i < len a; i++)
		if(a[i] == name)
			return i;
	return -1;
}

revstrs(l: list of string): array of string
{
	n := len l;
	r := array[n] of string;
	i := n;
	for(; l != nil; l = tl l)
		r[--i] = hd l;
	return r;
}

revreals(l: list of real): array of real
{
	n := len l;
	r := array[n] of real;
	i := n;
	for(; l != nil; l = tl l)
		r[--i] = hd l;
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
	for(i = 0; i < neq; i++)
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
	for(i = 0; i < neq; i++)
		eqsyms[i].val = hoc->eval(eqexprs[i]);
	r := array[len obsexprs] of real;
	for(i = 0; i < len obsexprs; i++)
		r[i] = hoc->eval(obsexprs[i]);
	return r;
}

# --- everything below is unchanged from appl/temple/orbital.b's own
# drawing/integration loop - it only ever touches state/mass/parameter
# by index, agnostic to where they came from ---

reset()
{
	state = modelinitialstate();
	if(len state != 4*len mass)
		raise "fail:Eqnorbital: state size";
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

handlepointer(pointer: ref Draw->Pointer)
{
	if(!(pointer.buttons&1) || win.image == nil)
		return;
	r := win.image.r;
	if(pointer.xy.y <= r.max.y-55)
		return;
	n := len parameter;
	width := r.dx()/n;
	which := (pointer.xy.x-r.min.x)/width;
	if(which < 0)
		which = 0;
	if(which >= n)
		which = n-1;
	fraction := real(pointer.xy.x-(r.min.x+which*width))/real(width);
	if(fraction < 0.01)
		fraction = 0.01;
	parameter[which] = minima[which]+(maxima[which]-minima[which])*fraction;
	reset();
}

redraw()
{
	im := win.image;
	if(im == nil)
		return;
	im.draw(im.r,bg,nil,Point(0,0));
	content := Rect(im.r.min.add((25,38)),im.r.max.sub((18,62)));
	middle := content.min.x+(content.dx()*3)/5;
	orbitview := Rect(content.min,(middle-20,content.max.y));
	draworbits(im,orbitview);
	graph.image = im;
	graph.cmd("clear");
	graph.cmd("content margin 25 38 18 62\n" +
		"split content x orbitview 3 plotview 2 gutter 55\n" +
		"view diagnostics plotview");
	tmax := t;
	if(tmax < 2.0)
		tmax = 2.0;
	ymax := observationmaximum[0];
	if(observationmaximum[1] > ymax)
		ymax = observationmaximum[1];
	graph.cmd(sys->sprint("scale diagnostics x 0 %.8g",tmax));
	graph.cmd(sys->sprint("scale diagnostics y %.8g %.8g reverse",-ymax,ymax));
	graph.cmd("axis diagnostics x time");
	graph.cmd("axis diagnostics y value");
	graph.cmd("line diagnostics history x time y first colour first width 2");
	graph.cmd("line diagnostics history x time y second colour second width 2");
	graph.draw();
	values := modelobservables(state);
	status := "running";
	if(paused)
		status = "paused";
	if(finished)
		status = "complete";
	im.text(im.r.min.add((10,18)),fg,Point(0,0),font,
		sys->sprint("%s   %s   t %.3g   %s %.4g   %s %.4g",
			title,status,t,observablelabels[0],values[0],
			observablelabels[1],values[1]));
	for(i := 0; i < len parameter; i++)
		drawparameter(im,i,paramlabels[i],parameter[i],maxima[i]);
	im.flush(Draw->Flushnow);
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

drawparameter(im: ref Image, index: int, name: string,
		value, maximum: real)
{
	width := im.r.dx()/len parameter;
	x := im.r.min.x+index*width;
	y := im.r.max.y-40;
	im.line((x+4,y),(x+width-6,y),0,0,2,grid,Point(0,0));
	fraction := (value-minima[index])/(maximum-minima[index]);
	knob := x+4+int(fraction*real(width-10));
	im.ellipse((knob,y),4,4,0,fg,Point(0,0));
	im.text((x+4,im.r.max.y-17),fg,Point(0,0),font,
		sys->sprint("%s %.3g",name,value));
}

timer(ticks: chan of int)
{
	for(;;){
		sys->sleep(25);
		ticks <-= 1;
	}
}

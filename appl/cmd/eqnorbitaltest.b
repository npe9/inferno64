implement Command;

# eqnorbitaltest(1) - fetches appl/danby/plugin/aerobraking.b's own
# spec text via its real in-process run() seam (exactly as
# appl/temple/eqnorbital.b itself does), then parses and drives it
# with an INDEPENDENTLY WRITTEN copy of the same small grammar - not
# by calling into the harness's own internals (not exposed outside its
# own module type anyway - see doc/danby-tks-plan.md's own note on Dis
# load typechecking). Two independent implementations of the same
# grammar reaching the same known-correct physics is a stronger check
# than one implementation calling itself twice.

include "sys.m";
	sys: Sys;
include "draw.m";
include "string.m";
	str: String;
include "eqn2hoc.m";
	eqn2hoc: Eqn2hoc;
include "hoc.m";
	hoc: Hoc;

Modelcmd: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
	run: fn(argv: list of string): (string, int);
};

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

nfail := 0;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	eqn2hoc = load Eqn2hoc Eqn2hoc->PATH;
	m := load Modelcmd "/dis/danby/plugin/aerobraking.dis";
	if(sys == nil || str == nil || eqn2hoc == nil || m == nil){
		sys->print("load failed\n");
		raise "fail:load";
	}
	(spec, ok) := m->run(nil);
	if(!ok){
		sys->print("model's own run() failed\n");
		raise "fail:run";
	}

	# --- minimal, independent parse: just enough to pull out the
	# param defaults and the derivative/eq expressions this test
	# needs, by name - not a full reimplementation of every directive
	# the real grammar has (bodylabels/mass/state/observable aren't
	# needed for this check).
	paramval: list of (string, real);
	derivsrc: list of (string, string);
	eqsrc: list of (string, string);
	for(rest := spec; rest != nil;){
		(line, tail) := str->splitl(rest, "\n");
		if(tail != nil)
			tail = tail[1:];
		rest = tail;
		a := fields(line);
		if(len a == 0)
			continue;
		case a[0] {
		"param" =>
			paramval = (a[1], real a[2]) :: paramval;
		"derivative" =>
			derivsrc = (a[1], joinfrom(a, 2)) :: derivsrc;
		"eq" =>
			eqsrc = (a[1], joinfrom(a, 2)) :: eqsrc;
		}
	}

	hoc = load Hoc Hoc->PATH;
	hoc->reset();
	for(pv := paramval; pv != nil; pv = tl pv){
		(name, val) := hd pv;
		hoc->setvar(name, val);
	}
	# the representative in-atmosphere state this test has always used
	hoc->setvar("x", 1.05); hoc->setvar("y", 0.3);
	hoc->setvar("vx", -0.02); hoc->setvar("vy", 0.9);

	for(eq := reverse(eqsrc); eq != nil; eq = tl eq){
		(name, src) := hd eq;
		(hocsrc, err) := eqn2hoc->translate(src);
		if(err != nil){
			sys->print("FAIL: eq %s: %s\n", name, err);
			nfail++;
			continue;
		}
		e := hoc->compile(hocsrc);
		if(e == nil){
			sys->print("FAIL: eq %s: hoc could not compile %q\n", name, hocsrc);
			nfail++;
			continue;
		}
		hoc->setvar(name, hoc->eval(e));
	}

	checkderiv(derivsrc, "vx", -0.8063085351010301);
	checkderiv(derivsrc, "vy", -0.2304125843818792);

	# and the two observables, both literally just "eq" names in this
	# spec (radius=r, speedobs=speed2) - confirm those too, straight
	# from hoc's own symbol table after the eq pass above.
	checkval("radius (=r)", hoc->getvar("r"), 1.0920164833920778);
	checkval("speedobs (=speed2)", hoc->getvar("speed2"), 0.9002221947941519);

	if(nfail == 0)
		sys->print("PASS\n");
	else{
		sys->print("%d test(s) failed\n", nfail);
		raise "fail:tests";
	}
}

checkderiv(derivsrc: list of (string, string), name: string, want: real)
{
	for(d := derivsrc; d != nil; d = tl d){
		(n, src) := hd d;
		if(n != name)
			continue;
		(hocsrc, err) := eqn2hoc->translate(src);
		if(err != nil){
			sys->print("FAIL: derivative %s: %s\n", name, err);
			nfail++;
			return;
		}
		e := hoc->compile(hocsrc);
		if(e == nil){
			sys->print("FAIL: derivative %s: hoc could not compile %q\n", name, hocsrc);
			nfail++;
			return;
		}
		got := hoc->eval(e);
		checkval("derivative "+name, got, want);
		return;
	}
	sys->print("FAIL: no derivative line for %s in the model's own spec\n", name);
	nfail++;
}

checkval(what: string, got, want: real)
{
	diff := got - want;
	if(diff < 0.0)
		diff = -diff;
	if(diff > 1.0e-9){
		sys->print("FAIL: %s: got %g, want %g\n", what, got, want);
		nfail++;
		return;
	}
	sys->print("ok: %s = %g\n", what, got);
}

fields(line: string): array of string
{
	l := str->fields(line);
	a := array[len l] of string;
	i := 0;
	for(; l != nil; l = tl l)
		a[i++] = hd l;
	return a;
}

joinfrom(a: array of string, from: int): string
{
	s := "";
	for(i := from; i < len a; i++){
		if(i > from)
			s += " ";
		s += a[i];
	}
	return s;
}

reverse(l: list of (string, string)): list of (string, string)
{
	r: list of (string, string);
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

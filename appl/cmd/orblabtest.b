implement Orblabtest;

# orblabtest - check every Danby N-body model written as an orblab(2)
# script.
#
# The models are one file each, and the model IS the SPEC constant in
# that file, so this reads the source and tests the string that ships,
# not a copy of it that could drift.  Extracting a Limbo string constant
# is a small price for that: the alternative is a test seam in every
# model, which is the sort of thing these models were rewritten to get
# rid of.
#
# Every model: the spec parses, it has four states per body, no rate is a
# NaN at the start, and every body's position rate IS its own velocity.
#
# And the one that matters: gravity between bodies is an internal force,
# so the total momentum cannot change.  Summing mass times acceleration
# over every body must give zero - which it does for the models with an
# external term too, because in those the body being pushed has zero mass
# and the one being held fixed has zero acceleration.  That check came
# from danbytest and is the reason this family is worth testing at all:
# it catches a sign error or a missing reaction in any one of up to
# fifteen pairs.

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "readdir.m";
	readdir: Readdir;
include "numerics.m";
	numerics: Numerics;
include "math.m";
	math: Math;
include "orblab.m";
	orblab: Orblab;
	dynsys: Dynsys;
	Expr: import Hoc;
	Model: import dynsys;

Orblabtest: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

DIR: con "/appl/danby";

bad := 0;
verbose := 0;

fail(s: string)
{
	sys->print("FAIL %s\n", s);
	bad++;
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	readdir = load Readdir Readdir->PATH;
	numerics = load Numerics Numerics->PATH;
	math = load Math Math->PATH;
	orblab = load Orblab Orblab->PATH;
	dynsys = load Dynsys Dynsys->PATH;
	if(bufio == nil || readdir == nil || numerics == nil || math == nil ||
			orblab == nil || dynsys == nil){
		sys->print("FAIL load: %r\n");
		raise "fail:load";
	}
	for(a := tl argv; a != nil; a = tl a)
		if(hd a == "-v")
			verbose = 1;

	(d, n) := readdir->init(DIR, Readdir->NAME);
	if(n <= 0){
		sys->print("FAIL cannot read %s: %r\n", DIR);
		raise "fail:readdir";
	}
	checked := 0;
	for(i := 0; i < n; i++){
		name := d[i].name;
		if(len name < 3 || name[len name-2:] != ".b")
			continue;
		spec := specof(DIR+"/"+name);
		if(spec == nil)
			continue;
		checked++;
		checkspec(name[0:len name-2], spec);
	}
	if(checked == 0)
		fail("no orblab models found in "+DIR);
	if(bad == 0)
		sys->print("OK   %d orblab model specs\n", checked);
	else {
		sys->print("%d failures over %d models\n", bad, checked);
		raise "fail:orblabtest";
	}
}

# specof: the SPEC constant of a mechlab model, or nil if this file is
# not one.  A Limbo string constant is quoted segments joined with +,
# possibly with # comment lines between them, ending at the ; that
# closes the declaration.
specof(path: string): string
{
	iob := bufio->open(path, Bufio->OREAD);
	if(iob == nil)
		return nil;
	ismodel := 0;
	inspec := 0;
	spec := "";
	while((line := iob.gets('\n')) != nil){
		if(!inspec && len line >= 9 && line[0:9] == "SPEC: con"){
			inspec = 1;
			line = line[9:];
		}else if(!inspec){
			if(strstr(line, "orblab->run") >= 0)
				ismodel = 1;
			continue;
		}
		(seg, done) := quoted(line);
		spec += seg;
		if(done)
			inspec = 0;
	}
	if(!ismodel)
		return nil;
	return spec;
}

# quoted: the concatenation of every double-quoted segment on one line,
# with \n understood, and whether the line ends the declaration.
quoted(line: string): (string, int)
{
	s := "";
	i := 0;
	for(; i < len line; i++){
		if(line[i] == '#')
			break;
		if(line[i] == ';')
			return (s, 1);
		if(line[i] != '"')
			continue;
		for(i++; i < len line && line[i] != '"'; i++){
			if(line[i] == '\\' && i+1 < len line){
				i++;
				case line[i] {
				'n' => s[len s] = '\n';
				't' => s[len s] = '\t';
				* => s[len s] = line[i];
				}
				continue;
			}
			s[len s] = line[i];
		}
	}
	return (s, 0);
}

strstr(s, sub: string): int
{
	for(i := 0; i+len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return i;
	return -1;
}

checkspec(name, spec: string)
{
	(m, bodies, exprs, err) := orblab->parse(spec);
	if(err != nil){
		fail(name+": "+err);
		return;
	}
	if(len m.parameter == 0)
		fail(name+": no param commands");
	for(i := 0; i < len m.parameter; i++){
		if(m.minima[i] >= m.maxima[i])
			fail(sys->sprint("%s: param %s range %g..%g",
				name, m.paramlabels[i], m.minima[i], m.maxima[i]));
	}
	state := dynsys->initialstate(m);
	deriv := array[len state] of real;
	dynsys->rhs(m, 0.0, state, deriv);
	for(i = 0; i < len deriv; i++)
		if(deriv[i] != deriv[i])
			fail(sys->sprint("%s: derivative %s is not a number at t=0",
				name, m.statenames[i]));
	if(verbose)
		sys->print("     %s: %d params, %d states\n",
			name, len m.parameter, len m.statenames);
	checkkinematics(name, m, bodies, state, deriv);
	checkmomentum(name, m, bodies, exprs, deriv);
}

# Four states per body, and the first two rates of each body are its own
# velocity components.
checkkinematics(name: string, m: ref Model, bodies: array of string,
		state, deriv: array of real)
{
	for(i := 0; i < len bodies; i++){
		if(deriv[4*i] != state[4*i+2])
			fail(sys->sprint("%s: body %s: dx/dt is %g, not vx %g",
				name, bodies[i], deriv[4*i], state[4*i+2]));
		if(deriv[4*i+1] != state[4*i+3])
			fail(sys->sprint("%s: body %s: dy/dt is %g, not vy %g",
				name, bodies[i], deriv[4*i+1], state[4*i+3]));
	}
}

# Gravity between bodies is internal, so sum(m*a) is zero.
checkmomentum(name: string, m: ref Model, bodies: array of string,
		exprs: array of ref Expr, deriv: array of real)
{
	mass := orblab->masses(m, exprs);
	px := 0.0;
	py := 0.0;
	for(i := 0; i < len mass; i++){
		px += mass[i]*deriv[4*i+2];
		py += mass[i]*deriv[4*i+3];
	}
	if(px > 1.0e-11 || px < -1.0e-11)
		fail(sys->sprint("%s: the internal forces sum to %g in x", name, px));
	if(py > 1.0e-11 || py < -1.0e-11)
		fail(sys->sprint("%s: the internal forces sum to %g in y", name, py));
}

rates(m: ref Model, state: array of real): array of real
{
	d := array[len state] of real;
	dynsys->rhs(m, 0.0, state, d);
	return d;
}

near(what: string, got, want, tol: real)
{
	d := got-want;
	if(d < 0.0)
		d = -d;
	if(d > tol)
		fail(sys->sprint("%s: got %.17g want %.17g", what, got, want));
}







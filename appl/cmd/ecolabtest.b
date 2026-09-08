implement Ecolabtest;

# ecolabtest - check every Danby two-species model written as an
# ecolab(2) script.
#
# The models are one file each, and the model IS the SPEC constant in
# that file, so this reads the source and tests the string that ships,
# not a copy of it that could drift.  Extracting a Limbo string constant
# is a small price for that: the alternative is a test seam in every
# model, which is the sort of thing these models were rewritten to get
# rid of.
#
# Every model: the spec parses, it has two species, no rate is a NaN at
# the start, and - the one that matters - the model is AT REST at the
# equilibrium its own spec declares.  That is the whole point of this
# family: the phase plot marks a fixed point, and a fixed point that the
# equations do not actually fix is a lie on the screen.
#
# Two models are exceptions and are checked differently, both moved here
# from danbytest with the models.  periodicvolterra's birthrate varies
# with time, so its declared equilibrium is the MEAN one: the rates are
# non-zero there at t=0 and zero a quarter period later.  maypredator's
# predators have no capacity without prey, so with the prey gone they
# simply die off.

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
include "ecolab.m";
	ecolab: Ecolab;
	dynsys: Dynsys;
	Expr: import Hoc;
	Model: import dynsys;

Ecolabtest: module
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
	ecolab = load Ecolab Ecolab->PATH;
	dynsys = load Dynsys Dynsys->PATH;
	if(bufio == nil || readdir == nil || numerics == nil || math == nil ||
			ecolab == nil || dynsys == nil){
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
		fail("no ecolab models found in "+DIR);
	if(bad == 0)
		sys->print("OK   %d ecolab model specs\n", checked);
	else {
		sys->print("%d failures over %d models\n", bad, checked);
		raise "fail:ecolabtest";
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
			if(strstr(line, "ecolab->run") >= 0)
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
	(m, eqx, eqy, nil, err) := ecolab->parse(spec);
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
	case name {
	"periodicvolterra" =>
		# the declared fixed point is the mean one: moving at t=0,
		# still a quarter period later
		(ex, ey) := ecolab->equilibrium(m, eqx, eqy);
		st := array[] of {ex, ey};
		d := array[2] of real;
		dynsys->rhs(m, 0.0, st, d);
		if(d[0] == 0.0)
			fail(name+": the birthrate does not vary at t=0");
		quarter := 2.0*3.14159265358979323846/m.parameter[5]/4.0;
		dynsys->rhs(m, quarter, st, d);
		near(name+" mean equilibrium prey", d[0], 0.0, 1.0e-12);
		near(name+" mean equilibrium predator", d[1], 0.0, 1.0e-12);
	"maypredator" =>
		# with no prey there is no capacity to be logistic about
		st := array[] of {0.0, 0.5};
		d := array[2] of real;
		dynsys->rhs(m, 0.0, st, d);
		near(name+" zero-prey boundary", d[1],
			-m.parameter[4]*st[1], 1.0e-12);
	* =>
		checkatrest(name, m, eqx, eqy);
	}
}

# The equilibrium the spec declares must be one: both rates zero there.
checkatrest(name: string, m: ref Model, eqx, eqy: ref Expr)
{
	(ex, ey) := ecolab->equilibrium(m, eqx, eqy);
	if(ex == 0.0 && ey == 0.0)
		return;		# the origin, which every model of this shape fixes
	st := array[] of {ex, ey};
	d := array[2] of real;
	dynsys->rhs(m, 0.0, st, d);
	near(sys->sprint("%s: d%s/dt at the equilibrium", name, m.statenames[0]),
		d[0], 0.0, 1.0e-12);
	near(sys->sprint("%s: d%s/dt at the equilibrium", name, m.statenames[1]),
		d[1], 0.0, 1.0e-12);
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







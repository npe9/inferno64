implement Flightlabtest;

# flightlabtest - check every Danby three-dimensional flight model
# written as a flightlab(2) script.
#
# The models are one file each, and the model IS the SPEC constant in
# that file, so this reads the source and tests the string that ships,
# not a copy of it that could drift.  Extracting a Limbo string constant
# is a small price for that: the alternative is a test seam in every
# model, which is the sort of thing these models were rewritten to get
# rid of.
#
# Every model: the spec parses, it has six states, no rate is a NaN at
# the start, and - the one that matters - the first three derivatives are
# exactly the last three states.
#
# That last is the whole shape of this family.  flightlab plots height
# against downrange and lateral against downrange, and stops the flight
# when the third state crosses zero, so it is relying on the six state
# lines meaning downrange, lateral, height and then those three
# velocities in that order.  A spec that listed them in another order
# would still integrate, still draw, and be wrong everywhere - and the
# cheap way to catch it is that a position's rate has to BE its own
# velocity, which is true by construction if the order is right and
# almost never true if it is not.

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
include "flightlab.m";
	flightlab: Flightlab;
	dynsys: Dynsys;
	Expr: import Hoc;
	Model: import dynsys;

Flightlabtest: module
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
	flightlab = load Flightlab Flightlab->PATH;
	dynsys = load Dynsys Dynsys->PATH;
	if(bufio == nil || readdir == nil || numerics == nil || math == nil ||
			flightlab == nil || dynsys == nil){
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
		sys->print("OK   %d flightlab model specs\n", checked);
	else {
		sys->print("%d failures over %d models\n", bad, checked);
		raise "fail:flightlabtest";
	}
}

# specof: the SPEC constant of a flightlab model, or nil if this file is
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
			if(strstr(line, "flightlab->run") >= 0)
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
	(m, err) := flightlab->parse(spec);
	if(err != nil){
		fail(name+": "+err);
		return;
	}
	if(len m.parameter == 0)
		fail(name+": no param commands");
	for(i := 0; i < len m.parameter; i++)
		if(m.minima[i] >= m.maxima[i])
			fail(sys->sprint("%s: param %s range %g..%g",
				name, m.paramlabels[i], m.minima[i], m.maxima[i]));
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
	# the kinematic identity, at the start and at eleven pseudo-random
	# states: a position's rate is its own velocity and nothing else
	seed := 7717321;
	st := array[6] of real;
	d := array[6] of real;
	for(k := 0; k < 12; k++){
		for(i = 0; i < 6; i++){
			seed = (seed*1103515245+12345)&16r7fffffff;
			st[i] = real(seed%4000)/100.0-10.0;
		}
		if(k == 0)
			for(i = 0; i < 6; i++)
				st[i] = state[i];
		dynsys->rhs(m, real k*0.31, st, d);
		for(i = 0; i < 3; i++)
			near(sys->sprint("%s: d%s/dt is %s", name,
				m.statenames[i], m.statenames[i+3]), d[i], st[i+3], 0.0);
	}
	case name {
	"icbmaccuracy" =>
		# an ICBM flies through an atmosphere whose density depends on
		# its own height, and its lateral motion is damped, so there is
		# no setting of its sliders that leaves plain free fall; the
		# kinematic check above is what this one gets
		;
	* =>
		checkvacuum(name, m);
	}
}

# With every parameter zeroed except the launch (speed, elevation, aim)
# and gravity, a thrown ball is in free fall: no horizontal acceleration
# at all, and a vertical one that is exactly minus gravity whatever the
# velocity happens to be.  This is the check that catches a drag or
# Magnus term that is really a constant, or one whose sign is wrong in a
# way the flight path only shows after a second.
checkvacuum(name: string, m: ref Model)
{
	gravity := -1.0;
	for(i := 0; i < len m.parameter; i++)
		case m.paramlabels[i] {
		"speed" or "elevation" or "aim" =>
			;
		"gravity" =>
			gravity = m.parameter[i];
		* =>
			m.parameter[i] = 0.0;
		}
	if(gravity < 0.0){
		fail(name+": no gravity parameter, so there is no vacuum to check");
		return;
	}
	st := dynsys->initialstate(m);
	d := array[6] of real;
	seed := 4410317;
	for(k := 0; k < 6; k++){
		if(k > 0)
			for(i = 3; i < 6; i++){
				seed = (seed*1103515245+12345)&16r7fffffff;
				st[i] = real(seed%6000)/100.0-30.0;
			}
		dynsys->rhs(m, real k*0.5, st, d);
		near(name+": vacuum downrange acceleration", d[3], 0.0, 1.0e-13);
		near(name+": vacuum lateral acceleration", d[4], 0.0, 1.0e-13);
		near(name+": vacuum vertical acceleration", d[5], -gravity, 1.0e-13);
	}
}

near(what: string, got, want, tol: real)
{
	d := got-want;
	if(d < 0.0)
		d = -d;
	if(d > tol)
		fail(sys->sprint("%s: got %.17g want %.17g", what, got, want));
}







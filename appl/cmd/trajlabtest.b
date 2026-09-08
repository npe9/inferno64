implement Trajlabtest;

# trajlabtest - check every Danby flight-path model written as a
# trajlab(2) script.
#
# The models are one file each, and the model IS the SPEC constant in
# that file, so this reads the source and tests the string that ships,
# not a copy of it that could drift.  Extracting a Limbo string constant
# is a small price for that: the alternative is a test seam in every
# model, which is the sort of thing these models were rewritten to get
# rid of.
#
# Every model: the spec parses, its state is the four values a flight
# has, the first two rates are the last two states (which is what makes
# them a position and a velocity rather than four unrelated numbers), and
# no rate is a NaN at the launch.
#
# Every model whose drag, lift and spin can be turned off also gets the
# vacuum check moved here from danbytest: with all three at zero the
# horizontal acceleration must be exactly zero and the vertical exactly
# minus gravity, which is the strongest single statement one can make
# about a ballistic model without integrating it.
#
# A default outside its own slider range is NOT an error here.  baseball
# and knuckleball are both pitched slightly downwards, so their angle is
# negative while the slider runs from zero, and that is the model as it
# ships.

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
include "trajlab.m";
	trajlab: Trajlab;
	dynsys: Dynsys;
	Model: import dynsys;

Trajlabtest: module
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
	trajlab = load Trajlab Trajlab->PATH;
	dynsys = load Dynsys Dynsys->PATH;
	if(bufio == nil || readdir == nil || numerics == nil || math == nil ||
			trajlab == nil || dynsys == nil){
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
		fail("no trajlab models found in "+DIR);
	if(bad == 0)
		sys->print("OK   %d trajlab model specs\n", checked);
	else {
		sys->print("%d failures over %d models\n", bad, checked);
		raise "fail:trajlabtest";
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
			if(strstr(line, "trajlab->run") >= 0)
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
	(m, err) := trajlab->parse(spec);
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
	checkkinematics(name, m, state, deriv);
	if(len m.parameter >= 6)
		checkvacuum(name, m);
}

# The first two states are a position and the next two its velocity, so
# the first two rates must BE the last two states, exactly.
checkkinematics(name: string, m: ref Model, state, deriv: array of real)
{
	if(deriv[0] != state[2])
		fail(sys->sprint("%s: dx/dt is %g, not vx %g", name, deriv[0], state[2]));
	if(deriv[1] != state[3])
		fail(sys->sprint("%s: dy/dt is %g, not vy %g", name, deriv[1], state[3]));
}

# Which parameter is the drag, which the lift, which the spin, and which
# the gravity - the four that have to be zeroed to fly in a vacuum.  A
# model not listed here has an air model of its own shape and is left to
# the checks above.
vacuum := array[] of {
	"badminton", "basketball", "baseballpitch", "discus", "flyball",
	"golfdrive", "javelin", "knuckleball", "projectile", "skijump",
	"softballpitch", "spinningball", "tabletennis",
};

checkvacuum(name: string, m: ref Model)
{
	found := 0;
	for(i := 0; i < len vacuum; i++)
		if(vacuum[i] == name)
			found = 1;
	if(!found)
		return;
	# parameters 2, 3 and 4 are the air: drag, lift and spin or flutter
	save := array[3] of real;
	for(i = 0; i < 3; i++){
		save[i] = m.parameter[2+i];
		m.parameter[2+i] = 0.0;
	}
	state := dynsys->initialstate(m);
	deriv := array[len state] of real;
	dynsys->rhs(m, 0.0, state, deriv);
	gravity := m.parameter[5];
	launch := math->sqrt(state[2]*state[2]+state[3]*state[3]);
	if(deriv[2] != 0.0)
		fail(sys->sprint("%s: horizontal acceleration is %g in a vacuum",
			name, deriv[2]));
	if(deriv[3] != -gravity)
		fail(sys->sprint("%s: vertical acceleration is %g in a vacuum, not -%g",
			name, deriv[3], gravity));
	d := launch-m.parameter[0];
	if(d < 0.0)
		d = -d;
	if(d > 1.0e-12)
		fail(sys->sprint("%s: launch speed %g is not the speed parameter %g",
			name, launch, m.parameter[0]));
	for(i = 0; i < 3; i++)
		m.parameter[2+i] = save[i];
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







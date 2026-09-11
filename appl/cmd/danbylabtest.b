implement Danbylabtest;

# danbylabtest - check every Danby model written as a danbylab(2) script.
#
# The models are one file each, and the model IS the SPEC constant in
# that file, so this reads the source and tests the string that ships,
# not a copy of it that could drift.  Extracting a Limbo string constant
# is a small price for that: the alternative is a test seam in every
# model, which is the sort of thing these models were rewritten to get
# rid of.
#
# Nothing here opens a window.  danbylab->parse() is deliberately the
# half of the library that needs no display, so this runs under emu-g,
# where there is no Draw and no Tk at all - which is the check worth
# having for the equations (see doc/temple-plan.md on what starting a
# demo proves).
#
# Every model gets the shared checks: it parses, it has parameters, each
# has a usable range, and no rate is a NaN at the start.  Then it gets
# its family's own, and a few named models get one written for them.

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
include "danbylab.m";
	danbylab: Danbylab;
	Config: import Danbylab;
	dynsys: Dynsys;
	Model: import dynsys;

Danbylabtest: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

DIR: con "/appl/danby";

bad := 0;
verbose := 0;
seen: array of int;

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
	danbylab = load Danbylab Danbylab->PATH;
	dynsys = load Dynsys Dynsys->PATH;
	if(bufio == nil || readdir == nil || numerics == nil || math == nil ||
			danbylab == nil || dynsys == nil){
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
	seen = array[len familynames] of {* => 0};
	checked := 0;
	for(i := 0; i < n; i++){
		name := d[i].name;
		if(len name < 6 || name[len name-5:] != ".spec")
			continue;
		spec := specof(DIR+"/"+name);
		if(spec == nil){
			fail(name+": cannot read it");
			continue;
		}
		checked++;
		checkspec(name[0:len name-5], spec);
	}
	# a family with no models left would make its checks below dead code
	# and nothing would say so
	for(i = 0; i < len seen; i++)
		if(seen[i] == 0)
			fail("no "+familynames[i]+" models found in "+DIR);
	if(bad == 0)
		sys->print("OK   %d danbylab model specs\n", checked);
	else {
		sys->print("%d failures over %d models\n", bad, checked);
		raise "fail:danbylabtest";
	}
}

familynames := array[] of {
	"mechanism", "population", "trajectory", "orbit",
	"ecology", "flight", "profile"
};

# specof: a model's spec, which is now simply the file.  This used to
# scrape a Limbo string constant out of a module and unescape it by
# hand, because that is where the spec lived; the models are text files
# in the two little languages now, so the scraper and its private
# understanding of \\n and \\t are gone.  That hack had already bitten
# once - a \\u0027 in a spec meant one thing to the compiler and another
# to the scraper, so the string under test was not the string that
# shipped.  A file cannot drift from itself.
specof(path: string): string
{
	iob := bufio->open(path, Bufio->OREAD);
	if(iob == nil)
		return nil;
	spec := "";
	while((line := iob.gets('\n')) != nil)
		spec += line;
	return spec;
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
	(m, c, err) := danbylab->parse(spec);
	if(err != nil){
		fail(name+": "+err);
		return;
	}
	seen[c.family]++;
	if(len m.parameter == 0)
		fail(name+": no param commands");
	for(i := 0; i < len m.parameter; i++){
		if(m.minima[i] >= m.maxima[i])
			fail(sys->sprint("%s: param %s range %g..%g",
				name, m.paramlabels[i], m.minima[i], m.maxima[i]));
		if(m.parameter[i] < m.minima[i] || m.parameter[i] > m.maxima[i])
			fail(sys->sprint("%s: param %s default %g outside %g..%g",
				name, m.paramlabels[i], m.parameter[i],
				m.minima[i], m.maxima[i]));
	}
	if(verbose)
		sys->print("     %s: %s, %d params, %d states\n",
			name, familynames[c.family], len m.parameter, len m.statenames);
	if(c.family == Danbylab->Profile){
		checkprofile(name, m, c);	# a profile has no state at t=0
		return;
	}
	state := dynsys->initialstate(m);
	deriv := array[len state] of real;
	dynsys->rhs(m, 0.0, state, deriv);
	for(i = 0; i < len deriv; i++)
		if(deriv[i] != deriv[i])
			fail(sys->sprint("%s: derivative %s is not a number at t=0",
				name, m.statenames[i]));
	# every check above is made at t=0, where a term that is zero there
	# and wrong later would pass.  So the families with an invariant get
	# it again at a state the model actually reaches, integrated here
	# rather than asked of the library, so what is tested is the
	# equations and not a second copy of the stepper.
	checkalongtheway(name, m, c);
	case c.family {
	Danbylab->Mechanism =>
		checkmechanism(name, m, c, state, deriv);
	Danbylab->Population =>
		checkpopulation(name, m);
	Danbylab->Trajectory =>
		checktrajectory(name, m, state, deriv);
	Danbylab->Orbit =>
		checkorbit(name, m, c, state, deriv);
	Danbylab->Ecology =>
		checkecology(name, m, c);
	Danbylab->Flight =>
		checkflight(name, m, state);
	}
}


# The families whose invariant is an identity in the equations, checked
# again after the model has been running a while.  A conserved quantity
# is a property of the right-hand side, not of the integrator, so the
# tolerance does not have to absorb the integrator's own error - only
# the size the terms have grown to.
stepping: ref Model;

steprhs(t: real, q, d: array of real)
{
	dynsys->rhs(stepping, t, q, d);
}

checkalongtheway(name: string, m: ref Model, c: ref Config)
{
	nsteps := 0;
	dt := 0.0;
	case c.family {
	Danbylab->Trajectory =>
		(nsteps, dt) = (200, 0.005);
	Danbylab->Orbit =>
		(nsteps, dt) = (400, 0.0025);
	* =>
		return;
	}
	stepping = m;
	state := dynsys->initialstate(m);
	work := numerics->workspace(len state);
	t := 0.0;
	for(i := 0; i < nsteps; i++){
		# a flat trajectory ends when it lands, and past that the
		# model is no longer describing anything
		if(c.family == Danbylab->Trajectory && state[1] < 0.0)
			break;
		numerics->rk4(work, steprhs, t, dt, state);
		t += dt;
	}
	deriv := array[len state] of real;
	dynsys->rhs(m, t, state, deriv);
	for(i = 0; i < len deriv; i++)
		if(deriv[i] != deriv[i]){
			fail(sys->sprint("%s: derivative %s is not a number at t=%g",
				name, m.statenames[i], t));
			return;
		}
	case c.family {
	Danbylab->Trajectory =>
		# the kinematic identity is exact at every state, not just the
		# one the spec starts at
		if(deriv[0] != state[2])
			fail(sys->sprint("%s: at t=%g dx/dt is %g, not vx %g",
				name, t, deriv[0], state[2]));
		if(deriv[1] != state[3])
			fail(sys->sprint("%s: at t=%g dy/dt is %g, not vy %g",
				name, t, deriv[1], state[3]));
	Danbylab->Orbit =>
		checkinternalforces(sys->sprint("%s at t=%g", name, t), m, c, deriv);
	}
}


# ------------------------------------------------------------- the mechanisms

checkmechanism(name: string, m: ref Model, c: ref Config,
		state, deriv: array of real)
{
	if(len c.links == 0)
		fail(name+": no link commands");
	points := dynsys->points(m, state);
	for(i := 0; i < len points; i++)
		if(points[i] != points[i])
			fail(sys->sprint("%s: point %d is not a number at t=0", name, i/2));
	case name {
	"slidingpendulum1" =>
		checkcartmomentum(name, m);
	"running" =>
		# the fourth state is distance, so its rate is the speed
		if(deriv[3] != state[0])
			fail(sys->sprint("%s: distance rate %g is not the speed %g",
				name, deriv[3], state[0]));
	"diving" =>
		# the diver leaves the board at the takeoff speed
		launch := math->sqrt(state[2]*state[2]+state[3]*state[3]);
		near(sys->sprint("%s: launch speed", name), launch, m.parameter[0], 1.0e-12);
	"schrodinger" =>
		checkschrodinger(name, m);
	"rabi" =>
		checkrabi(name, m);
	"hydrogen" =>
		checkhydrogen(name, m);
	"bands" =>
		checkbands(name, m);
	}
}


# ------------------------------------------------------------------- bands
#
# This model has no dynamics: it sweeps energy and evaluates a formula,
# so there is nothing to integrate and the checks are identities.
#
# The sharp one is the band edge.  At ka = n pi the sine in
# cos(ka) + P sin(ka)/(ka) vanishes exactly, so the whole thing is
# (-1)^n whatever P happens to be - those energies are band edges for
# every lattice strength there is.  It is an exact statement and it
# holds to the last few bits, which makes it a far better test than
# measuring a gap width.
#
# The control is P = 0.  With no barriers there is no lattice, the
# function is just cos(ka), and it can never leave -1..1: every energy
# is allowed and there are no gaps at all.  A model that had stopped
# depending on the strength would still pass the edge identity - (-1)^n
# does not mention P - and is caught here.

bandsat(m: ref Model, strength, lattice, e: real): (real, real)
{
	m.parameter[0] = strength;
	m.parameter[1] = lattice;
	st := dynsys->initialstate(m);
	d := array[len st] of real;
	dynsys->rhs(m, e-0.001, st, d);		# the spec's own 0.001 offset
	v := dynsys->observables(m, st);
	return (v[0], v[1]);
}

checkbands(name: string, m: ref Model)
{
	# at ka = n pi the function is exactly (-1)^n, for any P and any a
	for(pi := 0; pi < 3; pi++){
		p := 1.0 + 4.0*real pi;
		for(ai := 0; ai < 2; ai++){
			a := 1.0 + real ai;
			for(n := 1; n <= 3; n++){
				k := real n*Math->Pi/a;
				e := k*k/2.0;
				(f, nil) := bandsat(m, p, a, e);
				want := 1.0;
				if(n%2 == 1)
					want = -1.0;
				near(sys->sprint("%s: edge at ka=%d pi, P=%g a=%g", name, n, p, a),
					f, want, 1.0e-9);
			}
		}
	}
	# The edge identity above is exact and is also BLIND to most of the
	# formula: at ka = n pi the sine is zero, so the whole
	# P sin(ka)/(ka) term vanishes and the check cannot tell
	# sin(ka)/(ka) from sin(ka).  Deleting the 1/ka - which is the
	# reason gaps lose to bands as the energy rises, the entire point of
	# the model - passed every other check here.  So the function is
	# also compared against the closed form at energies where the sine
	# is NOT zero, which is what pins every term.
	for(ei := 0; ei < 6; ei++){
		p2 := 1.0 + 2.0*real (ei%3);
		a2 := 1.0 + 0.5*real (ei/3);
		e2 := 0.7 + 1.3*real ei;
		k2 := math->sqrt(2.0*e2);
		ka := k2*a2;
		want := math->cos(ka) + p2*math->sin(ka)/ka;
		if(want > 3.0 || want < -3.0)
			continue;			# the spec clamps the drawn value
		if(math->fabs(math->sin(ka)) < 0.2)
			fail(sys->sprint("%s: sample %d has sin(ka)=%g, too near a node "+
				"to test the 1/ka", name, ei, math->sin(ka)));
		(f2, nil) := bandsat(m, p2, a2, e2);
		near(sys->sprint("%s: f at E=%g, P=%g, a=%g", name, e2, p2, a2),
			f2, want, 1.0e-12);
	}

	# no barriers, no gaps: every energy allowed
	barred := 0;
	for(i := 1; i <= 400; i++){
		(nil, al) := bandsat(m, 0.0, 1.0, 0.125*real i);
		if(al < 0.5)
			barred++;
	}
	if(barred > 0)
		fail(sys->sprint("%s: with strength 0 there is no lattice, so every "+
			"energy must be allowed, but %d of 400 were not", name, barred));
	# and with barriers there really are gaps, or the control above is
	# passing because nothing is ever forbidden
	barred = 0;
	for(i = 1; i <= 400; i++){
		(nil, al) := bandsat(m, 3.0, 1.0, 0.125*real i);
		if(al < 0.5)
			barred++;
	}
	if(barred == 0)
		fail(name+": with strength 3 nothing was forbidden anywhere, so the "+
			"strength-0 check proves nothing");
	# edges go as 1/a^2: double the spacing and every edge quarters
	(f1, nil) := bandsat(m, 3.0, 2.0, (Math->Pi/2.0)*(Math->Pi/2.0)/2.0);
	near(name+": edge scales as 1/a^2", f1, -1.0, 1.0e-9);
}


# ---------------------------------------------------------------- hydrogen
#
# The only atom with an exact answer, which is what makes it worth
# testing: the bound states are at E = -Z^2/2n^2 and nowhere else, so
# the tail at the wall must come down at -0.5 and -0.125 for Z = 1 and
# must not come down a slider notch either side.
#
# Everything here runs at the step the library itself uses.  That is not
# a detail: this model's start_radius was chosen by measurement AT that
# step, because below about 0.001 the equation stiffens as 1/r faster
# than a 0.005 step can follow and the error starts growing again.  A
# test at a finer step would sail past the very thing the number was
# picked to avoid.

HYDDT: con 0.005;		# the mechanism family's own step
HYDWALL: con 20.0;		# the spec's own maxtime

hydshoot(m: ref Model, energy, charge, ell: real): real
{
	m.parameter[0] = energy;
	m.parameter[1] = charge;
	m.parameter[2] = ell;
	m.parameter[3] = 0.001;		# the spec's own start_radius
	stepping = m;
	state := dynsys->initialstate(m);
	work := numerics->workspace(len state);
	t := 0.0;
	for(i := 0; i < int (HYDWALL/HYDDT+0.5); i++){
		numerics->rk4(work, steprhs, t, HYDDT, state);
		t += HYDDT;
	}
	return state[0];
}

checkhydrogen(name: string, m: ref Model)
{
	# E = -Z^2/2n^2, so for Z=1: 1s and 2s at l=0, 2p at l=1
	levels := array[] of {-0.5, -0.125, -0.125};
	ells := array[] of {0.0, 0.0, 1.0};
	what := array[] of {"1s", "2s", "2p"};
	for(i := 0; i < len levels; i++){
		at := math->fabs(hydshoot(m, levels[i], 1.0, ells[i]));
		if(at > 0.05)
			fail(sys->sprint("%s: %s is a level but u(%g) is %g",
				name, what[i], real HYDWALL, at));
		below := math->fabs(hydshoot(m, levels[i]-0.0025, 1.0, ells[i]));
		above := math->fabs(hydshoot(m, levels[i]+0.0025, 1.0, ells[i]));
		if(below < 1.0 || above < 1.0)
			fail(sys->sprint("%s: %s off by a notch leaves u at %g and %g, "+
				"so the level check proves nothing", name, what[i], below, above));
	}
	# the Z^2 scaling: halve the charge and the ground state drops by four
	at2 := math->fabs(hydshoot(m, -0.125, 0.5, 0.0));
	if(at2 > 0.05)
		fail(sys->sprint("%s: at Z=0.5 the ground state should be -0.125, "+
			"but u(%g) is %g", name, real HYDWALL, at2));

	# the effective potential drawn in the diagram, against the formula.
	# Only the outer samples can be checked: V = -Z/r is below the -0.6
	# floor for every sample inside r = 1.667 at Z = 1, and a clamped
	# point tests the clamp and nothing about its own coefficients.
	m.parameter[1] = 1.0;
	m.parameter[2] = 0.0;
	pts := dynsys->points(m, dynsys->initialstate(m));
	for(i = 1; i <= 20; i++){
		rr := pts[2*i];
		v := -1.0/rr;			# l = 0, Z = 1
		if(v <= -0.6){
			near(sys->sprint("%s: well sample %d at r=%g clamps", name, i, rr),
				pts[2*i+1], -0.6, 1.0e-12);
			continue;
		}
		near(sys->sprint("%s: well sample %d at r=%g", name, i, rr),
			pts[2*i+1], v, 1.0e-12);
	}
	# and the centrifugal barrier really is repulsive: at l=2 the inner
	# samples must be ABOVE the l=0 ones, or the term has the wrong sign
	m.parameter[2] = 2.0;
	hi := dynsys->points(m, dynsys->initialstate(m));
	rose := 0;
	for(i = 1; i <= 20; i++)
		if(hi[2*i+1] > pts[2*i+1] + 1.0e-9)
			rose++;
	if(rose == 0)
		fail(name+": raising l did not lift the effective potential anywhere, "+
			"so the centrifugal term is not doing what the model is about");
}


# ------------------------------------------------------------ the two-level atom
#
# dR/dt = W x R is a rotation, so |R| cannot change: that is exact, it
# is a property of the equations and not of the integrator, and it is
# the one thing this model must not get wrong.  A sign slip in any of
# the three derivatives turns the rotation into something that grows or
# decays, which this catches at once.
#
# Then the physics the model exists to show.  On resonance the atom
# inverts completely - the excited fraction is sin^2(rabi t / 2) and
# reaches exactly 1 at t = pi/rabi.  Detuned, it CANNOT: the ceiling is
# rabi^2/(rabi^2 + detuning^2).  The second is the negative control for
# the first.  Without it, a model that had stopped responding to
# detuning at all would pass the resonance check and still be wrong
# about the only thing a detuning slider is for.

rabilen(st: array of real): real
{
	return math->sqrt(st[0]*st[0]+st[1]*st[1]+st[2]*st[2]);
}

# integrate to t, returning the state
rabirun(m: ref Model, rabi, detuning, w0, until: real): array of real
{
	m.parameter[0] = rabi;
	m.parameter[1] = detuning;
	m.parameter[2] = w0;
	stepping = m;
	state := dynsys->initialstate(m);
	work := numerics->workspace(len state);
	# a whole number of steps that lands EXACTLY on `until\', rather
	# than a fixed dt and however many steps that rounds to.  Stopping
	# 4e-4 past pi puts w 8e-8 below 1 - which is the cosine being
	# quadratic at its peak, not the integrator being inaccurate, and
	# it would have been absorbed by a looser tolerance and quietly
	# hidden how good rk4 actually is here
	n := 20000;
	dt := until/real n;
	t := 0.0;
	for(i := 0; i < n; i++){
		numerics->rk4(work, steprhs, t, dt, state);
		t += dt;
	}
	return state;
}

checkrabi(name: string, m: ref Model)
{
	# the rotation invariant, at a detuning that tilts the axis so all
	# three derivatives are doing something
	before := rabilen(dynsys->initialstate(m));
	st := rabirun(m, 1.0, 1.7, -1.0, 9.0);
	near(name+": |R| is conserved", rabilen(st), before, 1.0e-12);

	# on resonance the atom inverts completely at t = pi/rabi
	st = rabirun(m, 1.0, 0.0, -1.0, math->Pi);
	near(name+": resonant inversion w(pi)", st[2], 1.0, 1.0e-9);

	# the control: detuned it can never get there.  The ceiling is
	# rabi^2/(rabi^2+detuning^2), so at detuning 2 and rabi 1 the
	# excited fraction cannot pass 0.2 and w cannot pass -0.6
	(om, de) := (1.0, 2.0);
	ceiling := om*om/(om*om+de*de);
	worst := -1.0;
	for(k := 1; k <= 400; k++){
		s2 := rabirun(m, om, de, -1.0, 0.02*real k);
		excited := (1.0+s2[2])/2.0;
		if(excited > worst)
			worst = excited;
	}
	if(worst > ceiling+1.0e-6)
		fail(sys->sprint("%s: detuned by %g it reached %g excited, "+
			"above the %g ceiling", name, de, worst, ceiling));
	# and the control has to be a real constraint, not a vacuous one:
	# it must get close to the ceiling, or it is not being driven at all
	if(worst < ceiling-0.01)
		fail(sys->sprint("%s: detuned it only reached %g of a %g "+
			"ceiling, so the ceiling check proves nothing",
			name, worst, ceiling));
}


# ------------------------------------------------------- the wave equation
#
# danby/schrodinger marches in POSITION, not time, and the thing it has
# to get right is that the tail comes down at an eigenvalue and at no
# other energy.  That is the only check worth making on it, and it is
# one a spec can get wrong quietly: an expression whose precedence is
# not what it reads as still integrates, still stays finite, and still
# draws a curve.
#
# So this shoots the model the way the window does and looks at where
# the wave function has got to at the far wall, at the harmonic
# oscillator's own eigenvalues - which are exactly (n + 1/2) h-bar
# omega, and with the spec's own defaults h-bar, omega and the mass are
# all 1, so they are exactly 0.5, 1.5, 2.5 and 3.5.
#
# The negative control is the half of this that makes it a test: the
# same shot one slider notch away from each of those energies has to
# come out large.  Without it, a model whose equation was wrong but
# whose tail happened to stay small - one with the psi term dropped,
# say - would pass every line here.

SCHRODEND: con 5.0;		# the spec's own maxtime
SCHRODDT: con 0.005;		# and the mechanism family's own step

# psi at the far wall, for one energy and one parity.
schrodshoot(m: ref Model, energy, parity: real): real
{
	m.parameter[0] = energy;
	m.parameter[1] = 1.0;		# stiffness
	m.parameter[2] = 0.0;		# quartic
	m.parameter[3] = 1.0;		# mass
	m.parameter[4] = parity;
	stepping = m;
	state := dynsys->initialstate(m);
	work := numerics->workspace(len state);
	t := 0.0;
	for(i := 0; i < int (SCHRODEND/SCHRODDT+0.5); i++){
		numerics->rk4(work, steprhs, t, SCHRODDT, state);
		t += SCHRODDT;
	}
	return state[0];
}

checkschrodinger(name: string, m: ref Model)
{
	# the potential is written in eqn(7) syntax, where `quartic t sup 4`
	# is one term and `0.5 stiffness t t` is another; this is the oracle
	# for that reading, and it is the line a precedence mistake breaks
	m.parameter[0] = 0.75;		# energy
	m.parameter[1] = 1.5;		# stiffness
	m.parameter[2] = 0.25;		# quartic
	m.parameter[3] = 2.0;		# mass
	m.parameter[4] = 0.0;		# parity, even
	x := 1.25;
	st := array[] of {0.6, 0.0};
	d := array[len st] of real;
	dynsys->rhs(m, x, st, d);
	v := 0.5*1.5*x*x + 0.25*x*x*x*x;
	near(name+": psi'' at x=1.25", d[1], 2.0*2.0*(v-0.75)*st[0], 1.0e-13);
	# and psi' is the state that is called the slope
	if(d[0] != st[1])
		fail(sys->sprint("%s: dpsi/dx is %g, not the slope %g", name, d[0], st[1]));

	# even parity starts at psi=1, psi'=0 and odd at psi=0, psi'=1;
	# a slider is continuous, so what selects them is a step() of it
	m.parameter[4] = 0.0;
	e := dynsys->initialstate(m);
	near(name+": even psi(0)", e[0], 1.0, 0.0);
	near(name+": even psi'(0)", e[1], 0.0, 0.0);
	m.parameter[4] = 1.0;
	o := dynsys->initialstate(m);
	near(name+": odd psi(0)", o[0], 0.0, 0.0);
	near(name+": odd psi'(0)", o[1], 1.0, 0.0);

	# The well drawn in the diagram is a polyline of seventeen points
	# whose heights are written out as precomputed coefficients of
	# stiffness and quartic, one pair per sample.  Seventeen hand-copied
	# constants is exactly the sort of thing that rots without saying
	# so, and nothing else here would notice: a wrong coefficient draws
	# a slightly wrong well and every other check still passes.  So each
	# one is compared with the potential evaluated from scratch.
	# These two are chosen so that NOTHING clamps: 0.1x^2 + 0.002x^4 is
	# 3.75 at the outermost sample, inside the 4.5 the spec clamps at.
	# That matters more than it looks.  The obvious settings to test at
	# were stiffness 1.5 and quartic 0.25, and under those six of the
	# eight samples sit above the clamp, so their coefficients could be
	# any number at all and the comparison would still pass - which it
	# duly did when one was deliberately broken.  A clamped point tests
	# the clamp and nothing else.
	m.parameter[1] = 0.2;		# stiffness
	m.parameter[2] = 0.002;		# quartic
	pts := dynsys->points(m, dynsys->initialstate(m));
	for(j := 0; j < 17; j++){
		wx := pts[2*j];
		wv := 0.5*0.2*wx*wx + 0.002*wx*wx*wx*wx;
		if(wv >= 4.5 || wv <= -1.5)
			fail(sys->sprint("%s: well point %d clamps, so it tests "+
				"nothing about its coefficients", name, j));
		near(sys->sprint("%s: well point %d at x=%g", name, j, wx),
			pts[2*j+1], wv, 1.0e-12);
	}
	# and then the clamp itself, at a well steep enough to need it
	m.parameter[1] = 4.0;
	m.parameter[2] = 1.0;
	cl := dynsys->points(m, dynsys->initialstate(m));
	near(name+": well clamps high at the rim", cl[2*16+1], 4.5, 1.0e-12);
	m.parameter[1] = -4.0;
	m.parameter[2] = 0.0;
	cl = dynsys->points(m, dynsys->initialstate(m));
	near(name+": well clamps low when inverted", cl[2*16+1], -1.5, 1.0e-12);
	m.parameter[1] = 0.2;
	m.parameter[2] = 0.002;
	# and the polyline has to be in order and symmetric, or it is a
	# scribble rather than a well
	for(j = 1; j < 17; j++)
		if(pts[2*j] <= pts[2*(j-1)])
			fail(sys->sprint("%s: well point %d at x=%g is not right of %g",
				name, j, pts[2*j], pts[2*(j-1)]));
	for(j = 0; j < 8; j++)
		near(sys->sprint("%s: well is symmetric at x=%g", name, pts[2*(16-j)]),
			pts[2*(16-j)+1], pts[2*j+1], 1.0e-12);

	# the eigenvalues themselves, alternating even and odd, each with
	# its own negative control one slider notch (0.025) to either side
	levels := array[] of {0.5, 1.5, 2.5, 3.5};
	for(i := 0; i < len levels; i++){
		parity := real (i%2);
		at := math->fabs(schrodshoot(m, levels[i], parity));
		if(at > 1.0e-3)
			fail(sys->sprint("%s: E=%g is an eigenvalue but psi(%g) is %g",
				name, levels[i], real SCHRODEND, at));
		below := math->fabs(schrodshoot(m, levels[i]-0.025, parity));
		above := math->fabs(schrodshoot(m, levels[i]+0.025, parity));
		# the control: if these were small too, the line above would
		# be passing on a model that had stopped being sensitive to
		# the energy at all
		if(below < 1.0 || above < 1.0)
			fail(sys->sprint("%s: E=%g off by one notch leaves psi(%g) at "+
				"%g and %g, so the eigenvalue check proves nothing",
				name, levels[i], real SCHRODEND, below, above));
	}
}

mom: ref Model;

momrhs(t: real, state, derivative: array of real)
{
	dynsys->rhs(mom, t, state, derivative);
}

# The support is free, so (M+m)x' + m*l*th'*cos(th) is a first integral -
# the hinge damper is an internal couple and takes nothing out of it.
# Dropping its reaction on the support, which is what cartpendulum.b did
# until 242e399d, drifts this by about 6e-2 over the same run.
checkcartmomentum(name: string, m: ref Model)
{
	mom = m;
	p := m.parameter;
	total := p[0]+p[1];
	mass := p[1];
	length := p[2];
	if(p[5] <= 0.0){
		fail(name+": hinge damping is zero, so this check proves nothing");
		return;
	}
	state := dynsys->initialstate(m);
	work := numerics->workspace(len state);
	before := total*state[1]+mass*length*state[3]*math->cos(state[2]);
	t := 0.0;
	for(i := 0; i < 30000; i++){
		numerics->rk4(work, momrhs, t, 0.001, state);
		t += 0.001;
	}
	after := total*state[1]+mass*length*state[3]*math->cos(state[2]);
	near(name+": horizontal momentum", after, before, 1.0e-10);
}


# ------------------------------------------------------------ the populations

checkpopulation(name: string, m: ref Model)
{
	checkstates(name, m);
	case name {
	"lanchester" =>
		# the square law: b*A^2 - a*B^2 does not change
		st := array[] of {0.9, 0.7};
		d := rates(m, st);
		p := m.parameter;
		near(name+" square-law invariant",
			2.0*p[1]*st[0]*d[0] - 2.0*p[0]*st[1]*d[1], 0.0, 1.0e-14);
	"productionexchange" =>
		# exchange only moves goods between the two, so the total
		# changes only by what is produced less what is used
		st := array[] of {0.8, 0.3};
		d := rates(m, st);
		p := m.parameter;
		near(name+" conserves transferred goods", d[0]+d[1],
			p[0]+p[2]-p[1]*st[0]-p[3]*st[1], 1.0e-14);
	"gonorrhea" =>
		st := array[] of {0.8, 0.2, 0.7, 0.3};
		d := rates(m, st);
		near(name+" women conservation", d[0]+d[1], 0.0, 1.0e-14);
		near(name+" men conservation", d[2]+d[3], 0.0, 1.0e-14);
	"malaria" =>
		st := array[] of {0.8, 0.1, 0.7, 0.2};
		d := rates(m, st);
		near(name+" human conservation", d[0]+d[1], 0.0, 1.0e-14);
		near(name+" mosquito conservation", d[2]+d[3], 0.0, 1.0e-14);
	"incubation" =>
		st := array[] of {0.8, 0.1, 0.7, 0.2};
		d := rates(m, st);
		near(name+" SEIR conservation", d[0]+d[1]+d[2]+d[3], 0.0, 1.0e-14);
	"seasonaldisease" or "migration" =>
		st := array[] of {0.8, 0.15, 0.05};
		d := rates(m, st);
		near(name+" head-count conservation", d[0]+d[1]+d[2], 0.0, 1.0e-14);
	"weightchange" =>
		# a body of no mass spends nothing, so its rate is the whole
		# intake divided by the energy density
		st := array[] of {0.0};
		d := rates(m, st);
		p := m.parameter;
		near(name+" zero-mass energy balance", d[0], p[0]/p[3], 1.0e-14);
	"lakepollution" =>
		# at the steady state the inflow exactly balances what leaves
		# by the outlet and what decays
		p := m.parameter;
		st := array[] of {(p[0]/p[1])/(p[2]/p[1]+p[3])};
		d := rates(m, st);
		near(name+" mass balance", d[0], 0.0, 1.0e-12);
	"childcare" =>
		checkempty(name, m);
	"diseasebirthdeath1" =>
		# births balance deaths exactly, so the head count is a first
		# integral: the three rates must sum to zero
		checksum(name, m, 0.0);
	"diseasebirthdeath2" =>
		# births, deaths and virulence are independent, so the head
		# count changes at (birth - natural death) less what the disease
		# kills, at the same state checksum uses below
		p := m.parameter;
		checksum(name, m, (p[2]-p[3])-p[4]*0.15);
	"fishingone" =>
		checkfishery(name, m);
	}
}

# At the bionomic equilibrium - the stock at which the price of a catch
# just covers its cost, and the effort that holds the stock there -
# nothing moves.
checkfishery(name: string, m: ref Model)
{
	p := m.parameter;
	stock := p[4]/(p[3]*p[2]);
	effort := p[0]*(1.0-stock/p[1])/p[2];
	state := array[] of {stock, effort};
	deriv := array[len state] of real;
	dynsys->rhs(m, 0.0, state, deriv);
	for(i := 0; i < len deriv; i++)
		near(sys->sprint("%s: d%s/dt at the bionomic equilibrium",
			name, m.statenames[i]), deriv[i], 0.0, 1.0e-12);
}

checksum(name: string, m: ref Model, want: real)
{
	state := dynsys->initialstate(m);
	# the same state danbytest used, so the numbers are comparable
	if(len state == 3){
		state[0] = 0.8;
		state[1] = 0.15;
		state[2] = 0.05;
	}
	deriv := array[len state] of real;
	dynsys->rhs(m, 0.0, state, deriv);
	total := 0.0;
	for(i := 0; i < len deriv; i++)
		total += deriv[i];
	near(name+": the rates sum", total, want, 1.0e-14);
}

# An empty population stays empty: with every state at zero, every rate
# is zero.  A model whose growth term is not proportional to a population
# would fail this, which is the point of asking.
checkempty(name: string, m: ref Model)
{
	state := array[len m.statenames] of {* => 0.0};
	deriv := array[len state] of real;
	dynsys->rhs(m, 0.0, state, deriv);
	for(i := 0; i < len deriv; i++)
		if(deriv[i] != 0.0)
			fail(sys->sprint("%s: d%s/dt is %g with every population at zero",
				name, m.statenames[i], deriv[i]));
}

# Every population model's own state count, which is what its curriculum
# page describes and what danbytest used to assert one call at a time.
statecounts := array[] of {
	"brusselator", "2",
	"budworm", "1",
	"cannibalism", "2",
	"changingenvironment", "1",
	"childcare", "3",
	"crossinfection", "4",
	"decomposition", "3",
	"diseasebirthdeath1", "3",
	"diseasebirthdeath2", "3",
	"enzymeapplication", "6",
	"enzymekinetics", "4",
	"fishingone", "2",
	"fishingtwo", "3",
	"foodchain", "3",
	"gonorrhea", "4",
	"heliumburning", "4",
	"hiv", "3",
	"incubation", "4",
	"lakepollution", "1",
	"lanchester", "2",
	"limitstogrowth", "4",
	"malaria", "4",
	"manyspecies", "3",
	"migration", "3",
	"moreenzyme", "4",
	"oregonator", "3",
	"parasite", "2",
	"productionexchange", "2",
	"reactorstability", "2",
	"reservoir", "3",
	"seasonaldisease", "3",
	"stillmoreenzyme", "5",
	"tankcontrol", "4",
	"twocapital", "2",
	"violetsantsrodents", "3",
	"weightchange", "1",
};

checkstates(name: string, m: ref Model)
{
	for(i := 0; i+1 < len statecounts; i += 2)
		if(statecounts[i] == name){
			want := int statecounts[i+1];
			if(len m.statenames != want)
				fail(sys->sprint("%s: %d states, expected %d",
					name, len m.statenames, want));
			return;
		}
}


# ------------------------------------------------------------ the trajectories

checktrajectory(name: string, m: ref Model, state, deriv: array of real)
{
	# the first two states are a position and the next two its velocity,
	# so the first two rates must BE the last two states, exactly
	if(deriv[0] != state[2])
		fail(sys->sprint("%s: dx/dt is %g, not vx %g", name, deriv[0], state[2]));
	if(deriv[1] != state[3])
		fail(sys->sprint("%s: dy/dt is %g, not vy %g", name, deriv[1], state[3]));
	if(len m.parameter >= 6)
		checkflatvacuum(name, m);
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

checkflatvacuum(name: string, m: ref Model)
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
	near(sys->sprint("%s: launch speed", name), launch, m.parameter[0], 1.0e-12);
	for(i = 0; i < 3; i++)
		m.parameter[2+i] = save[i];
}


# ------------------------------------------------------------------ the orbits

# Four states per body, the first two rates of each body being its own
# velocity components; and the one that matters: gravity between bodies
# is an internal force, so the total momentum cannot change.  Summing
# mass times acceleration over every body must give zero - which it does
# for the models with an external term too, because in those the body
# being pushed has zero mass and the one being held fixed has zero
# acceleration.  That check came from danbytest and is the reason this
# family is worth testing at all: it catches a sign error or a missing
# reaction in any one of up to fifteen pairs.
checkorbit(name: string, m: ref Model, c: ref Config, state, deriv: array of real)
{
	for(i := 0; i < len c.bodies; i++){
		if(deriv[4*i] != state[4*i+2])
			fail(sys->sprint("%s: body %s: dx/dt is %g, not vx %g",
				name, c.bodies[i], deriv[4*i], state[4*i+2]));
		if(deriv[4*i+1] != state[4*i+3])
			fail(sys->sprint("%s: body %s: dy/dt is %g, not vy %g",
				name, c.bodies[i], deriv[4*i+1], state[4*i+3]));
	}
	checkinternalforces(name, m, c, deriv);
}

# Sum m*a over every body.  The residual is compared against the size of
# the largest term rather than against a fixed number, because a body
# that has fallen close to another has a large acceleration and a
# proportionally large rounding error in a sum that is still exactly zero
# in exact arithmetic.
checkinternalforces(name: string, m: ref Model, c: ref Config, deriv: array of real)
{
	mass := danbylab->masses(m, c);
	(px, py) := (0.0, 0.0);
	biggest := 1.0;
	for(i := 0; i < len mass; i++){
		(fx, fy) := (mass[i]*deriv[4*i+2], mass[i]*deriv[4*i+3]);
		px += fx;
		py += fy;
		if(absreal(fx) > biggest)
			biggest = absreal(fx);
		if(absreal(fy) > biggest)
			biggest = absreal(fy);
	}
	tol := 1.0e-11*biggest;
	near(name+": the internal forces in x", px, 0.0, tol);
	near(name+": the internal forces in y", py, 0.0, tol);
}

absreal(x: real): real
{
	if(x < 0.0)
		return -x;
	return x;
}


# --------------------------------------------------------------- the ecologies

checkecology(name: string, m: ref Model, c: ref Config)
{
	case name {
	"periodicvolterra" =>
		# the declared fixed point is the mean one: moving at t=0,
		# still a quarter period later
		(ex, ey) := danbylab->equilibrium(m, c);
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
		near(name+" zero-prey boundary", d[1], -m.parameter[4]*st[1], 1.0e-12);
	* =>
		checkatrest(name, m, c);
	}
}

# The equilibrium the spec declares must be one: both rates zero there.
checkatrest(name: string, m: ref Model, c: ref Config)
{
	(ex, ey) := danbylab->equilibrium(m, c);
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


# ------------------------------------------------------------ the 3d flights

checkflight(name: string, m: ref Model, state: array of real)
{
	# the kinematic identity, at the start and at eleven pseudo-random
	# states: a position's rate is its own velocity and nothing else
	seed := 7717321;
	st := array[6] of real;
	d := array[6] of real;
	for(k := 0; k < 12; k++){
		for(i := 0; i < 6; i++){
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
	# an ICBM flies through an atmosphere whose density depends on its
	# own height, and its lateral motion is damped, so there is no
	# setting of its sliders that leaves plain free fall; the kinematic
	# check above is what that one gets
	if(name != "icbmaccuracy")
		checkfreefall(name, m);
}

# With every parameter zeroed except the launch (speed, elevation, aim)
# and gravity, a thrown ball is in free fall: no horizontal acceleration
# at all, and a vertical one that is exactly minus gravity whatever the
# velocity happens to be.  This is the check that catches a drag or
# Magnus term that is really a constant, or one whose sign is wrong in a
# way the flight path only shows after a second.
checkfreefall(name: string, m: ref Model)
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


# ----------------------------------------------------------------- the profiles

# danbylab does not insist on a normalise line - a spec could
# legitimately draw two curves that are already comparable - but every
# model in THIS family plots an enclosed mass against a density
# fraction, and one that forgot to normalise would put an absolute mass
# on the same axis as a number that never leaves 0..1, so the second
# curve would be a flat line along the bottom or the first would be.
checkprofile(name: string, m: ref Model, c: ref Config)
{
	if(len m.observablelabels != 2)
		fail(sys->sprint("%s: %d curves, not two", name, len m.observablelabels));
	if(c.normalised < 0)
		fail(name+": no normalise line, so one curve is an absolute quantity "+
			"sharing an axis with a fraction");
	if(verbose)
		sys->print("     %s: %d samples, normalising %d\n",
			name, c.samples, c.normalised);
	seed := 3312551;
	for(k := 0; k < 12; k++){
		i := 0;
		if(k > 0)
			for(i = 0; i < len m.parameter; i++){
				seed = (seed*1103515245+12345)&16r7fffffff;
				m.parameter[i] = m.minima[i]+
					(m.maxima[i]-m.minima[i])*real(seed%1000)/1000.0;
			}
		d := danbylab->march(m, c);
		what := sys->sprint("%s[%d]", name, k);
		for(i = 0; i < 3*c.samples; i++)
			if(d[i] != d[i]){
				fail(what+": sample "+string (i/3)+" is not a number");
				break;
			}
		# the radius only ever increases, and neither curve is negative:
		# a density is a density and a mass is a mass
		for(i = 1; i < c.samples; i++)
			if(d[3*i] <= d[3*(i-1)]){
				fail(sys->sprint("%s: radius does not increase at sample %d",
					what, i));
				break;
			}
		for(i = 0; i < c.samples; i++)
			if(d[3*i+1] < 0.0 || d[3*i+2] < 0.0){
				fail(sys->sprint("%s: negative value at sample %d, %.17g and %.17g",
					what, i, d[3*i+1], d[3*i+2]));
				break;
			}
		# the enclosed mass never falls: a shell of non-negative density
		# can only add to it
		mass := 1;
		if(c.normalised >= 0)
			mass = c.normalised;
		for(i = 1; i < c.samples; i++)
			if(d[3*i+1+mass] < d[3*(i-1)+1+mass]-1.0e-12){
				fail(sys->sprint("%s: %s falls at sample %d, %.17g then %.17g",
					what, m.observablelabels[mass], i,
					d[3*(i-1)+1+mass], d[3*i+1+mass]));
				break;
			}
		# and the outermost sample of the normalised curve is exactly
		# the 1 it was divided by
		if(c.normalised >= 0 && d[3*(c.samples-1)+1+c.normalised] != 0.0)
			near(what+": "+m.observablelabels[c.normalised]+" at the outer edge",
				d[3*(c.samples-1)+1+c.normalised], 1.0, 0.0);
	}
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

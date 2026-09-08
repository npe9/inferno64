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
		if(len name < 3 || name[len name-2:] != ".b")
			continue;
		spec := specof(DIR+"/"+name);
		if(spec == nil)
			continue;
		checked++;
		checkspec(name[0:len name-2], spec);
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

# specof: the SPEC constant of a danbylab model, or nil if this file is
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
			if(strstr(line, "danbylab->run") >= 0)
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

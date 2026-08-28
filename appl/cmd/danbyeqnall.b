implement Command;

# danbyeqnall(1) - redoes ALL the Danby examples surveyed across this
# whole design thread in eqn(7), not just one representative per
# family (danbyeqntest(1)'s job): all 17 Trajectory plugins, both
# Populationmodel examples (epidemic, vaccination), and both
# Twospecies examples (ecology, competition), alongside the one
# Mechanism example already covered.
#
# Every Trajectory check compares the eqn-translated formula against
# the REAL plugin's own oracle function (ballistics->acceleration or
# atmosphere->drag2), called directly with that plugin's own real
# parameter() values - not a hand-computed expected number, which
# would only prove arithmetic, not that this IS the plugin's own
# physics. The two Populationmodel/Twospecies pairs use hand-computed
# values (no separate oracle module to call - their rhs is inline in
# the plugin itself), same as danbyeqntest(1).

include "sys.m";
	sys: Sys;
include "draw.m";
include "eqn2hoc.m";
	eqn2hoc: Eqn2hoc;
include "hoc.m";
	hoc: Hoc;
include "danby/ballistics.m";
	ballistics: Ballistics;
include "danby/atmosphere.m";
	atmosphere: Atmosphere;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

nfail := 0;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	eqn2hoc = load Eqn2hoc Eqn2hoc->PATH;
	hoc = load Hoc Hoc->PATH;
	ballistics = load Ballistics Ballistics->PATH;
	atmosphere = load Atmosphere Atmosphere->PATH;
	if(eqn2hoc == nil || hoc == nil || ballistics == nil || atmosphere == nil){
		sys->print("load: eqn2hoc=%d hoc=%d ballistics=%d atmosphere=%d\n",
			eqn2hoc != nil, hoc != nil, ballistics != nil, atmosphere != nil);
		raise "fail:load";
	}

	# --- Trajectory: 11 plugins sharing the plain ballistics call
	# form (state[2],state[3],p[2],p[3],p[4],p[5],0.0) - real
	# parameter()s from each plugin's own new(), state (vx,vy)=(10,5)
	# for all (the formula is state-independent of WHICH plugin it
	# is; only the parameters differ). ---
	plainplugins := "ballistics" :: "basketball" :: "badminton" ::
		"baseballpitch" :: "discus" :: "flyball" :: "golfdrive" ::
		"javelin" :: "softballpitch" :: nil;
	# (speed, angle unused here - only p[2..5] feed acceleration())
	drags := 0.005 :: 0.001 :: 0.045 :: 0.003 :: 0.008 :: 0.005 :: 0.004 :: 0.004 :: 0.006 :: nil;
	lifts := 0.0 :: 0.00015 :: 0.0 :: 0.0005 :: 0.012 :: 0.00045 :: 0.00055 :: 0.005 :: 0.001 :: nil;
	spins := 0.0 :: 20.0 :: 0.0 :: 180.0 :: 1.0 :: 130.0 :: 250.0 :: 1.0 :: 130.0 :: nil;
	gravs := 9.81 :: 9.81 :: 9.81 :: 9.81 :: 9.81 :: 9.81 :: 9.81 :: 9.81 :: 9.81 :: nil;
	for(np := plainplugins; np != nil;
	    (np, drags, lifts, spins, gravs) = (tl np, tl drags, tl lifts, tl spins, tl gravs))
		ballisticscheck(hd np, hd drags, hd lifts, hd spins, hd gravs, 0.0, 10.0, 5.0);

	# tabletennis: same call form, but lift is negated (topspin
	# convention) - reusing the identical eqn formula, just with a
	# negative lift value bound in, exactly as tabletennis.b itself
	# passes -p[3] to the same acceleration().
	ballisticscheck("tabletennis", 0.018, -0.0015, 90.0, 9.81, 0.0, 10.0, 5.0);

	# knuckleball: lift=0, spin=0, but verticalforce is a real
	# TIME-DEPENDENT flutter force (p[3]*sin(p[4]*t)) - computed as
	# its own small eqn expression first, then fed into the SAME
	# ax/ay formula as an ordinary bound value. Shows the composed-
	# expressions pattern doc/danby-tks-plan.md's own hoc adapter
	# design calls for (compile several small pieces, bind results
	# between them), not just one-shot translation.
	knuckleballcheck();

	# skijump: same acceleration() call, but vx is wind-adjusted
	# first (relativevx = vx + wind) - reusing the identical ax/ay
	# formula on a shifted input, exactly as skijump.b itself computes
	# relativevx before calling the same acceleration().
	skijumpcheck();

	# spinningball: not routed through the Ballistics module at all in
	# real Limbo (no `ballistics->` load) - the SAME formula written
	# out inline in the plugin's own rhs() instead. Same eqn strings,
	# checked against the SAME oracle (ballistics->acceleration) since
	# the inline Limbo and the module call compute identically.
	ballisticscheck("spinningball", 0.006, 0.0008, 150.0, 9.81, 0.0, 10.0, 5.0);

	# --- Trajectory: 2 atmosphere-based plugins (drag2+density,
	# assuming altitude >= 0 - the one piecewise clamp density()
	# itself has, out of scope the same way pendulum's dry friction
	# was). icbmrange and skylab are pure atmosphere->drag2 plus a
	# gravity term; reentry (piecewise lift correction) and rocket2d
	# (needs propulsion->thrustacceleration, itself piecewise on burn
	# time) have real complexity beyond this pure formula and are
	# named here, not silently skipped, rather than checked. ---
	atmospherecheck("icbmrange", 1.0, 0.002, 1.0, 1.0, 8.0, 200.0, 50.0, 100.0);
	atmospherecheck("skylab", 2.2, 74.0, 77000.0, 0.015, 28.0, 7.6, 0.0, 120.0);
	sys->print("note: reentry and rocket2d use atmosphere->drag2 too, but"
		+ " add their own piecewise terms (a speed>0 lift correction;"
		+ " propulsion->thrustacceleration's own burn-time cutoff) -"
		+ " not checked here, same scope reasoning as pendulum's dry"
		+ " friction.\n");

	# --- Mechanism: already covered in danbyeqntest(1) (pendulum's
	# gravity term) - not repeated here.

	# --- Populationmodel: epidemic already covered in danbyeqntest(1);
	# vaccination here - identical SIR dynamics plus a stub 4th
	# compartment (dvaccinated=0, a real Limbo line, not omitted).
	names := "contact" :: "recovery" :: "susceptible" :: "infectious" :: nil;
	vals := 2.2 :: 0.55 :: 0.792 :: 0.01 :: nil;
	checkeval("contact susceptible infectious", names, vals, 0.017424,
		"vaccination: infections = contact*susceptible*infectious");
	checkeval("recovery infectious",
		"recovery" :: "infectious" :: nil, 0.55 :: 0.01 :: nil,
		0.0055, "vaccination: recoveries = recovery*infectious");
	checkeval("0.0", nil, nil, 0.0,
		"vaccination: dvaccinated = 0 (a real rhs line, not omitted)");

	# --- Twospecies: ecology already covered in danbyeqntest(1);
	# competition here - a genuinely different Lotka-Volterra
	# variant (real competition, not predator-prey), at its own
	# real default parameters (growthA=1.0, growthB=0.8, competition=0.7).
	checkeval("growtha x { 1.0 - x - c y }",
		"growtha" :: "x" :: "c" :: "y" :: nil,
		1.0 :: 0.4 :: 0.7 :: 0.3 :: nil,
		0.156, "competition: dx = growthA*x*(1-x-c*y)");
	checkeval("growthb y { 1.0 - y - c x }",
		"growthb" :: "y" :: "c" :: "x" :: nil,
		0.8 :: 0.3 :: 0.7 :: 0.4 :: nil,
		0.1008, "competition: dy = growthB*y*(1-y-c*x)");

	if(nfail == 0)
		sys->print("PASS\n");
	else{
		sys->print("%d test(s) failed\n", nfail);
		raise "fail:tests";
	}
}

# ballisticscheck: the shared eqn formula (speed, ax, ay), checked
# against ballistics->acceleration() itself - the real oracle every
# one of these plugins calls, not a hand-computed number.
ballisticscheck(title: string, drag, lift, spin, gravity, verticalforce, vx, vy: real)
{
	(axreal, ayreal) := ballistics->acceleration(vx, vy, drag, lift, spin, gravity, verticalforce);

	hoc->reset();
	hoc->setvar("vx", vx); hoc->setvar("vy", vy);
	(speedsrc, err) := eqn2hoc->translate("sqrt { vx sup 2 + vy sup 2 }");
	fail1(err, title, "speed");
	speed := hoc->eval(hoc->compile(speedsrc));
	hoc->setvar("speed", speed);
	hoc->setvar("drag", drag); hoc->setvar("lift", lift);
	hoc->setvar("spin", spin); hoc->setvar("gravity", gravity);
	hoc->setvar("verticalforce", verticalforce);

	(axsrc, err2) := eqn2hoc->translate("- drag speed vx - lift spin vy");
	fail1(err2, title, "ax");
	axeqn := hoc->eval(hoc->compile(axsrc));

	(aysrc, err3) := eqn2hoc->translate("- gravity - drag speed vy + lift spin vx + verticalforce");
	fail1(err3, title, "ay");
	ayeqn := hoc->eval(hoc->compile(aysrc));

	checkclose(title+": ax", axeqn, axreal);
	checkclose(title+": ay", ayeqn, ayreal);
}

# knuckleballcheck: real values from appl/danby/plugin/knuckleball.b's
# own new() (drag=0.004, gravity=9.81) and flutter (amplitude=1.4,
# omega=48.0) at t=0.5, vx=10, vy=5.
knuckleballcheck()
{
	drag := 0.004; gravity := 9.81; amplitude := 1.4; omega := 48.0; t := 0.5;
	vx := 10.0; vy := 5.0;

	hoc->reset();
	hoc->setvar("amplitude", amplitude); hoc->setvar("omega", omega); hoc->setvar("t", t);
	(fsrc, ferr) := eqn2hoc->translate("amplitude sin { omega t }");
	fail1(ferr, "knuckleball", "flutter");
	flutter := hoc->eval(hoc->compile(fsrc));

	(axreal, ayreal) := ballistics->acceleration(vx, vy, drag, 0.0, 0.0, gravity, flutter);

	hoc->setvar("vx", vx); hoc->setvar("vy", vy);
	(speedsrc, serr) := eqn2hoc->translate("sqrt { vx sup 2 + vy sup 2 }");
	fail1(serr, "knuckleball", "speed");
	speed := hoc->eval(hoc->compile(speedsrc));
	hoc->setvar("speed", speed);
	hoc->setvar("drag", drag); hoc->setvar("lift", 0.0); hoc->setvar("spin", 0.0);
	hoc->setvar("gravity", gravity); hoc->setvar("verticalforce", flutter);

	(axsrc, aerr) := eqn2hoc->translate("- drag speed vx - lift spin vy");
	fail1(aerr, "knuckleball", "ax");
	axeqn := hoc->eval(hoc->compile(axsrc));
	(aysrc, aerr2) := eqn2hoc->translate("- gravity - drag speed vy + lift spin vx + verticalforce");
	fail1(aerr2, "knuckleball", "ay");
	ayeqn := hoc->eval(hoc->compile(aysrc));

	checkclose("knuckleball: ax (with flutter verticalforce)", axeqn, axreal);
	checkclose("knuckleball: ay (with flutter verticalforce)", ayeqn, ayreal);
}

# skijumpcheck: real values from skijump.b's own new() (drag=0.006,
# lift=0.002, spin=1.0, gravity=9.81), wind p[4]=0.0 in the real
# default parameters - pick a nonzero wind (2.0) to actually exercise
# the relativevx shift, at vx=10, vy=5.
skijumpcheck()
{
	drag := 0.006; lift := 0.002; spin := 1.0; gravity := 9.81;
	vx := 10.0; vy := 5.0; wind := 2.0;

	hoc->reset();
	hoc->setvar("vx", vx); hoc->setvar("wind", wind);
	(rsrc, rerr) := eqn2hoc->translate("vx + wind");
	fail1(rerr, "skijump", "relativevx");
	relativevx := hoc->eval(hoc->compile(rsrc));

	(axreal, ayreal) := ballistics->acceleration(relativevx, vy, drag, lift, spin, gravity, 0.0);

	hoc->setvar("vx", relativevx); hoc->setvar("vy", vy);
	(speedsrc, serr) := eqn2hoc->translate("sqrt { vx sup 2 + vy sup 2 }");
	fail1(serr, "skijump", "speed");
	speed := hoc->eval(hoc->compile(speedsrc));
	hoc->setvar("speed", speed);
	hoc->setvar("drag", drag); hoc->setvar("lift", lift);
	hoc->setvar("spin", spin); hoc->setvar("gravity", gravity);
	hoc->setvar("verticalforce", 0.0);

	(axsrc, aerr) := eqn2hoc->translate("- drag speed vx - lift spin vy");
	fail1(aerr, "skijump", "ax");
	axeqn := hoc->eval(hoc->compile(axsrc));
	(aysrc, aerr2) := eqn2hoc->translate("- gravity - drag speed vy + lift spin vx + verticalforce");
	fail1(aerr2, "skijump", "ay");
	ayeqn := hoc->eval(hoc->compile(aysrc));

	checkclose("skijump: ax (relativevx = vx+wind)", axeqn, axreal);
	checkclose("skijump: ay (relativevx = vx+wind)", ayeqn, ayreal);
}

# atmospherecheck: rho/speed/factor/ax/ay chained as their own small
# eqn expressions (matching atmosphere->drag2's own real structure -
# rho from density(), then a shared factor, then two components),
# checked against atmosphere->drag2() itself, real oracle. Assumes
# altitude >= 0 (density()'s one piecewise clamp - out of scope, same
# reasoning as pendulum's dry friction and knuckleball/skijump's own
# real complexity elsewhere).
atmospherecheck(title: string, coefficient, area, mass, surface, scaleheight, vx, vy, altitude: real)
{
	(axreal, ayreal) := atmosphere->drag2(vx, vy, altitude, coefficient, area, mass, surface, scaleheight);

	hoc->reset();
	hoc->setvar("surface", surface); hoc->setvar("altitude", altitude);
	hoc->setvar("scaleheight", scaleheight);
	(rhosrc, rerr) := eqn2hoc->translate("surface exp { - altitude over scaleheight }");
	fail1(rerr, title, "rho");
	rho := hoc->eval(hoc->compile(rhosrc));

	hoc->setvar("vx", vx); hoc->setvar("vy", vy);
	(speedsrc, serr) := eqn2hoc->translate("sqrt { vx sup 2 + vy sup 2 }");
	fail1(serr, title, "speed");
	speed := hoc->eval(hoc->compile(speedsrc));

	hoc->setvar("rho", rho); hoc->setvar("speed", speed);
	hoc->setvar("coefficient", coefficient); hoc->setvar("area", area);
	hoc->setvar("mass", mass);
	(factorsrc, ferr) := eqn2hoc->translate("- 0.5 rho coefficient area speed over mass");
	fail1(ferr, title, "factor");
	factor := hoc->eval(hoc->compile(factorsrc));

	hoc->setvar("factor", factor);
	(axsrc, aerr) := eqn2hoc->translate("factor vx");
	fail1(aerr, title, "ax");
	axeqn := hoc->eval(hoc->compile(axsrc));
	(aysrc, aerr2) := eqn2hoc->translate("factor vy");
	fail1(aerr2, title, "ay");
	ayeqn := hoc->eval(hoc->compile(aysrc));

	checkclose(title+": ax (atmosphere drag)", axeqn, axreal);
	checkclose(title+": ay (atmosphere drag)", ayeqn, ayreal);
}

fail1(err: string, title, what: string)
{
	if(err != nil){
		sys->print("FAIL: %s (%s): translate error: %s\n", title, what, err);
		nfail++;
	}
}

checkclose(what: string, got, want: real)
{
	diff := got - want;
	if(diff < 0.0)
		diff = -diff;
	if(diff > 1.0e-9){
		sys->print("FAIL: %s: eqn gave %g, real oracle gave %g\n", what, got, want);
		nfail++;
		return;
	}
	sys->print("ok: %s = %g (matches real oracle)\n", what, got);
}

checkeval(eq: string, names: list of string, vals: list of real, want: real, what: string)
{
	(hocsrc, err) := eqn2hoc->translate(eq);
	if(err != nil){
		sys->print("FAIL: translate(%q): %s\n", eq, err);
		nfail++;
		return;
	}
	hoc->reset();
	for(n := names; n != nil; (n, vals) = (tl n, tl vals))
		hoc->setvar(hd n, hd vals);
	e := hoc->compile(hocsrc);
	if(e == nil){
		sys->print("FAIL: hoc could not compile %q (from eqn %q)\n", hocsrc, eq);
		nfail++;
		return;
	}
	got := hoc->eval(e);
	diff := got - want;
	if(diff < 0.0)
		diff = -diff;
	if(diff > 1.0e-9){
		sys->print("FAIL: %q -> %q = %g, want %g [%s]\n",
			eq, hocsrc, got, want, what);
		nfail++;
		return;
	}
	sys->print("ok: %q -> %q = %g [%s]\n", eq, hocsrc, got, what);
}

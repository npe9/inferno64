implement Command;

# danbyeqntest(1) - the Danby models doc/danby-tks-plan.md already
# verified as plain hoc(2) arithmetic (ballistics->acceleration,
# epidemic.b's SIR rhs), plus two more real families, written this
# time as eqn(7) strings and pushed through eqn2hoc(2) instead of
# typed directly as hoc infix syntax - checked against the SAME real
# Limbo formulas they would replace, not just against eqn2hoc(2)'s own
# synthetic test coverage. If a real physics formula, written the way
# someone reading the printed equation would actually write it,
# doesn't come out through eqn2hoc+hoc with the right number, the
# whole "author Danby models in eqn notation" idea doesn't hold up.

include "sys.m";
	sys: Sys;
include "draw.m";
include "eqn2hoc.m";
	eqn2hoc: Eqn2hoc;
include "hoc.m";
	hoc: Hoc;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

nfail := 0;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	eqn2hoc = load Eqn2hoc Eqn2hoc->PATH;
	hoc = load Hoc Hoc->PATH;
	if(eqn2hoc == nil || hoc == nil){
		sys->print("load: eqn2hoc=%d hoc=%d\n", eqn2hoc != nil, hoc != nil);
		raise "fail:load";
	}

	# --- Trajectory family: appl/danby/ballistics.b's own
	# acceleration(), real drag+lift projectile physics, both
	# components - the formula doc/danby-tks-plan.md already confirmed
	# as plain hoc arithmetic, now authored as eqn instead. Real Limbo:
	#   speed := math->sqrt(vx*vx+vy*vy);
	#   ax := -drag*speed*vx-lift*spin*vy;
	#   ay := -gravity-drag*speed*vy+lift*spin*vx+verticalforce;
	names := "vx" :: "vy" :: "drag" :: "lift" :: "spin" :: "gravity" :: "verticalforce" :: nil;
	vals := 3.0 :: 4.0 :: 0.005 :: 0.0 :: 0.0 :: 9.8 :: 0.0 :: nil;
	checkeval("sqrt { vx sup 2 + vy sup 2 }", names, vals, 5.0,
		"ballistics: speed = sqrt(vx^2+vy^2)");
	checkeval("- drag speed vx - lift spin vy",
		"vx" :: "drag" :: "speed" :: "lift" :: "spin" :: "vy" :: nil,
		3.0 :: 0.005 :: 5.0 :: 0.0 :: 0.0 :: 4.0 :: nil,
		-0.075, "ballistics: ax = -drag*speed*vx - lift*spin*vy");
	checkeval("- gravity - drag speed vy + lift spin vx + verticalforce",
		"gravity" :: "drag" :: "speed" :: "vy" :: "lift" :: "spin" :: "vx" :: "verticalforce" :: nil,
		9.8 :: 0.005 :: 5.0 :: 4.0 :: 0.0 :: 0.0 :: 3.0 :: 0.0 :: nil,
		-9.9, "ballistics: ay = -gravity-drag*speed*vy+lift*spin*vx+verticalforce");

	# --- Mechanism family: appl/danby/pendulum.b's own gravity term
	# (the dry-friction/drive terms are a conditional, not a pure
	# formula - out of scope for eqn, same as hoc's own "no arrays"
	# scoping elsewhere; this is the actual physics, theta''=-(g/L)sin
	# theta, minus that piecewise friction). Real Limbo:
	#   -gravity/length*math->sin(angle)-damping*angularvelocity-friction+...
	# checked here: -gravity/length*sin(angle) alone, theta=PI/6 (30 deg).
	checkeval("- g over L sin { theta }",
		"g" :: "L" :: "theta" :: nil,
		9.8 :: 1.0 :: (3.14159265358979323846/6.0) :: nil,
		-4.9, "simple pendulum: -(g/L)*sin(theta), theta=30 degrees");
	# same formula, but theta is "PI over 6" written directly in the
	# eqn source rather than bound as a decimal - PI is installed as
	# an ordinary hoc symbol (appl/lib/hoc.b's installconst), so the
	# bare word "PI" in eqn source resolves to it with no special-
	# casing in eqn2hoc at all.
	checkeval("- g over L sin { PI over 6 }",
		"g" :: "L" :: nil, 9.8 :: 1.0 :: nil,
		-4.9, "same, theta written as PI over 6 - hoc's own PI constant, not a decimal");

	# --- Populationmodel family: appl/danby/epidemic.b's real SIR
	# rhs, doc/danby-tks-plan.md's own hoc example, now as eqn.
	checkeval("contact susceptible infectious",
		"contact" :: "susceptible" :: "infectious" :: nil,
		0.3 :: 100.0 :: 10.0 :: nil,
		300.0, "epidemic: infections = contact*susceptible*infectious");
	checkeval("recovery infectious", "recovery" :: "infectious" :: nil,
		0.1 :: 10.0 :: nil, 1.0, "epidemic: recoveries = recovery*infectious");
	checkeval("infections - recoveries", "infections" :: "recoveries" :: nil,
		300.0 :: 1.0 :: nil, 299.0, "epidemic: dinfectious = infections-recoveries");

	# --- Twospecies family: appl/danby/ecology.b's real Lotka-Volterra
	# rhs (real defaults: birth=1.5, predation=2.0, death=0.75). Real
	# Limbo: d[0]=birth*q[0]-predation*q[0]*q[1]; d[1]=q[0]*q[1]-death*q[1];
	checkeval("birth prey - predation prey predators",
		"birth" :: "prey" :: "predation" :: "predators" :: nil,
		1.5 :: 2.0 :: 2.0 :: 1.0 :: nil,
		-1.0, "ecology: dprey = birth*prey - predation*prey*predators");
	checkeval("prey predators - death predators",
		"prey" :: "predators" :: "death" :: nil,
		2.0 :: 1.0 :: 0.75 :: nil,
		1.25, "ecology: dpredators = prey*predators - death*predators");

	if(nfail == 0)
		sys->print("PASS\n");
	else{
		sys->print("%d test(s) failed\n", nfail);
		raise "fail:tests";
	}
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

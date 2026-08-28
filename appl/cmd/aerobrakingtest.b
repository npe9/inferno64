implement Command;

# aerobrakingtest(1) - checks appl/danby/plugin/aerobraking.b's
# eqn-driven rhs()/observables() against hand-computed values (an
# independent oracle would need loading a SECOND Orbital instance in
# the same process and calling its own Model.rhs - which this backlog
# tried and found silently broken: Limbo's "self ref Model" dot-method
# dispatch resolves through whichever module a caller's own "Model:
# import" names, not dynamically per the object's actual origin, so a
# second loaded model's .rhs call would silently run the FIRST
# model's code instead - a false pass, not a working comparison. See
# this file's own commit message and doc/danby-tks-plan.md for the
# full account. Hand-computed values, verified independently in
# Python before this file was written, avoid the pitfall entirely by
# never loading two Orbital instances in one process at all.

include "sys.m";
	sys: Sys;
include "draw.m";
include "danby/orbital.m";
	m: Orbital;
	Model: import m;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

nfail := 0;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	m = load Orbital "/dis/danby/plugin/aerobraking.dis";
	if(m == nil){
		sys->print("cannot load aerobraking: %r\n");
		raise "fail:load";
	}

	model := m->new();
	# x=1.05, y=0.3, vx=-0.02, vy=0.9 (an in-atmosphere craft state);
	# real parameters from new()'s own default array.
	state := array[] of {0.0,0.0,0.0,0.0, 1.05,0.3, -0.02,0.9};
	derivative := array[8] of real;
	model.rhs(0.0, state, derivative);

	check("derivative[0] (planet, fixed)", derivative[0], 0.0);
	check("derivative[1] (planet, fixed)", derivative[1], 0.0);
	check("derivative[2] (planet, fixed)", derivative[2], 0.0);
	check("derivative[3] (planet, fixed)", derivative[3], 0.0);
	check("derivative[4] (dx=vx)", derivative[4], -0.02);
	check("derivative[5] (dy=vy)", derivative[5], 0.9);
	check("derivative[6] (dvx: gravity+drag)", derivative[6], -0.8063085351010301);
	check("derivative[7] (dvy: gravity+drag)", derivative[7], -0.2304125843818792);

	obs := m->observables(model, state);
	check("observables[0] (radius)", obs[0], 1.0920164833920778);
	check("observables[1] (speed)", obs[1], 0.9002221947941519);

	if(nfail == 0)
		sys->print("PASS\n");
	else{
		sys->print("%d test(s) failed\n", nfail);
		raise "fail:tests";
	}
}

check(what: string, got, want: real)
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

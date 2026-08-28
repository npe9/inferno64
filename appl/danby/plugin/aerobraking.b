implement Orbital;

# Aerobraking's own physics, as literal eqn(7) strings - not hand-
# written Limbo arithmetic. This model is filed under Orbital (the
# N-body/array-math family - see doc/danby-tks-plan.md's own "one real
# boundary" section), but reading its ORIGINAL Limbo rhs() directly
# showed the "planet" body (state[0..3]) never moves at all - every
# derivative touching it is a constant 0.0. The actual dynamics are
# four independent named reals (x, y, vx, vy: the craft alone), a
# central 1/r^3 gravity term plus atmospheric drag - exactly the same
# shape danbyeqnall(1) already verified for Trajectory's ballistics/
# atmosphere formulas, not real array math at all. So this one Orbital
# plugin, unlike the other 11, has no array-math boundary to hit.
#
# Confirmed empirically before writing this: a single .dis file cannot
# serve two different module interfaces at once (Dis's own link
# typecheck compares against the compiled module's OWN "implement"
# type, not whatever shape a caller's load declares - a small probe
# with a second, unrelated interface on the same file failed with a
# real "link typecheck" error). Orbital.new() also takes no arguments,
# so a model has nowhere to receive external data from even if it
# could share a .dis with something else. A per-model file is
# unavoidable; what changes here is what's IN it - equation strings,
# not imperative math - not whether the file exists at all.

include "sys.m";
	sys: Sys;
include "eqn2hoc.m";
	eqn2hoc: Eqn2hoc;
# hoc.m deliberately does NOT include draw.m itself (see its own header
# comment) - needs it declared before, for its own init()/run() shapes,
# even though this file never calls them.
include "draw.m";
include "hoc.m";
	hoc: Hoc;
include "danby/orbital.m";

# One row per quantity, evaluated in this order every rhs() call - a
# later row may reference an earlier row's own name (matching hoc's
# real per-rk4-step usage pattern: compile once, resolve symbols once,
# eval every step). "rho"/"factor"/"axdrag"/"aydrag" are the same
# density()/drag2() chain danbyeqnall(1) already verified against
# atmosphere->drag2() itself; assumes altitude >= 0 (density()'s own
# one piecewise clamp - out of scope, same reasoning as everywhere else
# this session scoped a conditional out of a pure eqn formula).
eqnnames := array[] of {
	"r", "inversecube", "altitude", "rho", "speed", "factor", "axdrag", "aydrag", "dvx", "dvy",
};
eqnsrcs := array[] of {
	"sqrt { x sup 2 + y sup 2 }",
	"1.0 over { r sup 3 }",
	"r - 1.0",
	"surface exp { - altitude over scaleheight }",
	"sqrt { vx sup 2 + vy sup 2 }",
	"- 0.5 rho coefficient area speed over mass",
	"factor vx",
	"factor vy",
	"- gravity x inversecube + axdrag",
	"- gravity y inversecube + aydrag",
};
compiled: array of ref Hoc->Expr;

# resolved once in new(), written directly every rhs() call - the
# zero-lookup form hoc(2)'s own header comment describes.
sx, sy, svx, svy: ref Hoc->Sym;
sgravity, sscaleheight, ssurface, scoefficient, sarea, smass: ref Hoc->Sym;
sdvx, sdvy: ref Hoc->Sym;

new(): ref Model
{
	sys = load Sys Sys->PATH;
	eqn2hoc = load Eqn2hoc Eqn2hoc->PATH;
	hoc = load Hoc Hoc->PATH;
	if(eqn2hoc == nil || hoc == nil)
		raise "fail:aerobraking: cannot load eqn2hoc/hoc";
	hoc->reset();
	compiled = array[len eqnnames] of ref Hoc->Expr;
	for(i := 0; i < len eqnnames; i++){
		(hocsrc, err) := eqn2hoc->translate(eqnsrcs[i]);
		if(err != nil)
			raise "fail:aerobraking: eqn2hoc: "+eqnsrcs[i]+": "+err;
		e := hoc->compile(hocsrc);
		if(e == nil)
			raise "fail:aerobraking: hoc could not compile: "+hocsrc;
		compiled[i] = e;
	}
	sx = hoc->symbol("x"); sy = hoc->symbol("y");
	svx = hoc->symbol("vx"); svy = hoc->symbol("vy");
	sgravity = hoc->symbol("gravity"); sscaleheight = hoc->symbol("scaleheight");
	ssurface = hoc->symbol("surface"); scoefficient = hoc->symbol("coefficient");
	sarea = hoc->symbol("area"); smass = hoc->symbol("mass");
	sdvx = hoc->symbol("dvx"); sdvy = hoc->symbol("dvy");
	scoefficient.val = 1.0;
	smass.val = 1.0;

	return ref Model(array[] of {1.18,0.88,0.025,0.08,1.0,0.012},
		array[] of {1.0,0.0});
}

title(): string
{
	return "Aerobraking the orbit of a spacecraft";
}

parameterlabels(): array of string
{
	return array[] of {"apoapsis", "speed", "atmosphere", "scale height", "gravity", "drag area"};
}

parameterminima(): array of real
{
	return array[] of {1.02,0.3,0.0,0.01,0.2,0.0};
}

parametermaxima(): array of real
{
	return array[] of {2.0,1.5,0.2,0.3,2.0,0.08};
}

bodylabels(): array of string
{
	return array[] of {"planet", "craft"};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	return array[] of {0.0,0.0,0.0,0.0,p[0],0.0,0.0,p[1]};
}

maxtime(nil: ref Model): real
{
	return 30.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	sx.val = state[4]; sy.val = state[5];
	svx.val = state[6]; svy.val = state[7];
	ssurface.val = p[2]; sscaleheight.val = p[3];
	sgravity.val = p[4]; sarea.val = p[5];

	for(i := 0; i < len compiled; i++)
		hoc->symbol(eqnnames[i]).val = hoc->eval(compiled[i]);

	derivative[0] = 0.0;
	derivative[1] = 0.0;
	derivative[2] = 0.0;
	derivative[3] = 0.0;
	derivative[4] = state[6];
	derivative[5] = state[7];
	derivative[6] = sdvx.val;
	derivative[7] = sdvy.val;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

observablelabels(): array of string
{
	return array[] of {"radius", "speed"};
}

observables(nil: ref Model, state: array of real): array of real
{
	# reuses compiled[0] ("r", i.e. sqrt(x^2+y^2)) and compiled[4]
	# ("speed", i.e. sqrt(vx^2+vy^2)) - the exact same compiled trees
	# rhs() itself evaluates every step, not a fresh compile here.
	sx.val = state[4]; sy.val = state[5];
	svx.val = state[6]; svy.val = state[7];
	return array[] of {hoc->eval(compiled[0]), hoc->eval(compiled[4])};
}

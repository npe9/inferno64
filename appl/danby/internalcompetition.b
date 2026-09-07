implement Twospecies;

# danby/internalcompetition - Predator-prey with internal competition
#
# The equations, the parameters and everything else model-specific are
# in this file.  The window, the integrator and the controls are the
# shared ecology viewer's; init() at the foot of the file starts it and
# hands it this module back.

include "sys.m";
include "draw.m";
include "danby/twospecies.m";

new(): ref Model
{
	return ref Model(array[] of {1.5, 0.5, 1.0, 1.0, 0.5, 0.4});
}

title(): string
{
	return "Predator-prey with internal competition";
}

parameterlabels(): array of string
{
	return array[] of {
		"prey birth", "prey crowding", "predation",
		"conversion", "predator death", "predator crowding"
	};
}

parameterranges(): array of real
{
	return array[] of {3.0, 2.0, 3.0, 3.0, 2.0, 2.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	x := state[0];
	y := state[1];
	derivative[0] = x*(p[0]-p[1]*x-p[2]*y);
	derivative[1] = y*(p[3]*x-p[4]-p[5]*y);
}

Model.equilibrium(model: self ref Model): (real, real)
{
	p := model.parameter;
	denominator := p[1]*p[5]+p[2]*p[3];
	prey := (p[0]*p[5]+p[2]*p[4])/denominator;
	predators := (p[0]*p[3]-p[1]*p[4])/denominator;
	return (prey,predators);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

fixedpoint(model: ref Model): (real, real)
{
	return model.equilibrium();
}

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	viewer := load Command "/dis/danby/ecology.dis";
	if(viewer == nil)
		raise "fail:internalcompetition: cannot load the ecology viewer";
	viewer->init(ctxt, "internalcompetition" :: "/dis/danby/internalcompetition.dis" ::
		"danby-internalcompetition" :: nil);
}

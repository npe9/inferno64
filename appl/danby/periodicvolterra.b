implement Twospecies;

# danby/periodicvolterra - Volterra model with periodic birthrate
#
# The equations, the parameters and everything else model-specific are
# in this file.  The window, the integrator and the controls are the
# shared ecology viewer's; init() at the foot of the file starts it and
# hands it this module back.

include "sys.m";
include "draw.m";
include "math.m";
	math: Math;
include "danby/twospecies.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {1.5, 2.0, 1.0, 0.75, 0.25, 1.0});
}

title(): string
{
	return "Volterra model with periodic birthrate";
}

parameterlabels(): array of string
{
	return array[] of {
		"mean birth", "predation", "conversion",
		"predator death", "seasonality", "frequency"
	};
}

parameterranges(): array of real
{
	return array[] of {3.0, 4.0, 3.0, 3.0, 0.95, 3.0};
}

Model.rhs(model: self ref Model, t: real,
		state, derivative: array of real)
{
	p := model.parameter;
	birth := p[0]*(1.0+p[4]*math->cos(p[5]*t));
	derivative[0] = birth*state[0]-p[1]*state[0]*state[1];
	derivative[1] = p[2]*state[0]*state[1]-p[3]*state[1];
}

Model.equilibrium(model: self ref Model): (real, real)
{
	p := model.parameter;
	return (p[3]/p[2],p[0]/p[1]);
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
		raise "fail:periodicvolterra: cannot load the ecology viewer";
	viewer->init(ctxt, "periodicvolterra" :: "/dis/danby/periodicvolterra.dis" ::
		"danby-periodicvolterra" :: nil);
}

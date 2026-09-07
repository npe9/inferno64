implement Populationmodel;

# danby/seasonaldisease - Seasonal changes in infectiousness
#
# The equations, the parameters and everything else model-specific are
# in this file.  The window, the integrator and the controls are the
# shared populations viewer's; init() at the foot of the file starts it and
# hands it this module back.

include "sys.m";
include "draw.m";
include "math.m";
	math: Math;
include "danby/populationmodel.m";

new(): ref Model
{
	math = load Math Math->PATH;
	parameters := array[] of {2.0, 0.45, 1.0, 0.55};
	initial := array[] of {0.99, 0.01, 0.0};
	return ref Model(parameters,initial);
}

title(): string
{
	return "Seasonal changes in infectiousness";
}

statelabels(): array of string
{
	return array[] of {"susceptible", "infectious", "recovered"};
}

parameterlabels(): array of string
{
	return array[] of {"mean contact", "seasonality", "frequency", "recovery"};
}

parameterranges(): array of real
{
	return array[] of {5.0, 0.95, 3.0, 2.0};
}

Model.rhs(model: self ref Model, t: real,
		state, derivative: array of real)
{
	p := model.parameter;
	contact := p[0]*(1.0+p[1]*math->cos(p[2]*t));
	infections := contact*state[0]*state[1];
	recoveries := p[3]*state[1];
	derivative[0] = -infections;
	derivative[1] = infections-recoveries;
	derivative[2] = recoveries;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	viewer := load Command "/dis/temple/populations.dis";
	if(viewer == nil)
		raise "fail:seasonaldisease: cannot load the populations viewer";
	viewer->init(ctxt, "seasonaldisease" :: "/dis/danby/seasonaldisease.dis" ::
		"danby-seasonaldisease" :: nil);
}

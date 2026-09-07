implement Populationmodel;

# danby/weightchange - Body-weight energy balance
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
	parameters := array[] of {10.5, 0.72, 0.035, 32.2};
	initial := array[] of {75.0};
	return ref Model(parameters,initial);
}

title(): string
{
	return "Body-weight energy balance";
}

statelabels(): array of string
{
	return array[] of {"body mass"};
}

parameterlabels(): array of string
{
	return array[] of {"energy intake", "basal coefficient", "activity", "energy density"};
}

parameterranges(): array of real
{
	return array[] of {20.0, 1.5, 0.15, 60.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	mass := state[0];
	if(mass < 0.0)
		mass = 0.0;
	expenditure := p[1]*math->pow(mass,0.75)+p[2]*mass;
	derivative[0] = (p[0]-expenditure)/p[3];
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
		raise "fail:weightchange: cannot load the populations viewer";
	viewer->init(ctxt, "weightchange" :: "/dis/danby/weightchange.dis" ::
		"danby-weightchange" :: nil);
}

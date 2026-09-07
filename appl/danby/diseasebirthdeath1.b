implement Populationmodel;

# danby/diseasebirthdeath1 - Disease with balanced births and deaths
#
# The equations, the parameters and everything else model-specific are
# in this file.  The window, the integrator and the controls are the
# shared populations viewer's; init() at the foot of the file starts it and
# hands it this module back.

include "sys.m";
include "draw.m";
include "danby/populationmodel.m";

new(): ref Model
{
	parameters := array[] of {2.2, 0.55, 0.03};
	initial := array[] of {0.99, 0.01, 0.0};
	return ref Model(parameters,initial);
}

title(): string
{
	return "Disease with balanced births and deaths";
}

statelabels(): array of string
{
	return array[] of {"susceptible", "infectious", "recovered"};
}

parameterlabels(): array of string
{
	return array[] of {"contact", "recovery", "turnover"};
}

parameterranges(): array of real
{
	return array[] of {5.0, 2.0, 0.5};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	infections := p[0]*state[0]*state[1];
	recoveries := p[1]*state[1];
	derivative[0] = p[2]-infections-p[2]*state[0];
	derivative[1] = infections-recoveries-p[2]*state[1];
	derivative[2] = recoveries-p[2]*state[2];
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
		raise "fail:diseasebirthdeath1: cannot load the populations viewer";
	viewer->init(ctxt, "diseasebirthdeath1" :: "/dis/danby/diseasebirthdeath1.dis" ::
		"danby-diseasebirthdeath1" :: nil);
}

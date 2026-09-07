implement Populationmodel;

# danby/incubation - SEIR epidemic with incubation
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
	parameters := array[] of {2.2, 0.8, 0.55};
	initial := array[] of {0.99, 0.005, 0.005, 0.0};
	return ref Model(parameters,initial);
}

title(): string
{
	return "SEIR epidemic with incubation";
}

statelabels(): array of string
{
	return array[] of {"susceptible", "exposed", "infectious", "recovered"};
}

parameterlabels(): array of string
{
	return array[] of {"contact", "incubation", "recovery"};
}

parameterranges(): array of real
{
	return array[] of {5.0, 3.0, 2.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	infections := p[0]*state[0]*state[2];
	progression := p[1]*state[1];
	recoveries := p[2]*state[2];
	derivative[0] = -infections;
	derivative[1] = infections-progression;
	derivative[2] = progression-recoveries;
	derivative[3] = recoveries;
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
		raise "fail:incubation: cannot load the populations viewer";
	viewer->init(ctxt, "incubation" :: "/dis/danby/incubation.dis" ::
		"danby-incubation" :: nil);
}

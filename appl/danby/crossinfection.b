implement Populationmodel;

# danby/crossinfection - Cross-infection between two species
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
	parameters := array[] of {1.8, 1.5, 0.35, 0.5};
	initial := array[] of {0.99, 0.01, 0.995, 0.005};
	return ref Model(parameters,initial);
}

title(): string
{
	return "Cross-infection between two species";
}

statelabels(): array of string
{
	return array[] of {"susceptible A", "infectious A", "susceptible B", "infectious B"};
}

parameterlabels(): array of string
{
	return array[] of {"within contact", "cross contact", "recovery A", "recovery B"};
}

parameterranges(): array of real
{
	return array[] of {5.0, 5.0, 2.0, 2.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	forcea := p[0]*state[1]+p[1]*state[3];
	forceb := p[0]*state[3]+p[1]*state[1];
	infectionsa := state[0]*forcea;
	infectionsb := state[2]*forceb;
	derivative[0] = -infectionsa;
	derivative[1] = infectionsa-p[2]*state[1];
	derivative[2] = -infectionsb;
	derivative[3] = infectionsb-p[3]*state[3];
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
		raise "fail:crossinfection: cannot load the populations viewer";
	viewer->init(ctxt, "crossinfection" :: "/dis/danby/crossinfection.dis" ::
		"danby-crossinfection" :: nil);
}

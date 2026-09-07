implement Populationmodel;

# danby/budworm - Spruce budworm versus balsam fir
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
	parameters := array[] of {0.55, 3.0, 1.0, 0.5};
	initial := array[] of {0.35};
	return ref Model(parameters,initial);
}

title(): string
{
	return "Spruce budworm versus balsam fir";
}

statelabels(): array of string
{
	return array[] of {"budworms"};
}

parameterlabels(): array of string
{
	return array[] of {"growth", "foliage capacity", "bird predation", "saturation"};
}

parameterranges(): array of real
{
	return array[] of {2.0, 6.0, 3.0, 2.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	worms := state[0];
	predation := p[2]*worms*worms/(p[3]*p[3]+worms*worms);
	derivative[0] = p[0]*worms*(1.0-worms/p[1])-predation;
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
		raise "fail:budworm: cannot load the populations viewer";
	viewer->init(ctxt, "budworm" :: "/dis/danby/budworm.dis" ::
		"danby-budworm" :: nil);
}

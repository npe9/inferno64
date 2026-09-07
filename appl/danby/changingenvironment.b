implement Populationmodel;

# danby/changingenvironment - Population growth in a changing environment
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
	parameters := array[] of {1.0, 1.4, 0.45, 0.7};
	initial := array[] of {0.6};
	return ref Model(parameters,initial);
}

title(): string
{
	return "Population growth in a changing environment";
}

statelabels(): array of string
{
	return array[] of {"population"};
}

parameterlabels(): array of string
{
	return array[] of {"growth", "mean capacity", "variation", "frequency"};
}

parameterranges(): array of real
{
	return array[] of {3.0, 3.0, 0.95, 3.0};
}

Model.rhs(model: self ref Model, t: real,
		state, derivative: array of real)
{
	p := model.parameter;
	capacity := p[1]*(1.0+p[2]*math->sin(p[3]*t));
	if(capacity < 1.0e-8)
		capacity = 1.0e-8;
	derivative[0] = p[0]*state[0]*(1.0-state[0]/capacity);
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
		raise "fail:changingenvironment: cannot load the populations viewer";
	viewer->init(ctxt, "changingenvironment" :: "/dis/danby/changingenvironment.dis" ::
		"danby-changingenvironment" :: nil);
}

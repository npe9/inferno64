implement Populationmodel;

# danby/reactorstability - Chemical tank reactor stability
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
	return ref Model(array[] of {1.0,1.0,2.8,4.0,1.2,0.35},array[] of {1.0,0.45});
}

title(): string
{
	return "Chemical tank reactor stability";
}

statelabels(): array of string
{
	return array[] of {"reactant", "temperature"};
}

parameterlabels(): array of string
{
	return array[] of {"residence time", "feed concentration", "reaction rate", "activation", "heat release", "cooling"};
}

parameterranges(): array of real
{
	return array[] of {5.0,4.0,10.0,12.0,6.0,4.0};
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	temperature := state[1];
	rate := p[2]*math->exp(-p[3]/(temperature+1.0))*state[0];
	derivative[0] = (p[1]-state[0])/p[0]-rate;
	derivative[1] = (0.35-temperature)/p[0]+p[4]*rate-
		p[5]*(temperature-0.25);
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
		raise "fail:reactorstability: cannot load the populations viewer";
	viewer->init(ctxt, "reactorstability" :: "/dis/danby/reactorstability.dis" ::
		"danby-reactorstability" :: nil);
}

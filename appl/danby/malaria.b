implement Populationmodel;

# danby/malaria - Human-mosquito malaria transmission
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
	parameters := array[] of {1.1, 1.4, 0.35, 0.55};
	initial := array[] of {0.99, 0.01, 0.98, 0.02};
	return ref Model(parameters,initial);
}

title(): string
{
	return "Human-mosquito malaria transmission";
}

statelabels(): array of string
{
	return array[] of {"susceptible humans", "infectious humans", "susceptible mosquitoes", "infectious mosquitoes"};
}

parameterlabels(): array of string
{
	return array[] of {"mosquito to human", "human to mosquito", "human recovery", "mosquito turnover"};
}

parameterranges(): array of real
{
	return array[] of {4.0, 4.0, 2.0, 2.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	humaninfection := p[0]*state[0]*state[3];
	mosquitoinfection := p[1]*state[2]*state[1];
	derivative[0] = -humaninfection+p[2]*state[1];
	derivative[1] = humaninfection-p[2]*state[1];
	derivative[2] = -mosquitoinfection+p[3]*state[3];
	derivative[3] = mosquitoinfection-p[3]*state[3];
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
		raise "fail:malaria: cannot load the populations viewer";
	viewer->init(ctxt, "malaria" :: "/dis/danby/malaria.dis" ::
		"danby-malaria" :: nil);
}

implement Populationmodel;

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

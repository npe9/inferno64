implement Populationmodel;

include "danby/populationmodel.m";

new(): ref Model
{
	return ref Model(array[] of {2.2,0.55},array[] of {0.995,0.005,0.0});
}

title(): string
{
	return "SIR epidemic";
}

statelabels(): array of string
{
	return array[] of {"susceptible", "infectious", "recovered"};
}

parameterlabels(): array of string
{
	return array[] of {"contact", "recovery"};
}

parameterranges(): array of real
{
	return array[] of {5.0,2.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	infections := p[0]*state[0]*state[1];
	recoveries := p[1]*state[1];
	derivative[0] = -infections;
	derivative[1] = infections-recoveries;
	derivative[2] = recoveries;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

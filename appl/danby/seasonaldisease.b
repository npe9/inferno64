implement Populationmodel;

include "math.m";
	math: Math;
include "danby/populationmodel.m";

new(): ref Model
{
	math = load Math Math->PATH;
	parameters := array[] of {2.0, 0.45, 1.0, 0.55};
	initial := array[] of {0.99, 0.01, 0.0};
	return ref Model(parameters,initial);
}

title(): string
{
	return "Seasonal changes in infectiousness";
}

statelabels(): array of string
{
	return array[] of {"susceptible", "infectious", "recovered"};
}

parameterlabels(): array of string
{
	return array[] of {"mean contact", "seasonality", "frequency", "recovery"};
}

parameterranges(): array of real
{
	return array[] of {5.0, 0.95, 3.0, 2.0};
}

Model.rhs(model: self ref Model, t: real,
		state, derivative: array of real)
{
	p := model.parameter;
	contact := p[0]*(1.0+p[1]*math->cos(p[2]*t));
	infections := contact*state[0]*state[1];
	recoveries := p[3]*state[1];
	derivative[0] = -infections;
	derivative[1] = infections-recoveries;
	derivative[2] = recoveries;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

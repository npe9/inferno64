implement Populationmodel;

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

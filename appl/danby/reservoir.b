implement Populationmodel;

include "math.m";
	math: Math;
include "danby/populationmodel.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {0.8,0.55,0.4,0.25,0.3},array[] of {1.4,0.7,0.35});
}

title(): string
{
	return "Dynamics of a reservoir system";
}

statelabels(): array of string
{
	return array[] of {"upper reservoir", "lower reservoir", "service storage"};
}

parameterlabels(): array of string
{
	return array[] of {"inflow", "upper outlet", "lower outlet", "demand", "evaporation"};
}

parameterranges(): array of real
{
	return array[] of {3.0,3.0,3.0,2.0,1.0};
}

root(value: real): real
{
	if(value <= 0.0)
		return 0.0;
	return math->sqrt(value);
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	upperflow := p[1]*root(state[0]);
	lowerflow := p[2]*root(state[1]);
	delivery := p[3]*root(state[2]);
	derivative[0] = p[0]-upperflow-p[4]*state[0];
	derivative[1] = upperflow-lowerflow-p[4]*state[1];
	derivative[2] = lowerflow-delivery-p[4]*state[2];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

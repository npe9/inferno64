implement Populationmodel;

include "math.m";
	math: Math;
include "danby/populationmodel.m";

new(): ref Model
{
	math = load Math Math->PATH;
	parameters := array[] of {10.5, 0.72, 0.035, 32.2};
	initial := array[] of {75.0};
	return ref Model(parameters,initial);
}

title(): string
{
	return "Body-weight energy balance";
}

statelabels(): array of string
{
	return array[] of {"body mass"};
}

parameterlabels(): array of string
{
	return array[] of {"energy intake", "basal coefficient", "activity", "energy density"};
}

parameterranges(): array of real
{
	return array[] of {20.0, 1.5, 0.15, 60.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	mass := state[0];
	if(mass < 0.0)
		mass = 0.0;
	expenditure := p[1]*math->pow(mass,0.75)+p[2]*mass;
	derivative[0] = (p[0]-expenditure)/p[3];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

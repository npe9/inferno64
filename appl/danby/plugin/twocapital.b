implement Populationmodel;

include "math.m";
	math: Math;
include "danby/populationmodel.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {1.0,0.55,0.24,0.2,0.08,0.06},
		array[] of {1.0,0.8});
}

title(): string
{
	return "One-sector economy with two capital stocks";
}

statelabels(): array of string
{
	return array[] of {"capital A", "capital B"};
}

parameterlabels(): array of string
{
	return array[] of {"productivity", "share A", "investment A", "investment B", "depreciation A", "depreciation B"};
}

parameterranges(): array of real
{
	return array[] of {3.0,0.95,0.8,0.8,0.5,0.5};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	capitala := state[0];
	capitalb := state[1];
	if(capitala < 0.0)
		capitala = 0.0;
	if(capitalb < 0.0)
		capitalb = 0.0;
	output := p[0]*math->pow(capitala,p[1])*
		math->pow(capitalb,1.0-p[1]);
	derivative[0] = p[2]*output-p[4]*capitala;
	derivative[1] = p[3]*output-p[5]*capitalb;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

implement Populationmodel;

include "danby/populationmodel.m";

new(): ref Model
{
	return ref Model(array[] of {0.15, 1.0, -0.45},
		array[] of {-1.0, 0.4});
}

title(): string
{
	return "Zeeman heartbeat model";
}

statelabels(): array of string
{
	return array[] of {"muscle state", "electrochemical drive"};
}

parameterlabels(): array of string
{
	return array[] of {"fast timescale", "tension", "pacemaker"};
}

parameterranges(): array of real
{
	return array[] of {0.5, 2.0, 1.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	epsilon := p[0];
	if(epsilon < 1.0e-4)
		epsilon = 1.0e-4;
	x := state[0];
	y := state[1];
	derivative[0] = -(x*x*x-p[1]*x+y)/epsilon;
	derivative[1] = x-p[2];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

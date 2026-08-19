implement Populationmodel;

include "danby/populationmodel.m";

new(): ref Model
{
	return ref Model(array[] of {3.0,0.002,1.2,0.8},array[] of {0.2,0.3,0.1});
}

title(): string
{
	return "The Oregonator";
}

statelabels(): array of string
{
	return array[] of {"bromous acid", "bromide", "oxidized catalyst"};
}

parameterlabels(): array of string
{
	return array[] of {"timescale", "q", "stoichiometric f", "catalyst rate"};
}

parameterranges(): array of real
{
	return array[] of {12.0,0.05,4.0,4.0};
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	x := state[0];
	y := state[1];
	z := state[2];
	derivative[0] = p[0]*(y+x*(1.0-p[1]*x)-x*x);
	derivative[1] = (-y-x*y+p[2]*z)/p[0];
	derivative[2] = p[3]*(x-z);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

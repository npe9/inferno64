implement Populationmodel;

include "danby/populationmodel.m";

new(): ref Model
{
	return ref Model(array[] of {1.0,3.0},array[] of {1.2,2.4});
}

title(): string
{
	return "The Brusselator";
}

statelabels(): array of string
{
	return array[] of {"activator X", "intermediate Y"};
}

parameterlabels(): array of string
{
	return array[] of {"feed A", "feed B"};
}

parameterranges(): array of real
{
	return array[] of {4.0,8.0};
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	a := model.parameter[0];
	b := model.parameter[1];
	x := state[0];
	y := state[1];
	nonlinear := x*x*y;
	derivative[0] = a-(b+1.0)*x+nonlinear;
	derivative[1] = b*x-nonlinear;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

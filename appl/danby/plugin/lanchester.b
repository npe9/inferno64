implement Populationmodel;

include "danby/populationmodel.m";

new(): ref Model
{
	return ref Model(array[] of {0.35,0.5},array[] of {1.0,0.8});
}

title(): string
{
	return "Lanchester square-law combat";
}

statelabels(): array of string
{
	return array[] of {"force A", "force B"};
}

parameterlabels(): array of string
{
	return array[] of {"B effectiveness", "A effectiveness"};
}

parameterranges(): array of real
{
	return array[] of {2.0,2.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	derivative[0] = -p[0]*state[1];
	derivative[1] = -p[1]*state[0];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

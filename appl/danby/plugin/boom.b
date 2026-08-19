implement Populationmodel;

include "danby/populationmodel.m";

new(): ref Model
{
	return ref Model(array[] of {0.6,1.0,0.8,1.0},array[] of {0.65,0.25});
}

title(): string
{
	return "Goodwin growth cycle";
}

statelabels(): array of string
{
	return array[] of {"wage share", "employment"};
}

parameterlabels(): array of string
{
	return array[] of {"wage decay", "employment to wage", "employment growth", "wage drag"};
}

parameterranges(): array of real
{
	return array[] of {2.0,2.0,2.0,2.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	derivative[0] = state[0]*(-p[0]+p[1]*state[1]);
	derivative[1] = state[1]*(p[2]-p[3]*state[0]);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

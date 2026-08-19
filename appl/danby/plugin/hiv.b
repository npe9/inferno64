implement Populationmodel;

include "danby/populationmodel.m";

new(): ref Model
{
	parameters := array[] of {1.4, 0.18, 0.12};
	initial := array[] of {0.995, 0.005, 0.0};
	return ref Model(parameters,initial);
}

title(): string
{
	return "Initial spread of HIV";
}

statelabels(): array of string
{
	return array[] of {"susceptible", "HIV infected", "AIDS"};
}

parameterlabels(): array of string
{
	return array[] of {"effective contact", "progression", "AIDS mortality"};
}

parameterranges(): array of real
{
	return array[] of {4.0, 1.0, 1.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	transmission := p[0]*state[0]*state[1];
	progression := p[1]*state[1];
	derivative[0] = -transmission;
	derivative[1] = transmission-progression;
	derivative[2] = progression-p[2]*state[2];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

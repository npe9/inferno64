implement Populationmodel;

include "danby/populationmodel.m";

new(): ref Model
{
	parameters := array[] of {2.2, 0.8, 0.55};
	initial := array[] of {0.99, 0.005, 0.005, 0.0};
	return ref Model(parameters,initial);
}

title(): string
{
	return "SEIR epidemic with incubation";
}

statelabels(): array of string
{
	return array[] of {"susceptible", "exposed", "infectious", "recovered"};
}

parameterlabels(): array of string
{
	return array[] of {"contact", "incubation", "recovery"};
}

parameterranges(): array of real
{
	return array[] of {5.0, 3.0, 2.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	infections := p[0]*state[0]*state[2];
	progression := p[1]*state[1];
	recoveries := p[2]*state[2];
	derivative[0] = -infections;
	derivative[1] = infections-progression;
	derivative[2] = progression-recoveries;
	derivative[3] = recoveries;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

implement Populationmodel;

include "danby/populationmodel.m";

new(): ref Model
{
	parameters := array[] of {2.2, 0.55, 0.03};
	initial := array[] of {0.99, 0.01, 0.0};
	return ref Model(parameters,initial);
}

title(): string
{
	return "Disease with balanced births and deaths";
}

statelabels(): array of string
{
	return array[] of {"susceptible", "infectious", "recovered"};
}

parameterlabels(): array of string
{
	return array[] of {"contact", "recovery", "turnover"};
}

parameterranges(): array of real
{
	return array[] of {5.0, 2.0, 0.5};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	infections := p[0]*state[0]*state[1];
	recoveries := p[1]*state[1];
	derivative[0] = p[2]-infections-p[2]*state[0];
	derivative[1] = infections-recoveries-p[2]*state[1];
	derivative[2] = recoveries-p[2]*state[2];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

implement Populationmodel;

include "danby/populationmodel.m";

new(): ref Model
{
	parameters := array[] of {1.8, 1.5, 0.35, 0.5};
	initial := array[] of {0.99, 0.01, 0.995, 0.005};
	return ref Model(parameters,initial);
}

title(): string
{
	return "Cross-infection between two species";
}

statelabels(): array of string
{
	return array[] of {"susceptible A", "infectious A", "susceptible B", "infectious B"};
}

parameterlabels(): array of string
{
	return array[] of {"within contact", "cross contact", "recovery A", "recovery B"};
}

parameterranges(): array of real
{
	return array[] of {5.0, 5.0, 2.0, 2.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	forcea := p[0]*state[1]+p[1]*state[3];
	forceb := p[0]*state[3]+p[1]*state[1];
	infectionsa := state[0]*forcea;
	infectionsb := state[2]*forceb;
	derivative[0] = -infectionsa;
	derivative[1] = infectionsa-p[2]*state[1];
	derivative[2] = -infectionsb;
	derivative[3] = infectionsb-p[3]*state[3];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

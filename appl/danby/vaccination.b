implement Populationmodel;

include "danby/populationmodel.m";

new(): ref Model
{
	return ref Model(array[] of {2.2,0.55,0.20},
		array[] of {0.792,0.01,0.0,0.198});
}

title(): string
{
	return "SIR epidemic with vaccination";
}

statelabels(): array of string
{
	return array[] of {"susceptible", "infectious", "recovered", "vaccinated"};
}

parameterlabels(): array of string
{
	return array[] of {"contact", "recovery", "coverage"};
}

parameterranges(): array of real
{
	return array[] of {5.0,2.0,0.95};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	infections := p[0]*state[0]*state[1];
	recoveries := p[1]*state[1];
	derivative[0] = -infections;
	derivative[1] = infections-recoveries;
	derivative[2] = recoveries;
	derivative[3] = 0.0;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

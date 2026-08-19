implement Populationmodel;

include "danby/populationmodel.m";

new(): ref Model
{
	parameters := array[] of {1.1, 1.5, 1.4, 0.75, 0.45};
	initial := array[] of {0.8, 0.12};
	return ref Model(parameters,initial);
}

title(): string
{
	return "Population growth of a parasite";
}

statelabels(): array of string
{
	return array[] of {"hosts", "parasites"};
}

parameterlabels(): array of string
{
	return array[] of {
		"host growth", "host capacity", "infection",
		"conversion", "parasite death"
	};
}

parameterranges(): array of real
{
	return array[] of {3.0, 3.0, 3.0, 2.0, 2.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	hosts := state[0];
	parasites := state[1];
	infections := p[2]*hosts*parasites;
	derivative[0] = p[0]*hosts*(1.0-hosts/p[1])-infections;
	derivative[1] = p[3]*infections-p[4]*parasites;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

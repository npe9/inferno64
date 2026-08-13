implement Populationmodel;

include "danby/populationmodel.m";

new(): ref Model
{
	parameters := array[] of {0.35, 1.5, 0.45, 0.12};
	initial := array[] of {0.2};
	return ref Model(parameters,initial);
}

title(): string
{
	return "Pollutant concentration in a lake";
}

statelabels(): array of string
{
	return array[] of {"pollutant"};
}

parameterlabels(): array of string
{
	return array[] of {"input mass", "lake volume", "outflow", "decay"};
}

parameterranges(): array of real
{
	return array[] of {2.0, 4.0, 2.0, 1.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	derivative[0] = p[0]/p[1]-(p[2]/p[1]+p[3])*state[0];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

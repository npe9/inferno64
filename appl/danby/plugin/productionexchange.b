implement Populationmodel;

include "danby/populationmodel.m";

new(): ref Model
{
	return ref Model(array[] of {0.8,0.5,0.55,0.7,0.45},
		array[] of {0.7,0.35});
}

title(): string
{
	return "Production and exchange of two goods";
}

statelabels(): array of string
{
	return array[] of {"good A inventory", "good B inventory"};
}

parameterlabels(): array of string
{
	return array[] of {"production A", "use A", "production B", "use B", "exchange"};
}

parameterranges(): array of real
{
	return array[] of {2.0,2.0,2.0,2.0,2.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	flow := p[4]*(state[0]-state[1]);
	derivative[0] = p[0]-p[1]*state[0]-flow;
	derivative[1] = p[2]-p[3]*state[1]+flow;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

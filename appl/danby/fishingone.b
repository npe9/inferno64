implement Populationmodel;

include "danby/populationmodel.m";

new(): ref Model
{
	return ref Model(array[] of {1.0,1.5,0.7,1.2,0.45,0.8},
		array[] of {1.0,0.35});
}

title(): string
{
	return "Bioeconomics of one fish species";
}

statelabels(): array of string
{
	return array[] of {"fish stock", "fishing effort"};
}

parameterlabels(): array of string
{
	return array[] of {"growth", "capacity", "catchability", "price", "cost", "effort response"};
}

parameterranges(): array of real
{
	return array[] of {3.0,4.0,2.0,3.0,2.0,2.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	stock := state[0];
	effort := state[1];
	harvest := p[2]*effort*stock;
	profitpereffort := p[3]*p[2]*stock-p[4];
	derivative[0] = p[0]*stock*(1.0-stock/p[1])-harvest;
	derivative[1] = p[5]*effort*profitpereffort;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

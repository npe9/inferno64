implement Populationmodel;

include "danby/populationmodel.m";

new(): ref Model
{
	parameters := array[] of {1.0,1.5,0.65,1.2,0.8,1.1,0.5,1.6,0.55,0.7};
	initial := array[] of {0.9,0.7,0.3};
	return ref Model(parameters,initial);
}

title(): string
{
	return "Bioeconomics of two fish species";
}

statelabels(): array of string
{
	return array[] of {"fish stock A", "fish stock B", "fishing effort"};
}

parameterlabels(): array of string
{
	return array[] of {"growth A", "capacity A", "catch A", "price A",
		"growth B", "capacity B", "catch B", "price B", "cost", "effort response"};
}

parameterranges(): array of real
{
	return array[] of {3.0,4.0,2.0,3.0,3.0,4.0,2.0,3.0,3.0,2.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	stocka := state[0];
	stockb := state[1];
	effort := state[2];
	harvesta := p[2]*effort*stocka;
	harvestb := p[6]*effort*stockb;
	profit := p[3]*p[2]*stocka+p[7]*p[6]*stockb-p[8];
	derivative[0] = p[0]*stocka*(1.0-stocka/p[1])-harvesta;
	derivative[1] = p[4]*stockb*(1.0-stockb/p[5])-harvestb;
	derivative[2] = p[9]*effort*profit;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

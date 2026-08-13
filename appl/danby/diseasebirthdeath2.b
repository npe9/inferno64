implement Populationmodel;

include "danby/populationmodel.m";

new(): ref Model
{
	parameters := array[] of {2.2, 0.55, 0.035, 0.025, 0.08};
	initial := array[] of {0.99, 0.01, 0.0};
	return ref Model(parameters,initial);
}

title(): string
{
	return "Disease with independent birth, death, and virulence";
}

statelabels(): array of string
{
	return array[] of {"susceptible", "infectious", "recovered"};
}

parameterlabels(): array of string
{
	return array[] of {"contact", "recovery", "birth", "natural death", "virulence"};
}

parameterranges(): array of real
{
	return array[] of {5.0, 2.0, 0.5, 0.5, 0.8};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	susceptible := state[0];
	infectious := state[1];
	recovered := state[2];
	total := susceptible+infectious+recovered;
	if(total < 1.0e-12){
		derivative[0] = 0.0;
		derivative[1] = 0.0;
		derivative[2] = 0.0;
		return;
	}
	infections := p[0]*susceptible*infectious/total;
	derivative[0] = p[2]*total-infections-p[3]*susceptible;
	derivative[1] = infections-(p[1]+p[3]+p[4])*infectious;
	derivative[2] = p[1]*infectious-p[3]*recovered;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

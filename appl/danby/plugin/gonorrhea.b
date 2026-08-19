implement Populationmodel;

include "danby/populationmodel.m";

new(): ref Model
{
	parameters := array[] of {1.6, 1.3, 0.7, 0.8};
	initial := array[] of {0.98, 0.02, 0.99, 0.01};
	return ref Model(parameters,initial);
}

title(): string
{
	return "Two-sex transmission of gonorrhea";
}

statelabels(): array of string
{
	return array[] of {"susceptible women", "infectious women", "susceptible men", "infectious men"};
}

parameterlabels(): array of string
{
	return array[] of {"men to women", "women to men", "recovery women", "recovery men"};
}

parameterranges(): array of real
{
	return array[] of {5.0, 5.0, 3.0, 3.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	infectionswomen := p[0]*state[0]*state[3];
	infectionsmen := p[1]*state[2]*state[1];
	recoverieswomen := p[2]*state[1];
	recoveriesmen := p[3]*state[3];
	derivative[0] = -infectionswomen+recoverieswomen;
	derivative[1] = infectionswomen-recoverieswomen;
	derivative[2] = -infectionsmen+recoveriesmen;
	derivative[3] = infectionsmen-recoveriesmen;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

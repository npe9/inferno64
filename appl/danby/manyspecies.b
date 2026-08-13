implement Populationmodel;

include "danby/populationmodel.m";

new(): ref Model
{
	parameters := array[] of {1.4, 1.8, 1.1, 0.8, 0.5, 0.8, 0.7, 0.4};
	initial := array[] of {0.9, 0.12, 0.08};
	return ref Model(parameters,initial);
}

title(): string
{
	return "One prey and two predator species";
}

statelabels(): array of string
{
	return array[] of {"prey", "predator A", "predator B"};
}

parameterlabels(): array of string
{
	return array[] of {
		"prey growth", "capacity", "attack A", "conversion A",
		"death A", "attack B", "conversion B", "death B"
	};
}

parameterranges(): array of real
{
	return array[] of {3.0, 3.0, 3.0, 2.0, 2.0, 3.0, 2.0, 2.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	x := state[0];
	y := state[1];
	z := state[2];
	consumptiona := p[2]*x*y;
	consumptionb := p[5]*x*z;
	derivative[0] = p[0]*x*(1.0-x/p[1])-consumptiona-consumptionb;
	derivative[1] = p[3]*consumptiona-p[4]*y;
	derivative[2] = p[6]*consumptionb-p[7]*z;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

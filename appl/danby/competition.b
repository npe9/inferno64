implement Twospecies;

include "danby/twospecies.m";

new(): ref Model
{
	return ref Model(array[] of {1.0, 0.8, 0.7});
}

title(): string
{
	return "Competition between two species";
}

parameterlabels(): array of string
{
	return array[] of {"growth A", "growth B", "competition"};
}

parameterranges(): array of real
{
	return array[] of {2.0, 2.0, 2.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	x := state[0];
	y := state[1];
	derivative[0] = p[0]*x*(1.0-x-p[2]*y);
	derivative[1] = p[1]*y*(1.0-y-p[2]*x);
}

Model.equilibrium(model: self ref Model): (real, real)
{
	coupling := model.parameter[2];
	coexistence := 1.0/(1.0+coupling);
	return (coexistence,coexistence);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

fixedpoint(model: ref Model): (real, real)
{
	return model.equilibrium();
}

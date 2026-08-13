implement Twospecies;

include "danby/twospecies.m";

new(): ref Model
{
	return ref Model(array[] of {0.35, 1.0, 0.35, 0.25, 1.0, 0.3});
}

title(): string
{
	return "Cooperation between two species";
}

parameterlabels(): array of string
{
	return array[] of {
		"growth A", "crowding A", "help from B",
		"growth B", "crowding B", "help from A"
	};
}

parameterranges(): array of real
{
	return array[] of {2.0, 2.0, 1.5, 2.0, 2.0, 1.5};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	x := state[0];
	y := state[1];
	derivative[0] = x*(p[0]-p[1]*x+p[2]*y);
	derivative[1] = y*(p[3]-p[4]*y+p[5]*x);
}

Model.equilibrium(model: self ref Model): (real, real)
{
	p := model.parameter;
	denominator := p[1]*p[4]-p[2]*p[5];
	if(denominator <= 0.0)
		return (0.0,0.0);
	first := (p[0]*p[4]+p[2]*p[3])/denominator;
	second := (p[1]*p[3]+p[5]*p[0])/denominator;
	return (first,second);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

fixedpoint(model: ref Model): (real, real)
{
	return model.equilibrium();
}

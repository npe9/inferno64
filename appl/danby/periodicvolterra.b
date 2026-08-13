implement Twospecies;

include "math.m";
	math: Math;
include "danby/twospecies.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {1.5, 2.0, 1.0, 0.75, 0.25, 1.0});
}

title(): string
{
	return "Volterra model with periodic birthrate";
}

parameterlabels(): array of string
{
	return array[] of {
		"mean birth", "predation", "conversion",
		"predator death", "seasonality", "frequency"
	};
}

parameterranges(): array of real
{
	return array[] of {3.0, 4.0, 3.0, 3.0, 0.95, 3.0};
}

Model.rhs(model: self ref Model, t: real,
		state, derivative: array of real)
{
	p := model.parameter;
	birth := p[0]*(1.0+p[4]*math->cos(p[5]*t));
	derivative[0] = birth*state[0]-p[1]*state[0]*state[1];
	derivative[1] = p[2]*state[0]*state[1]-p[3]*state[1];
}

Model.equilibrium(model: self ref Model): (real, real)
{
	p := model.parameter;
	return (p[3]/p[2],p[0]/p[1]);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

fixedpoint(model: ref Model): (real, real)
{
	return model.equilibrium();
}

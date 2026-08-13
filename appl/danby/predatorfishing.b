implement Twospecies;

include "danby/twospecies.m";

new(): ref Model
{
	return ref Model(array[] of {1.5, 2.0, 1.0, 0.75, 0.2});
}

title(): string
{
	return "Predator-prey model with fishing";
}

parameterlabels(): array of string
{
	return array[] of {
		"prey birth", "predation", "conversion",
		"predator death", "fishing effort"
	};
}

parameterranges(): array of real
{
	return array[] of {3.0, 4.0, 3.0, 3.0, 1.4};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	effort := p[4];
	derivative[0] = state[0]*(p[0]-effort-p[1]*state[1]);
	derivative[1] = state[1]*(p[2]*state[0]-p[3]-effort);
}

Model.equilibrium(model: self ref Model): (real, real)
{
	p := model.parameter;
	return ((p[3]+p[4])/p[2],(p[0]-p[4])/p[1]);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

fixedpoint(model: ref Model): (real, real)
{
	return model.equilibrium();
}

implement Twospecies;

include "danby/twospecies.m";

new(): ref Model
{
	return ref Model(array[] of {1.5, 1.5, 2.0, 1.0, 0.75, 1.2});
}

title(): string
{
	return "Predator-prey with logistic regulation of both species";
}

parameterlabels(): array of string
{
	return array[] of {
		"prey growth", "prey capacity", "predation",
		"conversion", "predator death", "predator capacity"
	};
}

parameterranges(): array of real
{
	return array[] of {3.0, 3.0, 4.0, 3.0, 3.0, 3.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	derivative[0] = p[0]*state[0]*(1.0-state[0]/p[1])
		-p[2]*state[0]*state[1];
	derivative[1] = state[1]*(p[3]*state[0]-p[4])
		*(1.0-state[1]/p[5]);
}

Model.equilibrium(model: self ref Model): (real, real)
{
	p := model.parameter;
	prey := p[4]/p[3];
	predators := p[0]*(1.0-prey/p[1])/p[2];
	return (prey,predators);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

fixedpoint(model: ref Model): (real, real)
{
	return model.equilibrium();
}

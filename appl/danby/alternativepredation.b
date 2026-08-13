implement Twospecies;

include "danby/twospecies.m";

new(): ref Model
{
	return ref Model(array[] of {1.2, 2.0, 1.0, 0.6, 0.5});
}

title(): string
{
	return "Predator-prey with saturating predation";
}

parameterlabels(): array of string
{
	return array[] of {
		"prey birth", "attack", "conversion",
		"predator death", "handling"
	};
}

parameterranges(): array of real
{
	return array[] of {3.0, 4.0, 3.0, 2.0, 2.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	consumption := p[1]*state[0]*state[1]/(1.0+p[4]*state[0]);
	derivative[0] = p[0]*state[0]-consumption;
	derivative[1] = p[2]*consumption-p[3]*state[1];
}

Model.equilibrium(model: self ref Model): (real, real)
{
	p := model.parameter;
	denominator := p[2]*p[1]-p[3]*p[4];
	if(denominator <= 0.0)
		return (0.0,0.0);
	prey := p[3]/denominator;
	predators := p[0]*(1.0+p[4]*prey)/p[1];
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

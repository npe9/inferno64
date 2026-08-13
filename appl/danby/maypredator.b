implement Twospecies;

include "math.m";
	math: Math;
include "danby/twospecies.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {1.0, 2.0, 1.2, 0.3, 0.8, 0.7});
}

title(): string
{
	return "May predator-prey limit cycles";
}

parameterlabels(): array of string
{
	return array[] of {
		"prey growth", "prey capacity", "attack",
		"half saturation", "predator growth", "prey support"
	};
}

parameterranges(): array of real
{
	return array[] of {3.0, 4.0, 4.0, 2.0, 3.0, 2.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	x := state[0];
	y := state[1];
	derivative[0] = p[0]*x*(1.0-x/p[1])-p[2]*x*y/(x+p[3]);
	if(x <= 1.0e-12){
		derivative[1] = -p[4]*y;
		return;
	}
	derivative[1] = p[4]*y*(1.0-y/(p[5]*x));
}

Model.equilibrium(model: self ref Model): (real, real)
{
	p := model.parameter;
	b := p[0]*p[1]-p[0]*p[3]-p[2]*p[5]*p[1];
	discriminant := b*b+4.0*p[0]*p[0]*p[3]*p[1];
	prey := (b+math->sqrt(discriminant))/(2.0*p[0]);
	return (prey,p[5]*prey);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

fixedpoint(model: ref Model): (real, real)
{
	return model.equilibrium();
}

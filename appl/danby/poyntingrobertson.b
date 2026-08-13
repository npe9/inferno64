implement Orbital;

include "math.m";
	math: Math;
include "danby/orbital.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {1.0,1.0,0.015,0.18,0.001,1.0},array[] of {1.0,0.0});
}

title(): string
{
	return "The Poynting-Robertson effect";
}

parameterlabels(): array of string
{
	return array[] of {"radius", "speed", "radiation drag", "radiation pressure", "softening", "gravity"};
}

parameterminima(): array of real
{
	return array[] of {0.3,0.2,0.0,0.0,0.0001,0.2};
}

parametermaxima(): array of real
{
	return array[] of {3.0,2.0,0.08,0.8,0.02,2.0};
}

bodylabels(): array of string
{
	return array[] of {"Sun", "dust"};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	return array[] of {0.0,0.0,0.0,0.0,p[0],0.0,0.0,p[1]};
}

maxtime(nil: ref Model): real
{
	return 100.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	x := state[4];
	y := state[5];
	vx := state[6];
	vy := state[7];
	r2 := x*x+y*y+p[4]*p[4];
	r := math->sqrt(r2);
	gravityfactor := -p[5]*(1.0-p[3])/(r2*r);
	dragfactor := -p[2]/r2;
	for(i := 0; i < 4; i++)
		derivative[i] = 0.0;
	derivative[4] = vx;
	derivative[5] = vy;
	derivative[6] = gravityfactor*x+dragfactor*vx;
	derivative[7] = gravityfactor*y+dragfactor*vy;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

observablelabels(): array of string
{
	return array[] of {"radius", "angular momentum"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {math->sqrt(state[4]*state[4]+state[5]*state[5]),
		state[4]*state[7]-state[5]*state[6]};
}

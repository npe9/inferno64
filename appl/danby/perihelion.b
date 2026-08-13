implement Orbital;

include "math.m";
	math: Math;
include "danby/orbital.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {1.0,0.72,1.15,0.012,0.001,0.0},array[] of {1.0,0.0});
}

title(): string
{
	return "Relativistic motion of planetary perihelion";
}

parameterlabels(): array of string
{
	return array[] of {"gravity", "perihelion", "speed", "relativity", "softening", "velocity offset"};
}

parameterminima(): array of real
{
	return array[] of {0.2,0.2,0.2,0.0,0.0001,-0.3};
}

parametermaxima(): array of real
{
	return array[] of {2.0,1.5,2.0,0.08,0.02,0.3};
}

bodylabels(): array of string
{
	return array[] of {"Sun", "planet"};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	return array[] of {0.0,0.0,0.0,0.0,p[1],0.0,0.0,p[2]+p[5]};
}

maxtime(nil: ref Model): real
{
	return 80.0;
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
	h := x*vy-y*vx;
	factor := -p[0]/(r2*r)*(1.0+3.0*p[3]*h*h/r2);
	for(i := 0; i < 4; i++)
		derivative[i] = 0.0;
	derivative[4] = vx;
	derivative[5] = vy;
	derivative[6] = factor*x;
	derivative[7] = factor*y;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

observablelabels(): array of string
{
	return array[] of {"radius", "orbit angle"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {math->sqrt(state[4]*state[4]+state[5]*state[5]),
		math->atan2(state[5],state[4])};
}

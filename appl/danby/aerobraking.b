implement Orbital;

include "math.m";
	math: Math;
include "danby/atmosphere.m";
	atmosphere: Atmosphere;
include "danby/orbital.m";

new(): ref Model
{
	math = load Math Math->PATH;
	atmosphere = load Atmosphere Atmosphere->PATH;
	return ref Model(array[] of {1.18,0.88,0.025,0.08,1.0,0.012},
		array[] of {1.0,0.0});
}

title(): string
{
	return "Aerobraking the orbit of a spacecraft";
}

parameterlabels(): array of string
{
	return array[] of {"apoapsis", "speed", "atmosphere", "scale height", "gravity", "drag area"};
}

parameterminima(): array of real
{
	return array[] of {1.02,0.3,0.0,0.01,0.2,0.0};
}

parametermaxima(): array of real
{
	return array[] of {2.0,1.5,0.2,0.3,2.0,0.08};
}

bodylabels(): array of string
{
	return array[] of {"planet", "craft"};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	return array[] of {0.0,0.0,0.0,0.0,p[0],0.0,0.0,p[1]};
}

maxtime(nil: ref Model): real
{
	return 30.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	x := state[4];
	y := state[5];
	vx := state[6];
	vy := state[7];
	r := math->sqrt(x*x+y*y);
	inversecube := 1.0/(r*r*r);
	altitude := r-1.0;
	(ax, ay) := atmosphere->drag2(vx,vy,altitude,1.0,p[5],1.0,p[2],p[3]);
	derivative[0] = 0.0;
	derivative[1] = 0.0;
	derivative[2] = 0.0;
	derivative[3] = 0.0;
	derivative[4] = vx;
	derivative[5] = vy;
	derivative[6] = -p[4]*x*inversecube+ax;
	derivative[7] = -p[4]*y*inversecube+ay;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

observablelabels(): array of string
{
	return array[] of {"radius", "speed"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {math->sqrt(state[4]*state[4]+state[5]*state[5]),
		math->sqrt(state[6]*state[6]+state[7]*state[7])};
}

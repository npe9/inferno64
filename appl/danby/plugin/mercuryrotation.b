implement Mechanism;

include "math.m";
	math: Math;
include "danby/spinorbit.m";
	spinorbit: Spinorbit;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	spinorbit = load Spinorbit Spinorbit->PATH;
	return ref Model(array[] of {1.0,0.206,0.018,1.5,0.015});
}

title(): string
{
	return "The 3:2 rotation of Mercury";
}

parameterlabels(): array of string
{
	return array[] of {"mean motion", "eccentricity", "triaxiality", "initial spin", "tides"};
}

parameterminima(): array of real
{
	return array[] of {0.05,0.0,0.0,0.0,0.0};
}

parametermaxima(): array of real
{
	return array[] of {3.0,0.8,0.5,4.0,0.5};
}

initialstate(model: ref Model): array of real
{
	return array[] of {0.0,0.0,model.parameter[3]*model.parameter[0]};
}

maxtime(nil: ref Model): real
{
	return 55.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	spinorbit->derivatives(state,derivative,p[0],p[1],p[2],p[4]);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	r := spinorbit->radius(state[0],model.parameter[1]);
	cx := r*math->cos(state[0]);
	cy := r*math->sin(state[0]);
	dx := 0.18*math->cos(state[1]);
	dy := 0.18*math->sin(state[1]);
	return array[] of {0.0,0.0,cx-dx,cy-dy,cx+dx,cy+dy,cx,cy};
}

links(): array of int
{
	return array[] of {1,2,0,3};
}

observablelabels(): array of string
{
	return array[] of {"resonant angle", "spin/orbit"};
}

observables(model: ref Model, state: array of real): array of real
{
	return array[] of {2.0*state[1]-3.0*state[0],state[2]/model.parameter[0]};
}

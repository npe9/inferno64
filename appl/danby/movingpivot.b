implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {1.2,0.18,9.81,0.06,0.22,6.0});
}

title(): string
{
	return "A pendulum with moving pivot";
}

parameterlabels(): array of string
{
	return array[] of {"length", "initial angle", "gravity", "damping", "pivot amplitude", "drive rate"};
}

parameterminima(): array of real
{
	return array[] of {0.2,-2.0,0.1,0.0,0.0,0.1};
}

parametermaxima(): array of real
{
	return array[] of {4.0,2.0,20.0,1.5,1.0,12.0};
}

initialstate(model: ref Model): array of real
{
	return array[] of {model.parameter[1],0.0,0.0};
}

maxtime(nil: ref Model): real
{
	return 30.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	pivotaccel := -p[4]*p[5]*p[5]*math->sin(state[2]);
	derivative[0] = state[1];
	derivative[1] = -(p[2]+pivotaccel)*math->sin(state[0])/p[0]-
		p[3]*state[1];
	derivative[2] = p[5];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	p := model.parameter;
	pivoty := p[4]*math->sin(state[2]);
	x := p[0]*math->sin(state[0]);
	y := pivoty-p[0]*math->cos(state[0]);
	return array[] of {0.0,pivoty,x,y,-0.7,pivoty,0.7,pivoty};
}

links(): array of int
{
	return array[] of {0,1,2,3};
}

observablelabels(): array of string
{
	return array[] of {"angle", "pivot height"};
}

observables(model: ref Model, state: array of real): array of real
{
	return array[] of {state[0],model.parameter[4]*math->sin(state[2])};
}

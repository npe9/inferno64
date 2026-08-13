implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {2.0,0.35,9.81,0.12,0.18,1.1});
}

title(): string
{
	return "A child on a swing: changing centre of mass";
}

parameterlabels(): array of string
{
	return array[] of {"length", "initial angle", "gravity", "damping", "pump", "pump rate"};
}

parameterminima(): array of real
{
	return array[] of {0.4,-1.2,0.1,0.0,0.0,0.1};
}

parametermaxima(): array of real
{
	return array[] of {5.0,1.2,20.0,1.0,0.45,5.0};
}

initialstate(model: ref Model): array of real
{
	return array[] of {model.parameter[1],0.0,0.0};
}

maxtime(nil: ref Model): real
{
	return 35.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	length := p[0]*(1.0-p[4]*math->cos(2.0*state[2]));
	lengthrate := 2.0*p[0]*p[4]*p[5]*math->sin(2.0*state[2]);
	derivative[0] = state[1];
	derivative[1] = -2.0*lengthrate*state[1]/length-
		p[2]*math->sin(state[0])/length-p[3]*state[1];
	derivative[2] = p[5];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	p := model.parameter;
	l := p[0]*(1.0-p[4]*math->cos(2.0*state[2]));
	x := l*math->sin(state[0]);
	y := -l*math->cos(state[0]);
	return array[] of {0.0,0.0,x,y,x,y+0.28,-0.7,0.0,0.7,0.0};
}

links(): array of int
{
	return array[] of {0,1,1,2,3,4};
}

observablelabels(): array of string
{
	return array[] of {"angle", "angular speed"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[1]};
}

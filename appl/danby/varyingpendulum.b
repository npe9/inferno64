implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {2.0,0.45,9.81,0.08,0.35,1.4});
}

title(): string
{
	return "A pendulum with varying length";
}

parameterlabels(): array of string
{
	return array[] of {"mean length", "initial angle", "gravity", "damping", "variation", "rate"};
}

parameterminima(): array of real
{
	return array[] of {0.4,-2.0,0.1,0.0,0.0,0.1};
}

parametermaxima(): array of real
{
	return array[] of {5.0,2.0,20.0,1.0,0.8,6.0};
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
	length := p[0]*(1.0+p[4]*math->sin(state[2]));
	lengthrate := p[0]*p[4]*p[5]*math->cos(state[2]);
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
	l := p[0]*(1.0+p[4]*math->sin(state[2]));
	x := l*math->sin(state[0]);
	y := -l*math->cos(state[0]);
	return array[] of {0.0,0.0,x,y,-0.7,0.0,0.7,0.0};
}

links(): array of int
{
	return array[] of {0,1,2,3};
}

observablelabels(): array of string
{
	return array[] of {"angle", "length"};
}

observables(model: ref Model, state: array of real): array of real
{
	l := model.parameter[0]*(1.0+model.parameter[4]*math->sin(state[2]));
	return array[] of {state[0],l};
}

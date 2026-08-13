implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {1.0,0.8,1.0,0.03});
}

title(): string
{
	return "A gravity-gradient pendulum";
}

parameterlabels(): array of string
{
	return array[] of {"length", "initial angle", "orbital rate", "damping"};
}

parameterminima(): array of real
{
	return array[] of {0.1,-3.0,0.05,0.0};
}

parametermaxima(): array of real
{
	return array[] of {4.0,3.0,3.0,1.0};
}

initialstate(model: ref Model): array of real
{
	return array[] of {model.parameter[1],0.0};
}

maxtime(nil: ref Model): real
{
	return 30.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	derivative[0] = state[1];
	derivative[1] = -1.5*p[2]*p[2]*math->sin(2.0*state[0])-p[3]*state[1];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	h := model.parameter[0]/2.0;
	x := h*math->sin(state[0]);
	y := h*math->cos(state[0]);
	return array[] of {-x,-y,x,y,-1.4,0.0,1.4,0.0,0.0,0.0};
}

links(): array of int
{
	return array[] of {0,1,2,4,4,3};
}

observablelabels(): array of string
{
	return array[] of {"attitude", "angular speed"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[1]};
}

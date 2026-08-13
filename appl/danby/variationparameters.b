implement Mechanism;

include "math.m";
	math: Math;
include "danby/oscillator.m";
	oscillator: Oscillator;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	oscillator = load Oscillator Oscillator->PATH;
	return ref Model(array[] of {0.35,1.0,0.35,0.0});
}

title(): string
{
	return "Variation of parameters for Van der Pol";
}

parameterlabels(): array of string
{
	return array[] of {"mu", "frequency", "initial amplitude", "initial phase"};
}

parameterminima(): array of real
{
	return array[] of {0.01,0.1,0.05,-3.14};
}

parametermaxima(): array of real
{
	return array[] of {2.0,5.0,4.0,3.14};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	x := p[2]*math->cos(p[3]);
	v := -p[2]*p[1]*math->sin(p[3]);
	return array[] of {x,v,p[2],p[3]};
}

maxtime(nil: ref Model): real
{
	return 60.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	derivative[0] = state[1];
	derivative[1] = oscillator->vanderpol(state[0],state[1],p[0],p[1]);
	derivative[2] = 0.5*p[0]*state[2]*(1.0-state[2]*state[2]/4.0);
	derivative[3] = p[1];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(nil: ref Model, state: array of real): array of real
{
	approximation := state[2]*math->cos(state[3]);
	return array[] of {-2.0,0.0,state[0],0.0,-2.0,-0.5,approximation,-0.5};
}

links(): array of int
{
	return array[] of {0,1,2,3};
}

observablelabels(): array of string
{
	return array[] of {"numerical x", "averaged x"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[2]*math->cos(state[3])};
}

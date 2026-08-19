implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {1.0,0.18,1.35,1.1,0.25,9.81});
}

title(): string
{
	return "Chaos in the amusement park";
}

parameterlabels(): array of string
{
	return array[] of {"arm length", "damping", "drive", "frequency", "pivot motion", "gravity"};
}

parameterminima(): array of real
{
	return array[] of {0.3,0.0,0.0,0.1,0.0,0.0};
}

parametermaxima(): array of real
{
	return array[] of {3.0,1.0,4.0,4.0,1.0,20.0};
}

initialstate(nil: ref Model): array of real
{
	return array[] of {0.3,0.0};
}

maxtime(nil: ref Model): real
{
	return 40.0;
}

Model.rhs(model: self ref Model, t: real, state, derivative: array of real)
{
	p := model.parameter;
	derivative[0] = state[1];
	derivative[1] = -p[5]/p[0]*math->sin(state[0])-p[1]*state[1]+
		p[2]*math->cos(p[3]*t)-p[4]*math->sin(2.0*p[3]*t)*math->cos(state[0]);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	length := model.parameter[0];
	return array[] of {0.0,0.0,length*math->sin(state[0]),
		-length*math->cos(state[0]),-0.8,0.0,0.8,0.0};
}

links(): array of int
{
	return array[] of {0,1,2,3};
}

observablelabels(): array of string
{
	return array[] of {"angle", "angular speed"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[1]};
}

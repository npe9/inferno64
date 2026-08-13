implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {1.0,9.81,0.35,2.5,0.8,0.18});
}

title(): string
{
	return "Watt's governor";
}

parameterlabels(): array of string
{
	return array[] of {"arm length", "gravity", "angle damping", "drive torque", "load gain", "speed damping"};
}

parameterminima(): array of real
{
	return array[] of {0.2,0.1,0.0,0.0,0.0,0.0};
}

parametermaxima(): array of real
{
	return array[] of {4.0,20.0,2.0,10.0,5.0,2.0};
}

initialstate(nil: ref Model): array of real
{
	return array[] of {0.25,0.0,0.8};
}

maxtime(nil: ref Model): real
{
	return 35.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	angle := state[0];
	spin := state[2];
	derivative[0] = state[1];
	derivative[1] = spin*spin*math->sin(angle)*math->cos(angle)-
		p[1]*math->sin(angle)/p[0]-p[2]*state[1];
	derivative[2] = p[3]-p[4]*(1.0-math->cos(angle))-p[5]*spin;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	l := model.parameter[0];
	x := l*math->sin(state[0]);
	y := -l*math->cos(state[0]);
	return array[] of {0.0,0.0,x,y,-x,y,0.0,-1.5*l,0.0,0.5*l};
}

links(): array of int
{
	return array[] of {0,1,0,2,3,4};
}

observablelabels(): array of string
{
	return array[] of {"arm angle", "shaft speed"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[2]};
}

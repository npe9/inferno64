implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {620.0,12.0,55.0,4.0,18.0,9.81});
}

title(): string
{
	return "The motion of a balloon and its payload";
}

parameterlabels(): array of string
{
	return array[] of {"buoyancy", "drag", "balloon mass", "tether", "payload mass", "gravity"};
}

parameterminima(): array of real
{
	return array[] of {0.0,0.0,10.0,1.0,1.0,0.0};
}

parametermaxima(): array of real
{
	return array[] of {1500.0,60.0,150.0,10.0,80.0,20.0};
}

initialstate(nil: ref Model): array of real
{
	return array[] of {2.0,0.0,0.25,0.0};
}

maxtime(nil: ref Model): real
{
	return 30.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	totalmass := p[2]+p[4];
	derivative[0] = state[1];
	derivative[1] = (p[0]-totalmass*p[5]-p[1]*state[1])/totalmass;
	derivative[2] = state[3];
	derivative[3] = -p[5]/p[3]*math->sin(state[2])-0.18*state[3]-
		derivative[1]*math->sin(state[2])/p[3];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	length := model.parameter[3];
	x := length*math->sin(state[2]);
	y := state[0]-length*math->cos(state[2]);
	return array[] of {
		0.0,state[0],
		x,y,
		-0.7,state[0],
		0.7,state[0],
		0.0,state[0]+1.0
	};
}

links(): array of int
{
	return array[] of {0,1,2,4,4,3,3,2};
}

observablelabels(): array of string
{
	return array[] of {"altitude", "payload swing"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[2]};
}

implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {1.4,0.25,9.81,0.12,2.0,1.8});
}

title(): string
{
	return "A swinging censer";
}

parameterlabels(): array of string
{
	return array[] of {"chain", "initial angle", "gravity", "damping", "hand accel", "rhythm"};
}

parameterminima(): array of real
{
	return array[] of {0.3,-1.5,0.1,0.0,0.0,0.1};
}

parametermaxima(): array of real
{
	return array[] of {4.0,1.5,20.0,1.5,12.0,6.0};
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
	horizontalaccel := p[4]*math->cos(state[2]);
	derivative[0] = state[1];
	derivative[1] = (-p[2]*math->sin(state[0])-
		horizontalaccel*math->cos(state[0]))/p[0]-p[3]*state[1];
	derivative[2] = p[5];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	p := model.parameter;
	handx := 0.3*math->sin(state[2]);
	x := handx+p[0]*math->sin(state[0]);
	y := -p[0]*math->cos(state[0]);
	return array[] of {handx,0.0,x,y,-0.8,0.0,0.8,0.0,x-0.16,y,x+0.16,y};
}

links(): array of int
{
	return array[] of {0,1,2,3,4,5};
}

observablelabels(): array of string
{
	return array[] of {"angle", "angular speed"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[1]};
}

implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {2.0,0.25,9.81,0.12,1.0,2.2});
}

title(): string
{
	return "A child on a swing: rhythmic torque";
}

parameterlabels(): array of string
{
	return array[] of {"length", "initial angle", "gravity", "damping", "torque", "drive rate"};
}

parameterminima(): array of real
{
	return array[] of {0.4,-1.2,0.1,0.0,0.0,0.1};
}

parametermaxima(): array of real
{
	return array[] of {5.0,1.2,20.0,1.0,8.0,6.0};
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
	derivative[0] = state[1];
	derivative[1] = -p[2]*math->sin(state[0])/p[0]-p[3]*state[1]+
		p[4]*math->sin(state[2])/(p[0]*p[0]);
	derivative[2] = p[5];
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
	lean := 0.3*math->sin(state[2]);
	return array[] of {0.0,0.0,x,y,x+lean,y+0.32,-0.7,0.0,0.7,0.0};
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

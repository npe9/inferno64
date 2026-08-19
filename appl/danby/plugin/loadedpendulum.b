implement Mechanism;

include "math.m";
	math: Math;
include "danby/pendulum.m";
	pendulum: Pendulum;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	pendulum = load Pendulum Pendulum->PATH;
	return ref Model(array[] of {1.0,0.0,0.12,9.81,2.5,1.0});
}

title(): string
{
	return "The simple pendulum with added constant load";
}

parameterlabels(): array of string
{
	return array[] of {"length", "initial angle", "damping", "gravity", "load torque", "mass"};
}

parameterminima(): array of real
{
	return array[] of {0.1,-3.0,0.0,0.1,-15.0,0.1};
}

parametermaxima(): array of real
{
	return array[] of {4.0,3.0,2.0,20.0,15.0,5.0};
}

initialstate(model: ref Model): array of real
{
	return array[] of {model.parameter[1],0.0};
}

maxtime(nil: ref Model): real
{
	return 30.0;
}

Model.rhs(model: self ref Model, t: real, state, derivative: array of real)
{
	p := model.parameter;
	derivative[0] = state[1];
	derivative[1] = pendulum->acceleration(t,state[0],state[1],p[0],p[3],
		p[2],0.0,p[4]/(p[5]*p[0]*p[0]),0.0,0.0,1.0);
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
	return array[] of {0.0,0.0,x,y,-0.7,0.0,0.7,0.0,x,y,x+0.6,y};
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

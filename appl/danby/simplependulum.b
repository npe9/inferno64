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
	return ref Model(array[] of {1.0,0.7,0.0,9.81,1.0,0.0});
}

title(): string
{
	return "The simple pendulum";
}

parameterlabels(): array of string
{
	return array[] of {"length", "initial angle", "initial speed", "gravity", "mass", "reference"};
}

parameterminima(): array of real
{
	return array[] of {0.1,-3.0,-8.0,0.1,0.1,0.0};
}

parametermaxima(): array of real
{
	return array[] of {4.0,3.0,8.0,20.0,5.0,1.0};
}

initialstate(model: ref Model): array of real
{
	return array[] of {model.parameter[1],model.parameter[2]};
}

maxtime(nil: ref Model): real
{
	return 20.0;
}

Model.rhs(model: self ref Model, t: real, state, derivative: array of real)
{
	p := model.parameter;
	derivative[0] = state[1];
	derivative[1] = pendulum->acceleration(t,state[0],state[1],p[0],p[3],
		0.0,0.0,0.0,0.0,0.0,1.0);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	length := model.parameter[0];
	return array[] of {0.0,0.0,length*math->sin(state[0]),
		-length*math->cos(state[0]),-0.7,0.0,0.7,0.0};
}

links(): array of int
{
	return array[] of {0,1,2,3};
}

observablelabels(): array of string
{
	return array[] of {"angle", "energy"};
}

observables(model: ref Model, state: array of real): array of real
{
	return array[] of {state[0],pendulum->energy(state[0],state[1],
		model.parameter[0],model.parameter[3])};
}

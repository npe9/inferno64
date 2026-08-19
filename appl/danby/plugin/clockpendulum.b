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
	return ref Model(array[] of {1.0,0.45,0.08,9.81,0.04,0.18});
}

title(): string
{
	return "The pendulum of a clock";
}

parameterlabels(): array of string
{
	return array[] of {"length", "initial angle", "damping", "gravity", "escapement width", "impulse"};
}

parameterminima(): array of real
{
	return array[] of {0.1,-2.0,0.0,0.1,0.005,0.0};
}

parametermaxima(): array of real
{
	return array[] of {4.0,2.0,1.0,20.0,0.4,2.0};
}

initialstate(model: ref Model): array of real
{
	return array[] of {model.parameter[1],0.0};
}

maxtime(nil: ref Model): real
{
	return 40.0;
}

Model.rhs(model: self ref Model, t: real, state, derivative: array of real)
{
	p := model.parameter;
	escapement := 0.0;
	if(math->fabs(state[0]) < p[4]){
		if(state[1] >= 0.0)
			escapement = p[5];
		else
			escapement = -p[5];
	}
	derivative[0] = state[1];
	derivative[1] = pendulum->acceleration(t,state[0],state[1],p[0],p[3],
		p[2],0.0,escapement,0.0,0.0,1.0);
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
	return array[] of {0.0,0.0,x,y,-0.7,0.0,0.7,0.0,x-0.22,y,x+0.22,y};
}

links(): array of int
{
	return array[] of {0,1,2,3,4,5};
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

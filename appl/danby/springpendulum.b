implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {1.0,1.2,12.0,9.81,0.08,0.45});
}

title(): string
{
	return "A spring pendulum";
}

parameterlabels(): array of string
{
	return array[] of {"mass", "rest length", "spring", "gravity", "damping", "initial angle"};
}

parameterminima(): array of real
{
	return array[] of {0.1,0.2,0.1,0.1,0.0,-2.5};
}

parametermaxima(): array of real
{
	return array[] of {8.0,4.0,50.0,20.0,2.0,2.5};
}

initialstate(model: ref Model): array of real
{
	return array[] of {model.parameter[1],0.0,model.parameter[5],0.0};
}

maxtime(nil: ref Model): real
{
	return 35.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	r := state[0];
	if(r < 0.08)
		r = 0.08;
	derivative[0] = state[1];
	derivative[1] = r*state[3]*state[3]+p[3]*math->cos(state[2])-
		p[2]*(r-p[1])/p[0]-p[4]*state[1];
	derivative[2] = state[3];
	derivative[3] = -(p[3]*math->sin(state[2])+2.0*state[1]*state[3])/r-
		p[4]*state[3];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(nil: ref Model, state: array of real): array of real
{
	x := state[0]*math->sin(state[2]);
	y := -state[0]*math->cos(state[2]);
	return array[] of {0.0,0.0,x,y,-0.7,0.0,0.7,0.0};
}

links(): array of int
{
	return array[] of {0,1,2,3};
}

observablelabels(): array of string
{
	return array[] of {"length", "angle"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[2]};
}

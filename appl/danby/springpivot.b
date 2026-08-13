implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {1.0,1.0,1.4,8.0,9.81,0.08,0.5});
}

title(): string
{
	return "A pendulum with a spring pivot";
}

parameterlabels(): array of string
{
	return array[] of {"pivot mass", "bob mass", "length", "spring", "gravity", "damping", "initial angle"};
}

parameterminima(): array of real
{
	return array[] of {0.1,0.1,0.2,0.1,0.1,0.0,-2.5};
}

parametermaxima(): array of real
{
	return array[] of {8.0,8.0,4.0,30.0,20.0,2.0,2.5};
}

initialstate(model: ref Model): array of real
{
	return array[] of {0.0,0.0,model.parameter[6],0.0};
}

maxtime(nil: ref Model): real
{
	return 30.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	s := math->sin(state[2]);
	c := math->cos(state[2]);
	pivotaccel := (-p[3]*state[0]-p[5]*state[1]+
		p[1]*p[2]*state[3]*state[3]*s+p[1]*p[4]*s*c)/
		(p[0]+p[1]*s*s);
	derivative[0] = state[1];
	derivative[1] = pivotaccel;
	derivative[2] = state[3];
	derivative[3] = (-pivotaccel*c-p[4]*s)/p[2]-p[5]*state[3];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	l := model.parameter[2];
	x := state[0]+l*math->sin(state[2]);
	y := -l*math->cos(state[2]);
	return array[] of {state[0],0.0,x,y,-2.0,0.0,state[0],0.0};
}

links(): array of int
{
	return array[] of {0,1,2,3};
}

observablelabels(): array of string
{
	return array[] of {"pivot position", "angle"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[2]};
}

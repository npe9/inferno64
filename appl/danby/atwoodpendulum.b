implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {1.0,1.6,2.0,0.45,9.81,0.03});
}

title(): string
{
	return "The swinging Atwood machine";
}

parameterlabels(): array of string
{
	return array[] of {"swinging mass", "counterweight", "initial radius", "initial angle", "gravity", "damping"};
}

parameterminima(): array of real
{
	return array[] of {0.1,0.1,0.3,-2.5,0.1,0.0};
}

parametermaxima(): array of real
{
	return array[] of {8.0,8.0,5.0,2.5,20.0,1.0};
}

initialstate(model: ref Model): array of real
{
	return array[] of {model.parameter[2],0.0,model.parameter[3],0.0};
}

maxtime(nil: ref Model): real
{
	return 25.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	r := state[0];
	if(r < 0.08)
		r = 0.08;
	radialaccel := (p[0]*r*state[3]*state[3]+p[0]*p[4]*math->cos(state[2])-
		p[1]*p[4]-p[5]*state[1])/(p[0]+p[1]);
	derivative[0] = state[1];
	derivative[1] = radialaccel;
	derivative[2] = state[3];
	derivative[3] = -(p[4]*math->sin(state[2])+2.0*state[1]*state[3])/r;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	r := state[0];
	if(r < 0.08)
		r = 0.08;
	x := r*math->sin(state[2]);
	y := -r*math->cos(state[2]);
	countery := -(2.0*model.parameter[2]-r);
	return array[] of {0.0,0.0,x,y,0.5,0.0,0.5,countery,-0.25,0.0,0.75,0.0};
}

links(): array of int
{
	return array[] of {0,1,0,2,2,3,4,5};
}

observablelabels(): array of string
{
	return array[] of {"swing radius", "angle"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[2]};
}

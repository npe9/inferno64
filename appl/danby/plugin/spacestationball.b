implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {8.0,0.35,2.0,0.4,0.02,1.0});
}

title(): string
{
	return "Playing ball in a space station";
}

parameterlabels(): array of string
{
	return array[] of {"station radius", "rotation", "throw speed", "throw angle", "drag", "ball mass"};
}

parameterminima(): array of real
{
	return array[] of {2.0,-1.0,0.0,-3.14,0.0,0.1};
}

parametermaxima(): array of real
{
	return array[] of {20.0,1.0,8.0,3.14,0.2,5.0};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	return array[] of {0.0,0.7*p[0],p[2]*math->cos(p[3]),p[2]*math->sin(p[3])};
}

maxtime(nil: ref Model): real
{
	return 20.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	omega := p[1];
	derivative[0] = state[2];
	derivative[1] = state[3];
	derivative[2] = 2.0*omega*state[3]+omega*omega*state[0]-
		p[4]*state[2]/p[5];
	derivative[3] = -2.0*omega*state[2]+omega*omega*state[1]-
		p[4]*state[3]/p[5];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	r := model.parameter[0];
	return array[] of {
		-r,0.0,-0.7*r,-0.7*r,0.0,-r,0.7*r,-0.7*r,r,0.0,
		0.7*r,0.7*r,0.0,r,-0.7*r,0.7*r,state[0],state[1]
	};
}

links(): array of int
{
	return array[] of {0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,0};
}

observablelabels(): array of string
{
	return array[] of {"radius", "speed"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {math->sqrt(state[0]*state[0]+state[1]*state[1]),
		math->sqrt(state[2]*state[2]+state[3]*state[3])};
}

implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {900.0,1.8,500.0,0.35,650.0,1.4});
}

title(): string
{
	return "The motion of a hovercraft";
}

parameterlabels(): array of string
{
	return array[] of {"thrust", "drag", "mass", "rudder", "inertia", "yaw damping"};
}

parameterminima(): array of real
{
	return array[] of {0.0,0.0,100.0,-1.0,100.0,0.0};
}

parametermaxima(): array of real
{
	return array[] of {2500.0,8.0,1200.0,1.0,1500.0,5.0};
}

initialstate(nil: ref Model): array of real
{
	return array[] of {0.0,0.0,0.0,0.0,0.0,0.0};
}

maxtime(nil: ref Model): real
{
	return 25.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	heading := state[4];
	derivative[0] = state[2];
	derivative[1] = state[3];
	derivative[2] = (p[0]*math->cos(heading)-p[1]*state[2])/p[2];
	derivative[3] = (p[0]*math->sin(heading)-p[1]*state[3])/p[2];
	derivative[4] = state[5];
	derivative[5] = (p[0]*p[3]-p[5]*state[5])/p[4];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(nil: ref Model, state: array of real): array of real
{
	c := math->cos(state[4]);
	s := math->sin(state[4]);
	return array[] of {
		1.0*c,1.0*s,
		-0.7*c-0.6*s,-0.7*s+0.6*c,
		-0.7*c+0.6*s,-0.7*s-0.6*c,
		0.0,0.0
	};
}

links(): array of int
{
	return array[] of {0,1,1,2,2,0,3,0};
}

observablelabels(): array of string
{
	return array[] of {"speed", "heading"};
}

observables(nil: ref Model, state: array of real): array of real
{
	speed := math->sqrt(state[2]*state[2]+state[3]*state[3]);
	return array[] of {speed,state[4]};
}

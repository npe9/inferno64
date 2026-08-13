implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {0.28,2.4,1.5,0.35,0.8,1.15});
}

title(): string
{
	return "Pitching and rolling at sea";
}

parameterlabels(): array of string
{
	return array[] of {"wave", "roll stiffness", "pitch stiffness", "damping", "roll frequency", "pitch frequency"};
}

parameterminima(): array of real
{
	return array[] of {0.0,0.1,0.1,0.0,0.1,0.1};
}

parametermaxima(): array of real
{
	return array[] of {1.2,6.0,6.0,2.0,3.0,3.0};
}

initialstate(nil: ref Model): array of real
{
	return array[] of {0.15,0.0,-0.08,0.0};
}

maxtime(nil: ref Model): real
{
	return 30.0;
}

Model.rhs(model: self ref Model, t: real, state, derivative: array of real)
{
	p := model.parameter;
	derivative[0] = state[1];
	derivative[1] = p[0]*math->sin(p[4]*t)-p[1]*state[0]-p[3]*state[1];
	derivative[2] = state[3];
	derivative[3] = p[0]*math->sin(p[5]*t+0.7)-p[2]*state[2]-p[3]*state[3];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(nil: ref Model, state: array of real): array of real
{
	cr := math->cos(state[0]);
	sr := math->sin(state[0]);
	cp := math->cos(state[2]);
	sp := math->sin(state[2]);
	return array[] of {
		-2.5-cr,0.8-sr,
		-2.5+cr,0.8+sr,
		-2.5,0.2,
		0.0-sp,0.8-cp,
		3.0+sp,0.8+cp,
		0.0,0.2,
		3.0,0.2
	};
}

links(): array of int
{
	return array[] of {0,1,0,2,2,1,3,4,3,5,5,6,6,4};
}

observablelabels(): array of string
{
	return array[] of {"roll", "pitch"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[2]};
}

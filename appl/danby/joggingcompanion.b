implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {3.2,0.8,1.5,0.7,0.45,70.0});
}

title(): string
{
	return "Jogging with a companion";
}

parameterlabels(): array of string
{
	return array[] of {"leader pace", "response", "spacing", "drag", "coupling", "mass"};
}

parameterminima(): array of real
{
	return array[] of {0.5,0.0,0.2,0.0,0.0,35.0};
}

parametermaxima(): array of real
{
	return array[] of {8.0,3.0,5.0,2.0,2.0,120.0};
}

initialstate(nil: ref Model): array of real
{
	return array[] of {0.0,2.0,-2.5,1.0};
}

maxtime(nil: ref Model): real
{
	return 25.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	separationerror := (state[0]-state[2])-p[2];
	derivative[0] = state[1];
	derivative[1] = p[1]*(p[0]-state[1])-p[3]*state[1]/p[5];
	derivative[2] = state[3];
	derivative[3] = p[1]*(p[0]-state[3])+p[4]*separationerror-
		p[3]*state[3]/p[5];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(nil: ref Model, state: array of real): array of real
{
	separation := state[0]-state[2];
	return array[] of {
		0.0,0.0,0.0,1.0,0.0,1.4,-0.35,0.45,0.35,0.45,
		-separation,0.0,-separation,1.0,-separation,1.4,
		-separation-0.35,0.45,-separation+0.35,0.45
	};
}

links(): array of int
{
	return array[] of {0,1,1,2,1,3,1,4,5,6,6,7,6,8,6,9};
}

observablelabels(): array of string
{
	return array[] of {"leader speed", "separation"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[1],state[0]-state[2]};
}

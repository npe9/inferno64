implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {5.5,0.85,4.0,0.35,0.025,9.81});
}

title(): string
{
	return "Diving";
}

parameterlabels(): array of string
{
	return array[] of {"takeoff", "angle", "angular momentum", "tuck", "drag", "gravity"};
}

parameterminima(): array of real
{
	return array[] of {0.0,0.0,-10.0,0.1,0.0,0.0};
}

parametermaxima(): array of real
{
	return array[] of {12.0,1.5,10.0,1.0,0.1,20.0};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	inertia := 0.15+0.85*p[3];
	return array[] of {0.0,3.0,p[0]*math->cos(p[1]),p[0]*math->sin(p[1]),
		0.0,p[2]/inertia};
}

maxtime(nil: ref Model): real
{
	return 3.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	speed := math->sqrt(state[2]*state[2]+state[3]*state[3]);
	derivative[0] = state[2];
	derivative[1] = state[3];
	derivative[2] = -p[4]*speed*state[2];
	derivative[3] = -p[5]-p[4]*speed*state[3];
	derivative[4] = state[5];
	derivative[5] = -0.08*state[5];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	theta := state[4];
	length := 0.7+0.9*model.parameter[3];
	dx := length*math->sin(theta);
	dy := length*math->cos(theta);
	x := state[0];
	y := state[1];
	return array[] of {
		-1.2,3.0,
		-0.2,3.0,
		x,y,
		x+0.5*dx,y+0.5*dy,
		x-0.5*dx,y-0.5*dy,
		x+0.35*dy,y-0.35*dx,
		x-0.35*dy,y+0.35*dx
	};
}

links(): array of int
{
	return array[] of {0,1,3,2,2,4,2,5,2,6};
}

observablelabels(): array of string
{
	return array[] of {"height", "rotations"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[1],state[4]/(2.0*Math->Pi)};
}

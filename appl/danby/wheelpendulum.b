implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {1.2,1.0,1.8,0.5,0.7,9.81,0.03});
}

title(): string
{
	return "A pendulum attached to a freely spinning wheel";
}

parameterlabels(): array of string
{
	return array[] of {"length", "bob mass", "wheel inertia", "initial angle", "wheel speed", "gravity", "damping"};
}

parameterminima(): array of real
{
	return array[] of {0.2,0.1,0.1,-2.5,-5.0,0.1,0.0};
}

parametermaxima(): array of real
{
	return array[] of {4.0,5.0,10.0,2.5,5.0,20.0,1.0};
}

initialstate(model: ref Model): array of real
{
	return array[] of {model.parameter[3],0.0,0.0,model.parameter[4]};
}

maxtime(nil: ref Model): real
{
	return 30.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	bobinertia := p[1]*p[0]*p[0];
	relative := state[0]-state[2];
	gravitytorque := -p[1]*p[4]*p[0]*math->sin(relative);
	coupling := gravitytorque-p[6]*(state[1]-state[3]);
	derivative[0] = state[1];
	derivative[1] = coupling/bobinertia;
	derivative[2] = state[3];
	derivative[3] = -coupling/p[2];
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
	r := 0.45;
	return array[] of {0.0,0.0,x,y,r*math->cos(state[2]),r*math->sin(state[2]),
		-r*math->cos(state[2]),-r*math->sin(state[2])};
}

links(): array of int
{
	return array[] of {0,1,2,3};
}

observablelabels(): array of string
{
	return array[] of {"pendulum angle", "wheel angle"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[2]};
}

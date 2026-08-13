implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {1.0,0.35,0.12,1.2,0.75,0.3});
}

title(): string
{
	return "A two-magnet toy";
}

parameterlabels(): array of string
{
	return array[] of {"spring", "magnetic strength", "damping", "magnet spacing", "height", "initial x"};
}

parameterminima(): array of real
{
	return array[] of {0.05,0.0,0.0,0.2,0.05,-2.0};
}

parametermaxima(): array of real
{
	return array[] of {8.0,5.0,2.0,3.0,2.0,2.0};
}

initialstate(model: ref Model): array of real
{
	return array[] of {model.parameter[5],0.0};
}

maxtime(nil: ref Model): real
{
	return 35.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	force := -p[0]*state[0]-p[2]*state[1];
	for(side := -1; side <= 1; side += 2){
		dx := real(side)*p[3]-state[0];
		r2 := dx*dx+p[4]*p[4];
		force += p[1]*dx/(r2*math->sqrt(r2));
	}
	derivative[0] = state[1];
	derivative[1] = force;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	d := model.parameter[3];
	h := model.parameter[4];
	return array[] of {state[0],h,-d,0.0,d,0.0,0.0,2.0*h};
}

links(): array of int
{
	return array[] of {0,3};
}

observablelabels(): array of string
{
	return array[] of {"position", "velocity"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[1]};
}

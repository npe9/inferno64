implement Mechanism;

include "danby/oscillator.m";
	oscillator: Oscillator;
include "danby/mechanism.m";

new(): ref Model
{
	oscillator = load Oscillator Oscillator->PATH;
	return ref Model(array[] of {1.0,1.0,0.0,0.8,0.08,1.2});
}

title(): string
{
	return "Non-linear springs";
}

parameterlabels(): array of string
{
	return array[] of {"mass", "linear", "quadratic", "cubic", "damping", "initial x"};
}

parameterminima(): array of real
{
	return array[] of {0.1,-5.0,-5.0,-5.0,0.0,-3.0};
}

parametermaxima(): array of real
{
	return array[] of {5.0,5.0,5.0,5.0,2.0,3.0};
}

initialstate(model: ref Model): array of real
{
	return array[] of {model.parameter[5],0.0};
}

maxtime(nil: ref Model): real
{
	return 30.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	derivative[0] = state[1];
	derivative[1] = oscillator->nonlinear(state[0],state[1],p[0],p[1],p[2],p[3],p[4]);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(nil: ref Model, state: array of real): array of real
{
	return array[] of {-2.0,0.0,state[0],0.0,state[0],-0.3,state[0],0.3};
}

links(): array of int
{
	return array[] of {0,1,2,3};
}

observablelabels(): array of string
{
	return array[] of {"displacement", "velocity"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[1]};
}

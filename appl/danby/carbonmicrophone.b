implement Mechanism;

include "danby/mechanism.m";

new(): ref Model
{
	return ref Model(array[] of {1.0,18.0,0.35,1.5,4.0,0.8,0.5});
}

title(): string
{
	return "A carbon microphone circuit";
}

parameterlabels(): array of string
{
	return array[] of {"diaphragm mass", "stiffness", "mechanical damping", "bias voltage", "base resistance", "resistance coupling", "inductance"};
}

parameterminima(): array of real
{
	return array[] of {0.1,0.5,0.0,0.0,0.2,-3.0,0.05};
}

parametermaxima(): array of real
{
	return array[] of {5.0,60.0,4.0,8.0,12.0,3.0,5.0};
}

initialstate(nil: ref Model): array of real
{
	return array[] of {0.12,0.0,0.0};
}

maxtime(nil: ref Model): real
{
	return 20.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	resistance := p[4]*(1.0-p[5]*state[0]);
	if(resistance < 0.05)
		resistance = 0.05;
	electromagneticforce := 0.08*state[2]*state[2];
	derivative[0] = state[1];
	derivative[1] = (-p[1]*state[0]-p[2]*state[1]+electromagneticforce)/p[0];
	derivative[2] = (p[3]-resistance*state[2])/p[6];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(nil: ref Model, state: array of real): array of real
{
	return array[] of {-1.5,-0.8,-1.5,0.8,state[0],-0.8,state[0],0.8,
		-1.5,0.0,state[0],0.0};
}

links(): array of int
{
	return array[] of {0,1,2,3,4,5};
}

observablelabels(): array of string
{
	return array[] of {"diaphragm", "current"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[2]};
}

implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {4.0,2.0,0.8,1.0,0.18,0.0});
}

title(): string
{
	return "Pull-out torques of synchronous motors";
}

parameterlabels(): array of string
{
	return array[] of {"field speed", "maximum torque", "load torque", "inertia", "damping", "initial lag"};
}

parameterminima(): array of real
{
	return array[] of {0.1,0.1,-4.0,0.1,0.0,-3.14};
}

parametermaxima(): array of real
{
	return array[] of {10.0,8.0,4.0,5.0,2.0,3.14};
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
	derivative[1] = (p[2]-p[1]*math->sin(state[0])-p[4]*state[1])/p[3];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(nil: ref Model, state: array of real): array of real
{
	rotor := state[0];
	return array[] of {0.0,0.0,math->cos(rotor),math->sin(rotor),
		0.0,0.0,1.0,0.0,-1.0,0.0,0.0,-1.0};
}

links(): array of int
{
	return array[] of {0,1,2,3,4,5};
}

observablelabels(): array of string
{
	return array[] of {"phase lag", "slip speed"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[1]};
}

implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {2.0,0.15,1.0,1.4,0.2});
}

title(): string
{
	return "A compass in an oscillating magnetic field";
}

parameterlabels(): array of string
{
	return array[] of {"magnetic torque", "damping", "field amplitude", "field rate", "initial angle"};
}

parameterminima(): array of real
{
	return array[] of {0.0,0.0,0.0,0.1,-3.0};
}

parametermaxima(): array of real
{
	return array[] of {8.0,2.0,3.14,6.0,3.0};
}

initialstate(model: ref Model): array of real
{
	return array[] of {model.parameter[4],0.0,0.0};
}

maxtime(nil: ref Model): real
{
	return 40.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	fieldangle := p[2]*math->sin(state[2]);
	derivative[0] = state[1];
	derivative[1] = -p[0]*math->sin(state[0]-fieldangle)-p[1]*state[1];
	derivative[2] = p[3];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	fieldangle := model.parameter[2]*math->sin(state[2]);
	return array[] of {-math->cos(state[0]),-math->sin(state[0]),
		math->cos(state[0]),math->sin(state[0]),
		-1.3*math->cos(fieldangle),-1.3*math->sin(fieldangle),
		1.3*math->cos(fieldangle),1.3*math->sin(fieldangle)};
}

links(): array of int
{
	return array[] of {0,1,2,3};
}

observablelabels(): array of string
{
	return array[] of {"needle angle", "field angle"};
}

observables(model: ref Model, state: array of real): array of real
{
	return array[] of {state[0],model.parameter[2]*math->sin(state[2])};
}

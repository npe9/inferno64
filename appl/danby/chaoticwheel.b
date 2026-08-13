implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {1.0,0.22,1.2,1.1,0.2});
}

title(): string
{
	return "A chaotic driven wheel";
}

parameterlabels(): array of string
{
	return array[] of {"gravity torque", "damping", "drive", "drive rate", "initial angle"};
}

parameterminima(): array of real
{
	return array[] of {0.0,0.0,0.0,0.1,-3.0};
}

parametermaxima(): array of real
{
	return array[] of {5.0,2.0,5.0,5.0,3.0};
}

initialstate(model: ref Model): array of real
{
	return array[] of {model.parameter[4],0.0,0.0};
}

maxtime(nil: ref Model): real
{
	return 60.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	derivative[0] = state[1];
	derivative[1] = -p[0]*math->sin(state[0])-p[1]*state[1]+
		p[2]*math->cos(state[2]);
	derivative[2] = p[3];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(nil: ref Model, state: array of real): array of real
{
	x := math->cos(state[0]);
	y := math->sin(state[0]);
	return array[] of {0.0,0.0,x,y,-x,-y,-1.3,0.0,1.3,0.0};
}

links(): array of int
{
	return array[] of {1,2,3,4};
}

observablelabels(): array of string
{
	return array[] of {"wheel angle", "angular speed"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[1]};
}

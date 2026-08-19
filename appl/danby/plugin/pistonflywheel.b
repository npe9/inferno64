implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {0.65,1.5,2.0,1.0,0.18,0.8});
}

title(): string
{
	return "The motion of a piston and flywheel";
}

parameterlabels(): array of string
{
	return array[] of {"crank radius", "rod length", "wheel inertia", "drive torque", "damping", "load"};
}

parameterminima(): array of real
{
	return array[] of {0.1,0.3,0.1,-5.0,0.0,0.0};
}

parametermaxima(): array of real
{
	return array[] of {2.0,5.0,10.0,8.0,3.0,5.0};
}

initialstate(nil: ref Model): array of real
{
	return array[] of {0.0,0.6};
}

maxtime(nil: ref Model): real
{
	return 30.0;
}

pistonposition(model: ref Model, angle: real): real
{
	p := model.parameter;
	s := p[0]*math->sin(angle);
	inside := p[1]*p[1]-s*s;
	if(inside < 0.0)
		inside = 0.0;
	return p[0]*math->cos(angle)+math->sqrt(inside);
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	loadtorque := p[5]*math->sin(state[0]);
	derivative[0] = state[1];
	derivative[1] = (p[3]-p[4]*state[1]-loadtorque)/p[2];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	p := model.parameter;
	cx := p[0]*math->cos(state[0]);
	cy := p[0]*math->sin(state[0]);
	px := pistonposition(model,state[0]);
	return array[] of {0.0,0.0,cx,cy,px,0.0,px,-0.35,px,0.35,-p[0],0.0,p[0],0.0};
}

links(): array of int
{
	return array[] of {0,1,1,2,3,4,5,6};
}

observablelabels(): array of string
{
	return array[] of {"piston position", "wheel speed"};
}

observables(model: ref Model, state: array of real): array of real
{
	return array[] of {pistonposition(model,state[0]),state[1]};
}

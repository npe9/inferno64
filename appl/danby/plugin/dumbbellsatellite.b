implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {2.0,0.55,1.0,0.9,0.015});
}

title(): string
{
	return "A dumbbell satellite";
}

parameterlabels(): array of string
{
	return array[] of {"orbit radius", "body length", "orbital rate", "initial attitude", "damping"};
}

parameterminima(): array of real
{
	return array[] of {1.0,0.1,0.05,-3.0,0.0};
}

parametermaxima(): array of real
{
	return array[] of {5.0,2.0,3.0,3.0,0.5};
}

initialstate(model: ref Model): array of real
{
	return array[] of {0.0,model.parameter[3],0.0};
}

maxtime(nil: ref Model): real
{
	return 30.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	derivative[0] = p[2];
	derivative[1] = state[2];
	derivative[2] = -1.5*p[2]*p[2]*math->sin(2.0*state[1])-p[4]*state[2];
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
	absangle := state[0]+state[1];
	h := p[1]/2.0;
	dx := h*math->cos(absangle);
	dy := h*math->sin(absangle);
	return array[] of {0.0,0.0,cx-dx,cy-dy,cx+dx,cy+dy,cx,cy};
}

links(): array of int
{
	return array[] of {1,2,0,3};
}

observablelabels(): array of string
{
	return array[] of {"orbital phase", "relative attitude"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[1]};
}

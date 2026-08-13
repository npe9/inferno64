implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {1.0,2.2,1.2,0.25,0.22,0.0});
}

title(): string
{
	return "Zeeman's catastrophe machine";
}

parameterlabels(): array of string
{
	return array[] of {"mass", "spring", "rest length", "damping", "control rate", "initial x"};
}

parameterminima(): array of real
{
	return array[] of {0.1,0.1,0.2,0.0,-2.0,-1.5};
}

parametermaxima(): array of real
{
	return array[] of {5.0,8.0,3.0,2.0,2.0,1.5};
}

initialstate(model: ref Model): array of real
{
	return array[] of {model.parameter[5],0.0,0.0};
}

maxtime(nil: ref Model): real
{
	return 45.0;
}

springforce(x, y, anchorx, anchory, stiffness, rest: real): real
{
	dx := anchorx-x;
	dy := anchory-y;
	d := math->sqrt(dx*dx+dy*dy)+1.0e-6;
	return stiffness*(d-rest)*dx/d;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	cx := 1.8*math->cos(state[2]);
	cy := 1.8*math->sin(state[2])+1.0;
	force := springforce(state[0],0.0,-1.2,1.0,p[1],p[2]);
	force += springforce(state[0],0.0,cx,cy,p[1],p[2]);
	derivative[0] = state[1];
	derivative[1] = (force-p[3]*state[1])/p[0];
	derivative[2] = p[4];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(nil: ref Model, state: array of real): array of real
{
	cx := 1.8*math->cos(state[2]);
	cy := 1.8*math->sin(state[2])+1.0;
	return array[] of {state[0],0.0,-1.2,1.0,cx,cy,-2.0,0.0,2.0,0.0};
}

links(): array of int
{
	return array[] of {0,1,0,2,3,4};
}

observablelabels(): array of string
{
	return array[] of {"state", "control x"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],1.8*math->cos(state[2])};
}

implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {3.0,0.8,12.0,80.0,18.0,0.7});
}

title(): string
{
	return "De-spinning a satellite: the stretch yo-yo";
}

parameterlabels(): array of string
{
	return array[] of {"rest length", "tip mass", "satellite inertia", "initial spin", "stiffness", "damping"};
}

parameterminima(): array of real
{
	return array[] of {0.5,0.05,1.0,-200.0,1.0,0.0};
}

parametermaxima(): array of real
{
	return array[] of {10.0,5.0,50.0,200.0,80.0,4.0};
}

initialstate(model: ref Model): array of real
{
	return array[] of {0.0,model.parameter[3],0.7*model.parameter[0],0.0};
}

maxtime(nil: ref Model): real
{
	return 25.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	r := state[2];
	rdot := state[3];
	inertia := p[2]+2.0*p[1]*r*r;
	derivative[0] = state[1];
	derivative[1] = -4.0*p[1]*r*rdot*state[1]/inertia;
	derivative[2] = rdot;
	derivative[3] = r*state[1]*state[1]-p[4]*(r-p[0])/p[1]-p[5]*rdot;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(nil: ref Model, state: array of real): array of real
{
	c := math->cos(state[0]);
	s := math->sin(state[0]);
	r := state[2];
	return array[] of {0.0,0.0,r*c,r*s,-r*c,-r*s,-0.4*s,0.4*c,0.4*s,-0.4*c};
}

links(): array of int
{
	return array[] of {0,1,0,2,3,4};
}

observablelabels(): array of string
{
	return array[] of {"spin", "stretch"};
}

observables(model: ref Model, state: array of real): array of real
{
	return array[] of {state[1],state[2]-model.parameter[0]};
}

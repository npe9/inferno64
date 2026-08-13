implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {8.0,12.0,1.2,0.5,0.18,0.7});
}

title(): string
{
	return "Landing an airplane on an aircraft carrier";
}

parameterlabels(): array of string
{
	return array[] of {"aircraft mass", "cable stiffness", "cable slack", "damping", "deck heave", "heave rate"};
}

parameterminima(): array of real
{
	return array[] of {0.5,0.1,0.1,0.0,0.0,0.1};
}

parametermaxima(): array of real
{
	return array[] of {30.0,80.0,4.0,10.0,1.0,4.0};
}

initialstate(nil: ref Model): array of real
{
	return array[] of {-2.8,3.2,0.0};
}

maxtime(nil: ref Model): real
{
	return 18.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	deck := p[4]*math->sin(state[2]);
	length := math->sqrt(state[0]*state[0]+deck*deck);
	tension := 0.0;
	if(length > p[2])
		tension = p[1]*(length-p[2])*(length-p[2]);
	direction := 0.0;
	if(length > 1.0e-6)
		direction = state[0]/length;
	derivative[0] = state[1];
	derivative[1] = (-tension*direction-p[3]*state[1])/p[0];
	derivative[2] = p[5];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	deck := model.parameter[4]*math->sin(state[2]);
	return array[] of {-3.5,deck,3.5,deck,state[0],deck+0.2,
		state[0]-0.35,deck+0.2,state[0]+0.35,deck+0.2,0.0,deck};
}

links(): array of int
{
	return array[] of {0,1,2,3,3,4,2,5};
}

observablelabels(): array of string
{
	return array[] of {"aircraft position", "aircraft speed"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[1]};
}

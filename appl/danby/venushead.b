implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {1.0,0.08,0.25,1.7,0.2,1.0});
}

title(): string
{
	return "On Venus, could you see the back of your head?";
}

parameterlabels(): array of string
{
	return array[] of {"planet radius", "density gradient", "ray angle", "eye height", "curvature", "light speed"};
}

parameterminima(): array of real
{
	return array[] of {0.5,0.0,-1.2,0.1,0.0,0.2};
}

parametermaxima(): array of real
{
	return array[] of {3.0,0.5,1.2,3.0,1.5,2.0};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	return array[] of {p[0]+0.05*p[3],0.0,p[4],p[2]};
}

maxtime(nil: ref Model): real
{
	return 12.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	r := state[0];
	rayangle := state[3];
	derivative[0] = p[5]*math->cos(rayangle);
	derivative[1] = p[5]*math->sin(rayangle)/r;
	derivative[2] = 0.0;
	derivative[3] = p[1]*math->sin(rayangle)-p[5]*math->sin(rayangle)/r;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	r := model.parameter[0];
	x := state[0]*math->cos(state[1]);
	y := state[0]*math->sin(state[1]);
	return array[] of {-r,0.0,0.0,-r,r,0.0,0.0,r,x,y,r,0.0,r+0.15,0.0};
}

links(): array of int
{
	return array[] of {0,1,1,2,2,3,3,0,4,5,5,6};
}

observablelabels(): array of string
{
	return array[] of {"ray radius", "wrapped angle"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[1]};
}

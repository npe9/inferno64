implement Mechanism;

include "math.m";
	math: Math;
include "danby/rotatinghoop.m";
	hoop: Rotatinghoop;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	hoop = load Rotatinghoop Rotatinghoop->PATH;
	return ref Model(array[] of {1.0,9.81,1.0,1.2,3.0,0.03,0.45});
}

title(): string
{
	return "A ball in a rotating circular ring: free ring";
}

parameterlabels(): array of string
{
	return array[] of {"radius", "gravity", "ball mass", "ring inertia", "angular momentum", "damping", "initial angle"};
}

parameterminima(): array of real
{
	return array[] of {0.2,0.1,0.1,0.1,0.0,0.0,-3.0};
}

parametermaxima(): array of real
{
	return array[] of {4.0,20.0,5.0,10.0,12.0,1.0,3.0};
}

initialstate(model: ref Model): array of real
{
	return array[] of {model.parameter[6],0.0,0.0};
}

maxtime(nil: ref Model): real
{
	return 35.0;
}

ringrate(model: ref Model, angle: real): real
{
	p := model.parameter;
	s := math->sin(angle);
	return p[4]/(p[3]+p[2]*p[0]*p[0]*s*s);
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	rate := ringrate(model,state[0]);
	derivative[0] = state[1];
	derivative[1] = hoop->angularacceleration(state[0],state[1],p[0],p[1],rate,p[5]);
	derivative[2] = rate;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	r := model.parameter[0];
	width := 0.35+0.65*math->fabs(math->cos(state[2]));
	x := width*r*math->sin(state[0]);
	y := -r*math->cos(state[0]);
	return array[] of {-width*r,0.0,0.0,-r,width*r,0.0,0.0,r,x,y};
}

links(): array of int
{
	return array[] of {0,1,1,2,2,3,3,0};
}

observablelabels(): array of string
{
	return array[] of {"ball angle", "ring speed"};
}

observables(model: ref Model, state: array of real): array of real
{
	return array[] of {state[0],ringrate(model,state[0])};
}

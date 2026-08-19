implement Mechanism;

include "math.m";
	math: Math;
include "danby/doublependulum.m";
	doublependulum: Doublependulum;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	doublependulum = load Doublependulum Doublependulum->PATH;
	return ref Model(array[] of {1.0,1.0,1.0,1.0,1.1,1.6,9.81,0.01});
}

title(): string
{
	return "A double pendulum";
}

parameterlabels(): array of string
{
	return array[] of {"mass 1", "mass 2", "length 1", "length 2", "angle 1", "angle 2", "gravity", "damping"};
}

parameterminima(): array of real
{
	return array[] of {0.1,0.1,0.2,0.2,-3.0,-3.0,0.1,0.0};
}

parametermaxima(): array of real
{
	return array[] of {5.0,5.0,3.0,3.0,3.0,3.0,20.0,0.5};
}

initialstate(model: ref Model): array of real
{
	return array[] of {model.parameter[4],0.0,model.parameter[5],0.0};
}

maxtime(nil: ref Model): real
{
	return 30.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	doublependulum->derivatives(state,derivative,p[0],p[1],p[2],p[3],p[6],p[7]);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	p := model.parameter;
	x1 := p[2]*math->sin(state[0]);
	y1 := -p[2]*math->cos(state[0]);
	x2 := x1+p[3]*math->sin(state[2]);
	y2 := y1-p[3]*math->cos(state[2]);
	return array[] of {0.0,0.0,x1,y1,x2,y2,-0.7,0.0,0.7,0.0};
}

links(): array of int
{
	return array[] of {0,1,1,2,3,4};
}

observablelabels(): array of string
{
	return array[] of {"angle 1", "angle 2"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[2]};
}

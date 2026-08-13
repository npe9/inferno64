implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {2.0,0.75,9.81,0.04,0.8});
}

title(): string
{
	return "A pendulum wrapped around a peg";
}

parameterlabels(): array of string
{
	return array[] of {"string", "initial angle", "gravity", "damping", "peg depth"};
}

parameterminima(): array of real
{
	return array[] of {0.5,-2.5,0.1,0.0,0.1};
}

parametermaxima(): array of real
{
	return array[] of {5.0,2.5,20.0,1.0,4.5};
}

initialstate(model: ref Model): array of real
{
	return array[] of {model.parameter[1],0.0};
}

maxtime(nil: ref Model): real
{
	return 30.0;
}

effectivelength(model: ref Model, angle: real): real
{
	p := model.parameter;
	l := p[0];
	if(angle < 0.0 && p[4] < l-0.05)
		l -= p[4];
	return l;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	l := effectivelength(model,state[0]);
	derivative[0] = state[1];
	derivative[1] = -p[2]*math->sin(state[0])/l-p[3]*state[1];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	p := model.parameter;
	pegdepth := p[4];
	if(pegdepth > p[0]-0.05)
		pegdepth = p[0]-0.05;
	if(state[0] < 0.0){
		l := p[0]-pegdepth;
		x := l*math->sin(state[0]);
		y := -pegdepth-l*math->cos(state[0]);
		return array[] of {0.0,0.0,0.0,-pegdepth,x,y,-0.7,0.0,0.7,0.0};
	}
	x := p[0]*math->sin(state[0]);
	y := -p[0]*math->cos(state[0]);
	return array[] of {0.0,0.0,0.0,-pegdepth,x,y,-0.7,0.0,0.7,0.0};
}

links(): array of int
{
	return array[] of {0,1,1,2,3,4};
}

observablelabels(): array of string
{
	return array[] of {"angle", "effective length"};
}

observables(model: ref Model, state: array of real): array of real
{
	return array[] of {state[0],effectivelength(model,state[0])};
}

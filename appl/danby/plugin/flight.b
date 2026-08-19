implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {1800.0,0.38,0.025,850.0,1.8,9.81});
}

title(): string
{
	return "The dynamics of flight";
}

parameterlabels(): array of string
{
	return array[] of {"thrust", "lift", "drag", "mass", "pitch control", "gravity"};
}

parameterminima(): array of real
{
	return array[] of {0.0,0.0,0.0,300.0,0.0,0.0};
}

parametermaxima(): array of real
{
	return array[] of {5000.0,1.0,0.1,1800.0,5.0,20.0};
}

initialstate(nil: ref Model): array of real
{
	return array[] of {0.0,100.0,55.0,0.05,0.12,0.0};
}

maxtime(nil: ref Model): real
{
	return 30.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	speed := state[2];
	if(speed < 1.0)
		speed = 1.0;
	pathangle := state[3];
	pitch := state[4];
	alpha := pitch-pathangle;
	lift := p[1]*alpha*speed*speed;
	drag := p[2]*speed*speed;
	derivative[0] = speed*math->cos(pathangle);
	derivative[1] = speed*math->sin(pathangle);
	derivative[2] = (p[0]*math->cos(alpha)-drag)/p[3]-
		p[5]*math->sin(pathangle);
	derivative[3] = (lift+p[0]*math->sin(alpha))/(p[3]*speed)-
		p[5]*math->cos(pathangle)/speed;
	derivative[4] = state[5];
	derivative[5] = p[4]*alpha-1.2*state[5];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(nil: ref Model, state: array of real): array of real
{
	x := 0.0;
	y := 1.5;
	c := math->cos(state[4]);
	s := math->sin(state[4]);
	return array[] of {
		x-1.0*c,y-1.0*s,
		x+1.2*c,y+1.2*s,
		x-0.1*s,y+0.1*c,
		x+0.65*s,y-0.65*c,
		-1.5,0.0,
		1.5,0.0
	};
}

links(): array of int
{
	return array[] of {0,1,2,3,4,5};
}

observablelabels(): array of string
{
	return array[] of {"altitude", "speed"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[1],state[2]};
}

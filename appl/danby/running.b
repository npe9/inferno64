implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {320.0,0.9,70.0,0.7,2.2,0.18});
}

title(): string
{
	return "Running";
}

parameterlabels(): array of string
{
	return array[] of {"drive", "drag", "mass", "fatigue", "stride", "recovery"};
}

parameterminima(): array of real
{
	return array[] of {20.0,0.05,35.0,0.0,0.8,0.0};
}

parametermaxima(): array of real
{
	return array[] of {700.0,3.0,120.0,2.0,4.0,0.8};
}

initialstate(nil: ref Model): array of real
{
	return array[] of {1.0,0.0,0.0,0.0};
}

maxtime(nil: ref Model): real
{
	return 20.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	speed := state[0];
	fatigue := state[1];
	effective := p[0]*(1.0-p[3]*fatigue);
	if(effective < 0.0)
		effective = 0.0;
	derivative[0] = (effective-p[1]*speed*speed)/p[2];
	derivative[1] = 0.002*speed*speed-p[5]*fatigue;
	derivative[2] = 2.0*Math->Pi*speed/p[4];
	derivative[3] = speed;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(nil: ref Model, state: array of real): array of real
{
	phase := state[2];
	hipx := 0.0;
	hipy := 1.05+0.05*math->sin(2.0*phase);
	shoulderx := 0.08;
	shouldery := hipy+0.55;
	front := 0.55*math->sin(phase);
	back := 0.55*math->sin(phase+Math->Pi);
	return array[] of {
		hipx,hipy,
		shoulderx,shouldery,
		shoulderx,shouldery+0.25,
		front*0.55,hipy-0.45,
		front,0.0,
		back*0.55,hipy-0.45,
		back,0.0,
		0.45*math->sin(phase+Math->Pi),shouldery-0.25,
		0.45*math->sin(phase),shouldery-0.25
	};
}

links(): array of int
{
	return array[] of {0,1,1,2,0,3,3,4,0,5,5,6,1,7,1,8};
}

observablelabels(): array of string
{
	return array[] of {"speed", "distance"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[3]};
}

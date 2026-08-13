implement Mechanism;

include "math.m";
	math: Math;
include "danby/cartpendulum.m";
	cartpendulum: Cartpendulum;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	cartpendulum = load Cartpendulum Cartpendulum->PATH;
	return ref Model(array[] of {2.0,1.0,1.4,0.6,9.81,1.8,0.15});
}

title(): string
{
	return "A sliding pendulum: elastic support";
}

parameterlabels(): array of string
{
	return array[] of {"support mass", "bob mass", "length", "initial angle", "gravity", "spring", "cart damping"};
}

parameterminima(): array of real
{
	return array[] of {0.1,0.1,0.2,-2.5,0.1,0.0,0.0};
}

parametermaxima(): array of real
{
	return array[] of {10.0,10.0,5.0,2.5,20.0,10.0,2.0};
}

initialstate(model: ref Model): array of real
{
	return array[] of {0.0,0.0,model.parameter[3],0.0};
}

maxtime(nil: ref Model): real
{
	return 30.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	cartpendulum->derivatives(state,derivative,p[0],p[1],p[2],p[4],
		p[5],p[6],0.03);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	l := model.parameter[2];
	x := state[0]+l*math->sin(state[2]);
	y := -l*math->cos(state[2]);
	return array[] of {state[0],0.0,x,y,state[0]-0.35,0.0,
		state[0]+0.35,0.0,-2.0,0.0,2.0,0.0,-2.0,0.0,state[0]-0.35,0.0};
}

links(): array of int
{
	return array[] of {0,1,2,3,4,5,6,7};
}

observablelabels(): array of string
{
	return array[] of {"support position", "angle"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[2]};
}

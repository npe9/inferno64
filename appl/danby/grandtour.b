implement Orbital;

include "math.m";
	math: Math;
include "danby/gravity.m";
	gravity: Gravity;
include "danby/orbital.m";

new(): ref Model
{
	math = load Math Math->PATH;
	gravity = load Gravity Gravity->PATH;
	return ref Model(array[] of {0.001,0.0003,5.2,9.5,0.52,0.003},
		array[] of {1.0,0.001,0.0003,0.0});
}

title(): string
{
	return "A grand tour of the Solar System";
}

parameterlabels(): array of string
{
	return array[] of {"Jupiter mass", "Saturn mass", "Jupiter radius", "Saturn radius", "launch speed", "softening"};
}

parameterminima(): array of real
{
	return array[] of {0.0001,0.00005,2.0,5.0,0.1,0.0002};
}

parametermaxima(): array of real
{
	return array[] of {0.01,0.003,8.0,15.0,1.2,0.05};
}

bodylabels(): array of string
{
	return array[] of {"Sun", "Jupiter", "Saturn", "craft"};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	model.mass[1] = p[0];
	model.mass[2] = p[1];
	return array[] of {
		0.0,0.0,0.0,0.0,
		p[2],0.0,0.0,math->sqrt(1.0/p[2]),
		0.0,p[3],-math->sqrt(1.0/p[3]),0.0,
		1.2,0.0,0.0,p[4]
	};
}

maxtime(nil: ref Model): real
{
	return 120.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	gravity->derivatives(state,model.mass,1.0,model.parameter[5],derivative);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

observablelabels(): array of string
{
	return array[] of {"Jupiter distance", "Saturn distance"};
}

observables(nil: ref Model, state: array of real): array of real
{
	jdx := state[12]-state[4];
	jdy := state[13]-state[5];
	sdx := state[12]-state[8];
	sdy := state[13]-state[9];
	return array[] of {math->sqrt(jdx*jdx+jdy*jdy),math->sqrt(sdx*sdx+sdy*sdy)};
}

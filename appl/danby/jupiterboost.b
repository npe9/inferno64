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
	return ref Model(array[] of {0.001,5.2,0.45,0.16,0.018,1.0},
		array[] of {1.0,0.001,0.0});
}

title(): string
{
	return "Using Jupiter to boost the orbit of a spacecraft";
}

parameterlabels(): array of string
{
	return array[] of {"Jupiter mass", "Jupiter radius", "craft speed", "aim offset", "softening", "gravity"};
}

parameterminima(): array of real
{
	return array[] of {0.0001,2.0,0.05,-1.0,0.001,0.2};
}

parametermaxima(): array of real
{
	return array[] of {0.01,8.0,1.2,1.0,0.1,2.0};
}

bodylabels(): array of string
{
	return array[] of {"Sun", "Jupiter", "craft"};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	model.mass[1] = p[0];
	jupiterspeed := math->sqrt(p[5]/p[1]);
	return array[] of {
		0.0,0.0,0.0,0.0,
		p[1],0.0,0.0,jupiterspeed,
		p[1]-2.0,p[3],p[2],jupiterspeed
	};
}

maxtime(nil: ref Model): real
{
	return 45.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	gravity->derivatives(state,model.mass,model.parameter[5],model.parameter[4],derivative);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

observablelabels(): array of string
{
	return array[] of {"heliocentric speed", "Jupiter distance"};
}

observables(nil: ref Model, state: array of real): array of real
{
	jdx := state[8]-state[4];
	jdy := state[9]-state[5];
	return array[] of {math->sqrt(state[10]*state[10]+state[11]*state[11]),
		math->sqrt(jdx*jdx+jdy*jdy)};
}

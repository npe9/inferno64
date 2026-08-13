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
	return ref Model(array[] of {2.0,2.0,4.5,0.25,0.12,1.0},
		array[] of {2.0,2.0,0.08,0.08,0.08,0.08});
}

title(): string
{
	return "Gravitational interaction between two galaxies";
}

parameterlabels(): array of string
{
	return array[] of {"galaxy A mass", "galaxy B mass", "separation", "approach speed", "softening", "gravity"};
}

parameterminima(): array of real
{
	return array[] of {0.2,0.2,1.0,0.0,0.02,0.2};
}

parametermaxima(): array of real
{
	return array[] of {6.0,6.0,10.0,1.0,0.6,2.0};
}

bodylabels(): array of string
{
	return array[] of {"core A", "core B", "A1", "A2", "B1", "B2"};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	model.mass[0] = p[0];
	model.mass[1] = p[1];
	d := p[2]/2.0;
	return array[] of {
		-d,0.0,p[3],0.12,
		d,0.0,-p[3],-0.12,
		-d-0.8,0.0,p[3],-0.6,
		-d+0.8,0.0,p[3],0.6,
		d-0.8,0.0,-p[3],-0.6,
		d+0.8,0.0,-p[3],0.6
	};
}

maxtime(nil: ref Model): real
{
	return 35.0;
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
	return array[] of {"core separation", "system energy"};
}

observables(model: ref Model, state: array of real): array of real
{
	dx := state[4]-state[0];
	dy := state[5]-state[1];
	return array[] of {math->sqrt(dx*dx+dy*dy),
		gravity->energy(state,model.mass,model.parameter[5],model.parameter[4])};
}

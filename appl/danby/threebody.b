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
	return ref Model(array[] of {1.0,1.0,0.5,1.0,0.015,0.03},
		array[] of {1.0,1.0,0.5});
}

title(): string
{
	return "The motion of three bodies";
}

parameterlabels(): array of string
{
	return array[] of {"mass A", "mass B", "mass C", "gravity", "softening", "perturbation"};
}

parameterminima(): array of real
{
	return array[] of {0.1,0.1,0.1,0.1,0.001,-0.2};
}

parametermaxima(): array of real
{
	return array[] of {3.0,3.0,3.0,3.0,0.1,0.2};
}

bodylabels(): array of string
{
	return array[] of {"A", "B", "C"};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	model.mass[0] = p[0];
	model.mass[1] = p[1];
	model.mass[2] = p[2];
	omega := math->sqrt(p[3]*(p[0]+p[1]+p[2]));
	return array[] of {
		-0.5,-0.288675,omega*0.288675,-omega*0.5,
		0.5,-0.288675,omega*0.288675,omega*0.5+p[5],
		0.0,0.57735,-omega*0.57735,0.0
	};
}

maxtime(nil: ref Model): real
{
	return 30.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	gravity->derivatives(state,model.mass,model.parameter[3],
		model.parameter[4],derivative);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

observablelabels(): array of string
{
	return array[] of {"energy", "angular momentum"};
}

observables(model: ref Model, state: array of real): array of real
{
	return array[] of {
		gravity->energy(state,model.mass,model.parameter[3],model.parameter[4]),
		gravity->angularmomentum(state,model.mass)
	};
}

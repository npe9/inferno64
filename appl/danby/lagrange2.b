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
	return ref Model(array[] of {0.08,0.06,0.0123,0.002,1.0,-1.0},
		array[] of {1.0,0.0123,0.000001});
}

title(): string
{
	return "A space station around L4 or L5: 2";
}

parameterlabels(): array of string
{
	return array[] of {"position perturb", "speed perturb", "Moon mass", "softening", "gravity", "L4 or L5"};
}

parameterminima(): array of real
{
	return array[] of {-0.2,-0.3,0.001,0.0002,0.2,-1.0};
}

parametermaxima(): array of real
{
	return array[] of {0.2,0.3,0.05,0.02,2.0,1.0};
}

bodylabels(): array of string
{
	return array[] of {"Earth", "Moon", "station"};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	model.mass[1] = p[2];
	mu := p[2]/(1.0+p[2]);
	omega := math->sqrt(p[4]*(1.0+p[2]));
	sign := 1.0;
	if(p[5] < 0.0)
		sign = -1.0;
	sx := 0.5-mu+p[0];
	sy := sign*(0.8660254+p[0]*0.4);
	return array[] of {
		-mu,0.0,0.0,-omega*mu,
		1.0-mu,0.0,0.0,omega*(1.0-mu),
		sx,sy,-omega*sy+p[1],omega*sx
	};
}

maxtime(nil: ref Model): real
{
	return 40.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	gravity->derivatives(state,model.mass,model.parameter[4],
		model.parameter[3],derivative);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

observablelabels(): array of string
{
	return array[] of {"Earth distance", "Moon distance"};
}

observables(nil: ref Model, state: array of real): array of real
{
	edx := state[8]-state[0];
	edy := state[9]-state[1];
	mdx := state[8]-state[4];
	mdy := state[9]-state[5];
	return array[] of {math->sqrt(edx*edx+edy*edy),math->sqrt(mdx*mdx+mdy*mdy)};
}

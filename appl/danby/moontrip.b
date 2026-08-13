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
	return ref Model(array[] of {0.0123,0.06,0.0,3.7,0.18,0.002},
		array[] of {1.0,0.0123,0.000001});
}

title(): string
{
	return "A trip to the Moon";
}

parameterlabels(): array of string
{
	return array[] of {"Moon mass", "launch radius", "launch offset", "launch speed", "launch angle", "softening"};
}

parameterminima(): array of real
{
	return array[] of {0.001,0.02,-0.08,0.5,-1.0,0.0002};
}

parametermaxima(): array of real
{
	return array[] of {0.05,0.15,0.08,6.0,1.0,0.02};
}

bodylabels(): array of string
{
	return array[] of {"Earth", "Moon", "craft"};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	model.mass[1] = p[0];
	mu := p[0]/(1.0+p[0]);
	omega := math->sqrt(1.0+p[0]);
	earthx := -mu;
	moonx := 1.0-mu;
	craftx := earthx+p[1];
	crafty := p[2];
	return array[] of {
		earthx,0.0,0.0,-omega*mu,
		moonx,0.0,0.0,omega*(1.0-mu),
		craftx,crafty,p[3]*math->cos(p[4]),
		-omega*mu+p[3]*math->sin(p[4])
	};
}

maxtime(nil: ref Model): real
{
	return 12.0;
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

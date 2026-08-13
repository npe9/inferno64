implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {3.0,0.8,12.0,80.0,0.12,1.2});
}

title(): string
{
	return "De-spinning a satellite: a space yo-yo";
}

parameterlabels(): array of string
{
	return array[] of {"tether length", "tip mass", "satellite inertia", "initial spin", "damping", "deployment"};
}

parameterminima(): array of real
{
	return array[] of {0.5,0.05,1.0,-200.0,0.0,0.1};
}

parametermaxima(): array of real
{
	return array[] of {10.0,5.0,50.0,200.0,1.0,5.0};
}

initialstate(model: ref Model): array of real
{
	return array[] of {0.0,model.parameter[3],0.05,model.parameter[5]};
}

maxtime(nil: ref Model): real
{
	return 20.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	radius := state[2];
	radialvelocity := state[3];
	totalinertia := p[2]+2.0*p[1]*radius*radius;
	angularmomentum := (p[2]+2.0*p[1]*0.05*0.05)*p[3];
	derivative[0] = angularmomentum/totalinertia;
	derivative[1] = -p[4]*state[1]-4.0*p[1]*radius*radialvelocity*
		state[1]/totalinertia;
	derivative[2] = radialvelocity;
	derivative[3] = radius*state[1]*state[1]-0.4*radialvelocity;
	if(radius >= p[0] && radialvelocity > 0.0)
		derivative[3] -= 12.0*(radius-p[0]);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(nil: ref Model, state: array of real): array of real
{
	c := math->cos(state[0]);
	s := math->sin(state[0]);
	r := state[2];
	return array[] of {0.0,0.0,r*c,r*s,-r*c,-r*s,-0.4*s,0.4*c,0.4*s,-0.4*c};
}

links(): array of int
{
	return array[] of {0,1,0,2,3,4};
}

observablelabels(): array of string
{
	return array[] of {"spin", "deployment"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[1],state[2]};
}

implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {0.35,0.2,1.3,0.16,0.2,0.8});
}

title(): string
{
	return "A magnetic pendulum in three dimensions";
}

parameterlabels(): array of string
{
	return array[] of {"initial x", "initial y", "spring", "damping", "magnet strength", "spacing"};
}

parameterminima(): array of real
{
	return array[] of {-1.5,-1.5,0.1,0.0,0.0,0.2};
}

parametermaxima(): array of real
{
	return array[] of {1.5,1.5,5.0,1.5,1.5,1.5};
}

initialstate(model: ref Model): array of real
{
	return array[] of {model.parameter[0],model.parameter[1],0.75,0.0,0.0,0.0};
}

maxtime(nil: ref Model): real
{
	return 35.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	acceleration := array[] of {-p[2]*state[0]-p[3]*state[3],
		-p[2]*state[1]-p[3]*state[4],-p[2]*(state[2]-0.75)-p[3]*state[5]};
	for(i := 0; i < 4; i++){
		a := 2.0*Math->Pi*real(i)/4.0;
		mx := p[5]*math->cos(a);
		my := p[5]*math->sin(a);
		dx := mx-state[0];
		dy := my-state[1];
		dz := -state[2];
		r2 := dx*dx+dy*dy+dz*dz+0.05;
		force := p[4]/(r2*math->sqrt(r2));
		acceleration[0] += force*dx;
		acceleration[1] += force*dy;
		acceleration[2] += force*dz;
	}
	derivative[0] = state[3];
	derivative[1] = state[4];
	derivative[2] = state[5];
	derivative[3] = acceleration[0];
	derivative[4] = acceleration[1];
	derivative[5] = acceleration[2];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	d := model.parameter[5];
	projectedy := state[1]-0.45*state[2];
	return array[] of {state[0],projectedy,d,0.0,0.0,d,-d,0.0,
		0.0,-d,0.0,-0.45*1.5};
}

links(): array of int
{
	return array[] of {0,5};
}

observablelabels(): array of string
{
	return array[] of {"horizontal radius", "height"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {math->sqrt(state[0]*state[0]+state[1]*state[1]),state[2]};
}

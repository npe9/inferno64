implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {0.35,1.2,0.18,0.16,0.75});
}

title(): string
{
	return "A magnetic pendulum in two dimensions";
}

parameterlabels(): array of string
{
	return array[] of {"initial x", "spring", "damping", "magnet strength", "spacing"};
}

parameterminima(): array of real
{
	return array[] of {-1.5,0.1,0.0,0.0,0.2};
}

parametermaxima(): array of real
{
	return array[] of {1.5,5.0,1.5,1.0,1.5};
}

initialstate(model: ref Model): array of real
{
	return array[] of {model.parameter[0],0.24,0.0,0.0};
}

maxtime(nil: ref Model): real
{
	return 35.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	ax := -p[1]*state[0]-p[2]*state[2];
	ay := -p[1]*state[1]-p[2]*state[3];
	for(i := 0; i < 3; i++){
		a := 2.0*Math->Pi*real(i)/3.0;
		mx := p[4]*math->cos(a);
		my := p[4]*math->sin(a);
		dx := mx-state[0];
		dy := my-state[1];
		r2 := dx*dx+dy*dy+0.06;
		force := p[3]/(r2*math->sqrt(r2));
		ax += force*dx;
		ay += force*dy;
	}
	derivative[0] = state[2];
	derivative[1] = state[3];
	derivative[2] = ax;
	derivative[3] = ay;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	d := model.parameter[4];
	return array[] of {state[0],state[1],d,0.0,
		-0.5*d,0.8660254*d,-0.5*d,-0.8660254*d,0.0,0.0};
}

links(): array of int
{
	return array[] of {0,4};
}

observablelabels(): array of string
{
	return array[] of {"x", "y"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[1]};
}

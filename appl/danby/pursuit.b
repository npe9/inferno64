implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {0.5,1.0,0.0});
}

title(): string
{
	return "Curves of pursuit";
}

parameterlabels(): array of string
{
	return array[] of {"speed", "initial size", "turn bias"};
}

parameterminima(): array of real
{
	return array[] of {0.05,0.2,-1.0};
}

parametermaxima(): array of real
{
	return array[] of {3.0,3.0,1.0};
}

initialstate(model: ref Model): array of real
{
	d := model.parameter[1];
	return array[] of {-d,-d,d,-d,d,d,-d,d};
}

maxtime(nil: ref Model): real
{
	return 8.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	for(i := 0; i < 4; i++){
		j := (i+1)%4;
		dx := state[2*j]-state[2*i];
		dy := state[2*j+1]-state[2*i+1];
		d := math->sqrt(dx*dx+dy*dy)+1.0e-6;
		derivative[2*i] = model.parameter[0]*(dx-model.parameter[2]*dy)/d;
		derivative[2*i+1] = model.parameter[0]*(dy+model.parameter[2]*dx)/d;
	}
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(nil: ref Model, state: array of real): array of real
{
	points := array[len state] of real;
	points[0:] = state;
	return points;
}

links(): array of int
{
	return array[] of {0,1,1,2,2,3,3,0};
}

observablelabels(): array of string
{
	return array[] of {"separation 01", "separation 12"};
}

observables(nil: ref Model, state: array of real): array of real
{
	dx1 := state[2]-state[0];
	dy1 := state[3]-state[1];
	dx2 := state[4]-state[2];
	dy2 := state[5]-state[3];
	return array[] of {math->sqrt(dx1*dx1+dy1*dy1),math->sqrt(dx2*dx2+dy2*dy2)};
}

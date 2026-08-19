implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

Nfragment: con 4;

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {32.0,1.8,14.0,0.015,9.81,1.0});
}

title(): string
{
	return "Fireworks";
}

parameterlabels(): array of string
{
	return array[] of {"launch speed", "fuse", "burst speed", "drag", "gravity", "symmetry"};
}

parameterminima(): array of real
{
	return array[] of {5.0,0.2,1.0,0.0,0.0,0.5};
}

parametermaxima(): array of real
{
	return array[] of {60.0,4.0,30.0,0.08,20.0,1.5};
}

initialstate(model: ref Model): array of real
{
	state := array[Nfragment*4] of real;
	for(i := 0; i < Nfragment; i++){
		state[4*i] = 0.0;
		state[4*i+1] = 0.0;
		state[4*i+2] = 0.0;
		state[4*i+3] = model.parameter[0];
	}
	return state;
}

maxtime(nil: ref Model): real
{
	return 8.0;
}

Model.rhs(model: self ref Model, t: real, state, derivative: array of real)
{
	p := model.parameter;
	delta := t-p[1];
	burstacceleration := p[2]*5.6418958*math->exp(-100.0*delta*delta);
	for(i := 0; i < Nfragment; i++){
		angle := 2.0*Math->Pi*real i/real Nfragment*p[5];
		vx := state[4*i+2];
		vy := state[4*i+3];
		speed := math->sqrt(vx*vx+vy*vy);
		derivative[4*i] = vx;
		derivative[4*i+1] = vy;
		derivative[4*i+2] = burstacceleration*math->cos(angle)-p[3]*speed*vx;
		derivative[4*i+3] = burstacceleration*math->sin(angle)-p[4]-p[3]*speed*vy;
	}
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(nil: ref Model, state: array of real): array of real
{
	points := array[(Nfragment+2)*2] of real;
	for(i := 0; i < Nfragment; i++){
		points[2*i] = state[4*i];
		points[2*i+1] = state[4*i+1];
	}
	points[2*Nfragment] = -2.0;
	points[2*Nfragment+1] = 0.0;
	points[2*Nfragment+2] = 2.0;
	points[2*Nfragment+3] = 0.0;
	return points;
}

links(): array of int
{
	return array[] of {Nfragment,Nfragment+1};
}

observablelabels(): array of string
{
	return array[] of {"mean altitude", "spread"};
}

observables(nil: ref Model, state: array of real): array of real
{
	mean := 0.0;
	xmin := state[0];
	xmax := state[0];
	for(i := 0; i < Nfragment; i++){
		x := state[4*i];
		mean += state[4*i+1];
		if(x < xmin)
			xmin = x;
		if(x > xmax)
			xmax = x;
	}
	return array[] of {mean/real Nfragment,xmax-xmin};
}

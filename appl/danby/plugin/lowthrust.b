implement Orbital;

include "math.m";
	math: Math;
include "danby/orbital.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {1.0,0.006,1.0,0.0,1.0,0.002},
		array[] of {1.0,0.0});
}

title(): string
{
	return "The motion of a rocket: low-thrust orbits";
}

parameterlabels(): array of string
{
	return array[] of {"initial radius", "thrust", "gravity", "steering offset", "initial speed", "softening"};
}

parameterminima(): array of real
{
	return array[] of {0.5,-0.02,0.2,-1.57,0.2,0.0002};
}

parametermaxima(): array of real
{
	return array[] of {2.0,0.02,2.0,1.57,2.0,0.02};
}

bodylabels(): array of string
{
	return array[] of {"planet", "craft"};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	return array[] of {0.0,0.0,0.0,0.0,p[0],0.0,0.0,p[4]};
}

maxtime(nil: ref Model): real
{
	return 80.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	x := state[4];
	y := state[5];
	vx := state[6];
	vy := state[7];
	r := math->sqrt(x*x+y*y+p[5]*p[5]);
	speed := math->sqrt(vx*vx+vy*vy);
	tx := 0.0;
	ty := 0.0;
	if(speed > 0.0){
		c := math->cos(p[3]);
		s := math->sin(p[3]);
		tx = p[1]*(c*vx-s*vy)/speed;
		ty = p[1]*(s*vx+c*vy)/speed;
	}
	derivative[0] = 0.0;
	derivative[1] = 0.0;
	derivative[2] = 0.0;
	derivative[3] = 0.0;
	derivative[4] = vx;
	derivative[5] = vy;
	derivative[6] = -p[2]*x/(r*r*r)+tx;
	derivative[7] = -p[2]*y/(r*r*r)+ty;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

observablelabels(): array of string
{
	return array[] of {"radius", "speed"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {math->sqrt(state[4]*state[4]+state[5]*state[5]),
		math->sqrt(state[6]*state[6]+state[7]*state[7])};
}

implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {9.0,5.0,1800.0,35.0,75.0,9.81});
}

title(): string
{
	return "The pole vault";
}

parameterlabels(): array of string
{
	return array[] of {"run speed", "pole length", "stiffness", "damping", "mass", "gravity"};
}

parameterminima(): array of real
{
	return array[] of {1.0,2.0,200.0,0.0,40.0,0.0};
}

parametermaxima(): array of real
{
	return array[] of {14.0,6.5,4000.0,150.0,120.0,20.0};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	return array[] of {-0.9,p[0]/p[1],0.0,p[0]*0.18};
}

maxtime(nil: ref Model): real
{
	return 4.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	theta := state[0];
	omega := state[1];
	flex := state[2];
	flexvelocity := state[3];
	derivative[0] = omega;
	derivative[1] = -p[5]/p[1]*math->sin(theta)+
		p[2]*flex/(p[4]*p[1]*p[1])-0.08*omega;
	derivative[2] = flexvelocity;
	derivative[3] = -p[2]*flex/p[4]-p[3]*flexvelocity/p[4]-
		p[1]*omega*omega*0.08;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	length := model.parameter[1];
	theta := state[0];
	flex := state[2];
	topx := length*math->sin(theta);
	topy := length*math->cos(theta);
	midx := 0.5*topx+flex*math->cos(theta);
	midy := 0.5*topy-flex*math->sin(theta);
	return array[] of {
		0.0,0.0,
		midx,midy,
		topx,topy,
		topx+0.3*math->sin(theta),topy+0.3*math->cos(theta),
		topx-0.55*math->cos(theta),topy+0.55*math->sin(theta),
		-1.0,0.0,
		1.0,0.0
	};
}

links(): array of int
{
	return array[] of {0,1,1,2,2,3,2,4,5,0,0,6};
}

observablelabels(): array of string
{
	return array[] of {"height", "pole energy"};
}

observables(model: ref Model, state: array of real): array of real
{
	height := model.parameter[1]*math->cos(state[0]);
	energy := 0.5*model.parameter[2]*state[2]*state[2];
	return array[] of {height,energy};
}

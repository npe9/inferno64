implement Flight3d;

include "math.m";
	math: Math;
include "danby/ballistics.m";
	ballistics: Ballistics;
include "danby/flight3d.m";

new(): ref Model
{
	math = load Math Math->PATH;
	ballistics = load Ballistics Ballistics->PATH;
	return ref Model(array[] of {24.0,0.55,0.0,0.008,1.5,9.81});
}

title(): string
{
	return "A badly kicked football";
}

parameterlabels(): array of string
{
	return array[] of {"speed", "elevation", "aim", "drag", "wobble", "gravity"};
}

parameterminima(): array of real
{
	return array[] of {0.0,0.0,-0.5,0.0,-4.0,0.0};
}

parameterranges(): array of real
{
	return array[] of {40.0,1.3,0.5,0.03,4.0,20.0};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	horizontal := p[0]*math->cos(p[1]);
	return array[] of {0.0,0.0,0.0,
		horizontal*math->cos(p[2]),horizontal*math->sin(p[2]),
		p[0]*math->sin(p[1])};
}

maxtime(nil: ref Model): real
{
	return 8.0;
}

Model.rhs(model: self ref Model, t: real, state, derivative: array of real)
{
	p := model.parameter;
	derivative[0] = state[3];
	derivative[1] = state[4];
	derivative[2] = state[5];
	(derivative[3],derivative[4],derivative[5]) = ballistics->acceleration3(
		state[3],state[4],state[5],p[3],0.0,0.0,0.0,0.0,p[5]);
	derivative[4] += p[4]*math->sin(14.0*t);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

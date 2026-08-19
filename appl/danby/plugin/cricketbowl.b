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
	return ref Model(array[] of {34.0,0.03,0.0,0.004,0.012,9.81});
}

title(): string
{
	return "Bowling a cricket ball";
}

parameterlabels(): array of string
{
	return array[] of {"speed", "elevation", "aim", "drag", "spin", "gravity"};
}

parameterminima(): array of real
{
	return array[] of {0.0,-0.35,-0.35,0.0,-0.06,0.0};
}

parameterranges(): array of real
{
	return array[] of {50.0,0.35,0.35,0.02,0.06,20.0};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	horizontal := p[0]*math->cos(p[1]);
	return array[] of {0.0,0.0,2.0,
		horizontal*math->cos(p[2]),horizontal*math->sin(p[2]),
		p[0]*math->sin(p[1])};
}

maxtime(nil: ref Model): real
{
	return 1.2;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	derivative[0] = state[3];
	derivative[1] = state[4];
	derivative[2] = state[5];
	(derivative[3],derivative[4],derivative[5]) = ballistics->acceleration3(
		state[3],state[4],state[5],p[3],p[4],0.0,0.0,1.0,p[5]);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

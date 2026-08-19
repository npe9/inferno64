implement Trajectory;

include "math.m";
	math: Math;
include "danby/ballistics.m";
	ballistics: Ballistics;
include "danby/trajectory.m";

new(): ref Model
{
	math = load Math Math->PATH;
	ballistics = load Ballistics Ballistics->PATH;
	return ref Model(array[] of {12.0,0.08,0.018,0.0015,90.0,9.81});
}

title(): string
{
	return "Table tennis";
}

parameterlabels(): array of string
{
	return array[] of {"speed", "angle", "drag", "lift", "topspin", "gravity"};
}

parameterranges(): array of real
{
	return array[] of {30.0,0.8,0.06,0.006,250.0,20.0};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	return array[] of {0.0,1.0,p[0]*math->cos(p[1]),p[0]*math->sin(p[1])};
}

maxtime(nil: ref Model): real
{
	return 2.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	derivative[0] = state[2];
	derivative[1] = state[3];
	(derivative[2],derivative[3]) = ballistics->acceleration(
		state[2],state[3],p[2],-p[3],p[4],p[5],0.0);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

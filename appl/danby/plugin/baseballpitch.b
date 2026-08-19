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
	return ref Model(array[] of {40.0,-0.03,0.003,0.0005,180.0,9.81});
}

title(): string
{
	return "A model for a baseball pitch";
}

parameterlabels(): array of string
{
	return array[] of {"speed", "angle", "drag", "lift", "spin", "gravity"};
}

parameterranges(): array of real
{
	return array[] of {55.0,0.3,0.02,0.003,350.0,20.0};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	return array[] of {0.0,1.8,p[0]*math->cos(p[1]),p[0]*math->sin(p[1])};
}

maxtime(nil: ref Model): real
{
	return 0.55;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	derivative[0] = state[2];
	derivative[1] = state[3];
	(derivative[2],derivative[3]) = ballistics->acceleration(
		state[2],state[3],p[2],p[3],p[4],p[5],0.0);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

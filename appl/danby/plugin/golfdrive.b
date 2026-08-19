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
	return ref Model(array[] of {70.0,0.22,0.004,0.00055,250.0,9.81});
}

title(): string
{
	return "Driving a golf ball";
}

parameterlabels(): array of string
{
	return array[] of {"ball speed", "launch angle", "drag", "lift", "backspin", "gravity"};
}

parameterranges(): array of real
{
	return array[] of {100.0,0.8,0.02,0.003,500.0,20.0};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	return array[] of {0.0,0.0,p[0]*math->cos(p[1]),p[0]*math->sin(p[1])};
}

maxtime(nil: ref Model): real
{
	return 15.0;
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

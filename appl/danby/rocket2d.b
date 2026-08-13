implement Trajectory;

include "math.m";
	math: Math;
include "danby/atmosphere.m";
	atmosphere: Atmosphere;
include "danby/propulsion.m";
	propulsion: Propulsion;
include "danby/trajectory.m";

new(): ref Model
{
	math = load Math Math->PATH;
	atmosphere = load Atmosphere Atmosphere->PATH;
	propulsion = load Propulsion Propulsion->PATH;
	return ref Model(array[] of {3800.0,1.35,80.0,140.0,6.0,9.81});
}

title(): string
{
	return "The motion of a rocket: two-dimensional motion";
}

parameterlabels(): array of string
{
	return array[] of {"thrust", "pitch", "dry mass", "propellant", "flow", "gravity"};
}

parameterranges(): array of real
{
	return array[] of {10000.0,1.57,300.0,500.0,20.0,20.0};
}

initialstate(nil: ref Model): array of real
{
	return array[] of {0.0,0.0,0.0,0.0};
}

maxtime(nil: ref Model): real
{
	return 80.0;
}

Model.rhs(model: self ref Model, t: real, state, derivative: array of real)
{
	p := model.parameter;
	acceleration := propulsion->thrustacceleration(p[0],p[2],p[3],p[4],t);
	(ax, ay) := atmosphere->drag2(state[2],state[3],state[1],1.0,0.02,
		propulsion->mass(p[2],p[3],p[4],t),1.0,8.0);
	derivative[0] = state[2];
	derivative[1] = state[3];
	derivative[2] = acceleration*math->cos(p[1])+ax;
	derivative[3] = acceleration*math->sin(p[1])+ay-p[5];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

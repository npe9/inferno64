implement Trajectory;

include "math.m";
	math: Math;
include "danby/atmosphere.m";
	atmosphere: Atmosphere;
include "danby/trajectory.m";

new(): ref Model
{
	math = load Math Math->PATH;
	atmosphere = load Atmosphere Atmosphere->PATH;
	return ref Model(array[] of {120.0,0.015,74.0,77000.0,28.0,9.81});
}

title(): string
{
	return "The descent of Skylab";
}

parameterlabels(): array of string
{
	return array[] of {"altitude", "density", "area", "mass", "scale height", "gravity"};
}

parameterranges(): array of real
{
	return array[] of {250.0,0.08,150.0,150000.0,60.0,20.0};
}

initialstate(model: ref Model): array of real
{
	return array[] of {0.0,model.parameter[0],7.6,0.0};
}

maxtime(nil: ref Model): real
{
	return 80.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	(ax, ay) := atmosphere->drag2(state[2],state[3],state[1],2.2,p[2],p[3],
		p[1],p[4]);
	derivative[0] = state[2];
	derivative[1] = state[3];
	derivative[2] = ax;
	derivative[3] = ay-p[5]*0.001;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

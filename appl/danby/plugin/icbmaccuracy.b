implement Flight3d;

include "math.m";
	math: Math;
include "danby/atmosphere.m";
	atmosphere: Atmosphere;
include "danby/flight3d.m";

new(): ref Model
{
	math = load Math Math->PATH;
	atmosphere = load Atmosphere Atmosphere->PATH;
	return ref Model(array[] of {2.2,0.78,0.0,0.002,0.003,9.81});
}

title(): string
{
	return "The accuracy of an ICBM";
}

parameterlabels(): array of string
{
	return array[] of {"speed", "elevation", "aim error", "drag", "crosswind", "gravity"};
}

parameterminima(): array of real
{
	return array[] of {0.2,0.1,-0.12,0.0,-0.02,0.0};
}

parameterranges(): array of real
{
	return array[] of {8.0,1.5,0.12,0.02,0.02,20.0};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	horizontal := p[0]*math->cos(p[1]);
	return array[] of {0.0,0.0,0.0,horizontal*math->cos(p[2]),
		horizontal*math->sin(p[2]),p[0]*math->sin(p[1])};
}

maxtime(nil: ref Model): real
{
	return 2000.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	(ax, az) := atmosphere->drag2(state[3],state[5],state[2],1.0,p[3],1.0,1.0,8.0);
	derivative[0] = state[3];
	derivative[1] = state[4];
	derivative[2] = state[5];
	derivative[3] = ax;
	derivative[4] = p[4]-0.01*state[4];
	derivative[5] = az-p[5]*0.001;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

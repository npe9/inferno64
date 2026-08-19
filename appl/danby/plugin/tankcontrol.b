implement Populationmodel;

include "math.m";
	math: Math;
include "danby/populationmodel.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {1.0,1.0,0.7,0.8,2.0,1.5,0.35},
		array[] of {0.65,0.4,0.7,0.3});
}

title(): string
{
	return "Temperature and volume control in a tank";
}

statelabels(): array of string
{
	return array[] of {"liquid level", "temperature", "outlet valve", "heater"};
}

parameterlabels(): array of string
{
	return array[] of {"level target", "temperature target", "inflow", "feed temperature", "level gain", "temperature gain", "heat loss"};
}

parameterranges(): array of real
{
	return array[] of {3.0,3.0,3.0,3.0,8.0,8.0,4.0};
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	level := state[0];
	if(level < 0.001)
		level = 0.001;
	valvetarget := p[2]+p[4]*(level-p[0]);
	if(valvetarget < 0.0)
		valvetarget = 0.0;
	heatertarget := p[5]*(p[1]-state[1]);
	if(heatertarget < 0.0)
		heatertarget = 0.0;
	outflow := state[2]*math->sqrt(level);
	derivative[0] = p[2]-outflow;
	derivative[1] = (p[2]*(p[3]-state[1])+state[3])/level-
		p[6]*(state[1]-0.25);
	derivative[2] = 2.0*(valvetarget-state[2]);
	derivative[3] = 2.0*(heatertarget-state[3]);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

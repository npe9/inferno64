implement Mechanism;

include "math.m";
	math: Math;
include "danby/propulsion.m";
	propulsion: Propulsion;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	propulsion = load Propulsion Propulsion->PATH;
	return ref Model(array[] of {4200.0,180.0,140.0,7.0,2200.0,9.81});
}

title(): string
{
	return "The motion of a rocket: multi-stage rockets";
}

parameterlabels(): array of string
{
	return array[] of {"stage 1 thrust", "stage 1 fuel", "stage 2 fuel", "flow", "stage 2 thrust", "gravity"};
}

parameterminima(): array of real
{
	return array[] of {100.0,10.0,10.0,0.5,100.0,0.0};
}

parametermaxima(): array of real
{
	return array[] of {10000.0,500.0,400.0,25.0,8000.0,20.0};
}

initialstate(nil: ref Model): array of real
{
	return array[] of {0.0,0.0};
}

maxtime(nil: ref Model): real
{
	return 60.0;
}

Model.rhs(model: self ref Model, t: real, state, derivative: array of real)
{
	p := model.parameter;
	firstburn := p[1]/p[3];
	acceleration := 0.0;
	if(t < firstburn)
		acceleration = p[0]/(60.0+p[1]+p[2]-p[3]*t);
	else if(t < firstburn+p[2]/p[3])
		acceleration = p[4]/(25.0+p[2]-p[3]*(t-firstburn));
	derivative[0] = state[1];
	derivative[1] = acceleration-p[5]-0.008*state[1]*math->fabs(state[1]);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(nil: ref Model, state: array of real): array of real
{
	return array[] of {0.0,state[0],0.0,state[0]+1.4,-0.4,state[0],0.4,state[0]};
}

links(): array of int
{
	return array[] of {0,1,0,2,0,3};
}

observablelabels(): array of string
{
	return array[] of {"altitude", "speed"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[1]};
}

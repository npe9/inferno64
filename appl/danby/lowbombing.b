implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {3.0,1.4,9.81,0.08,0.0});
}

title(): string
{
	return "Low-level bombing";
}

parameterlabels(): array of string
{
	return array[] of {"aircraft speed", "release height", "gravity", "drag", "release delay"};
}

parameterminima(): array of real
{
	return array[] of {0.2,0.2,0.1,0.0,0.0};
}

parametermaxima(): array of real
{
	return array[] of {10.0,5.0,20.0,2.0,3.0};
}

initialstate(model: ref Model): array of real
{
	return array[] of {-3.0,model.parameter[1],-3.0,model.parameter[1],
		model.parameter[0],0.0,0.0};
}

maxtime(nil: ref Model): real
{
	return 8.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	derivative[0] = p[0];
	derivative[1] = 0.0;
	if(state[6] < p[4]){
		derivative[2] = p[0];
		derivative[3] = 0.0;
		derivative[4] = 0.0;
		derivative[5] = 0.0;
	}else{
		speed := math->sqrt(state[4]*state[4]+state[5]*state[5]);
		derivative[2] = state[4];
		derivative[3] = state[5];
		derivative[4] = -p[3]*speed*state[4];
		derivative[5] = -p[2]-p[3]*speed*state[5];
	}
	derivative[6] = 1.0;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[1],state[2],state[3],-4.0,0.0,6.0,0.0,
		2.0,0.0,2.0,0.35};
}

links(): array of int
{
	return array[] of {2,3,4,5};
}

observablelabels(): array of string
{
	return array[] of {"bomb range", "bomb height"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[2],state[3]};
}

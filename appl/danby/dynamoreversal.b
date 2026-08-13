implement Mechanism;

include "danby/mechanism.m";

new(): ref Model
{
	return ref Model(array[] of {1.0,1.8,1.0,0.1});
}

title(): string
{
	return "A dynamo with magnetic reversal";
}

parameterlabels(): array of string
{
	return array[] of {"electrical loss", "rotation asymmetry", "mechanical drive", "initial imbalance"};
}

parameterminima(): array of real
{
	return array[] of {0.05,0.0,0.0,-2.0};
}

parametermaxima(): array of real
{
	return array[] of {5.0,6.0,6.0,2.0};
}

initialstate(model: ref Model): array of real
{
	return array[] of {1.0+model.parameter[3],0.8-model.parameter[3],1.0};
}

maxtime(nil: ref Model): real
{
	return 80.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	derivative[0] = -p[0]*state[0]+state[1]*state[2];
	derivative[1] = -p[0]*state[1]+(state[2]-p[1])*state[0];
	derivative[2] = p[2]-state[0]*state[1];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(nil: ref Model, state: array of real): array of real
{
	return array[] of {-1.0,-0.8,-1.0,0.8,1.0,-0.8,1.0,0.8,
		-1.0,state[0]/3.0,1.0,state[1]/3.0};
}

links(): array of int
{
	return array[] of {0,1,2,3,4,5};
}

observablelabels(): array of string
{
	return array[] of {"field 1", "field 2"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[1]};
}

implement Mechanism;

include "danby/mechanism.m";

new(): ref Model
{
	return ref Model(array[] of {1.0,1.0,0.35,2.0,0.12,1.4});
}

title(): string
{
	return "Two attracting current-carrying wires";
}

parameterlabels(): array of string
{
	return array[] of {"mass", "support spring", "current force", "rest spacing", "damping", "initial spacing"};
}

parameterminima(): array of real
{
	return array[] of {0.1,0.05,0.0,0.4,0.0,0.15};
}

parametermaxima(): array of real
{
	return array[] of {5.0,8.0,5.0,4.0,2.0,4.0};
}

initialstate(model: ref Model): array of real
{
	return array[] of {model.parameter[5],0.0};
}

maxtime(nil: ref Model): real
{
	return 25.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	spacing := state[0];
	if(spacing < 0.05)
		spacing = 0.05;
	derivative[0] = state[1];
	derivative[1] = (p[1]*(p[3]-spacing)-p[2]/spacing-p[4]*state[1])/p[0];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(nil: ref Model, state: array of real): array of real
{
	h := state[0]/2.0;
	return array[] of {-h,-1.2,-h,1.2,h,-1.2,h,1.2,-2.0,0.0,2.0,0.0};
}

links(): array of int
{
	return array[] of {0,1,2,3,4,5};
}

observablelabels(): array of string
{
	return array[] of {"wire spacing", "closing speed"};
}

observables(nil: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[1]};
}

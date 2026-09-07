implement Mechanism;

# danby/dynamoreversal - A dynamo with magnetic reversal
#
# The equations, the parameters and everything else model-specific are
# in this file.  The window, the integrator and the controls are the
# shared mechanism viewer's; init() at the foot of the file starts it and
# hands it this module back.

include "sys.m";
include "draw.m";
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

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	viewer := load Command "/dis/temple/mechanism.dis";
	if(viewer == nil)
		raise "fail:dynamoreversal: cannot load the mechanism viewer";
	viewer->init(ctxt, "dynamoreversal" :: "/dis/danby/dynamoreversal.dis" ::
		"danby-dynamoreversal" :: nil);
}

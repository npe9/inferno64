implement Mechanism;

# danby/pendulumperiod - The period of a simple pendulum
#
# The equations, the parameters and everything else model-specific are
# in this file.  The window, the integrator and the controls are the
# shared mechanism viewer's; init() at the foot of the file starts it and
# hands it this module back.

include "sys.m";
include "draw.m";
include "math.m";
	math: Math;
include "danby/pendulum.m";
	pendulum: Pendulum;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	pendulum = load Pendulum Pendulum->PATH;
	return ref Model(array[] of {1.0,0.25,0.0,9.81,1.0,0.0});
}

title(): string
{
	return "The period of a simple pendulum";
}

parameterlabels(): array of string
{
	return array[] of {"length", "amplitude", "initial speed", "gravity", "mass", "reference"};
}

parameterminima(): array of real
{
	return array[] of {0.1,0.01,-4.0,0.1,0.1,0.0};
}

parametermaxima(): array of real
{
	return array[] of {4.0,3.0,4.0,20.0,5.0,1.0};
}

initialstate(model: ref Model): array of real
{
	return array[] of {model.parameter[1],model.parameter[2]};
}

maxtime(nil: ref Model): real
{
	return 25.0;
}

Model.rhs(model: self ref Model, t: real, state, derivative: array of real)
{
	p := model.parameter;
	derivative[0] = state[1];
	derivative[1] = pendulum->acceleration(t,state[0],state[1],p[0],p[3],
		0.0,0.0,0.0,0.0,0.0,1.0);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	l := model.parameter[0];
	return array[] of {0.0,0.0,l*math->sin(state[0]),-l*math->cos(state[0]),
		-0.7,0.0,0.7,0.0};
}

links(): array of int
{
	return array[] of {0,1,2,3};
}

observablelabels(): array of string
{
	return array[] of {"angle", "small-angle period"};
}

observables(model: ref Model, state: array of real): array of real
{
	return array[] of {state[0],pendulum->periodsmall(model.parameter[0],model.parameter[3])};
}

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	viewer := load Command "/dis/temple/mechanism.dis";
	if(viewer == nil)
		raise "fail:pendulumperiod: cannot load the mechanism viewer";
	viewer->init(ctxt, "pendulumperiod" :: "/dis/danby/pendulumperiod.dis" ::
		"danby-pendulumperiod" :: nil);
}

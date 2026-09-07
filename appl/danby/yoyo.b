implement Mechanism;

# danby/yoyo - A model for the motion of a yo-yo
#
# The equations, the parameters and everything else model-specific are
# in this file.  The window, the integrator and the controls are the
# shared mechanism viewer's; init() at the foot of the file starts it and
# hands it this module back.

include "sys.m";
include "draw.m";
include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {1.2,0.04,0.12,0.08,0.02,9.81});
}

title(): string
{
	return "A model for the motion of a yo-yo";
}

parameterlabels(): array of string
{
	return array[] of {"string length", "axle radius", "mass", "inertia", "friction", "gravity"};
}

parameterminima(): array of real
{
	return array[] of {0.2,0.01,0.03,0.005,0.0,0.0};
}

parametermaxima(): array of real
{
	return array[] of {3.0,0.15,0.5,0.3,0.2,20.0};
}

initialstate(nil: ref Model): array of real
{
	return array[] of {0.0,0.0,0.0};
}

maxtime(nil: ref Model): real
{
	return 8.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	effectivemass := p[2]+p[3]/(p[1]*p[1]);
	acceleration := (p[2]*p[5]-p[4]*state[1])/effectivemass;
	if(state[0] >= p[0] && state[1] > 0.0)
		acceleration = -0.8*p[5];
	derivative[0] = state[1];
	derivative[1] = acceleration;
	derivative[2] = state[1]/p[1];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(nil: ref Model, state: array of real): array of real
{
	x := 0.25*math->sin(state[2]);
	y := -state[0];
	return array[] of {0.0,0.0,0.0,y,x,y,-x,y};
}

links(): array of int
{
	return array[] of {0,1,2,3};
}

observablelabels(): array of string
{
	return array[] of {"depth", "angular speed"};
}

observables(model: ref Model, state: array of real): array of real
{
	return array[] of {state[0],state[1]/model.parameter[1]};
}

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	viewer := load Command "/dis/temple/mechanism.dis";
	if(viewer == nil)
		raise "fail:yoyo: cannot load the mechanism viewer";
	viewer->init(ctxt, "yoyo" :: "/dis/danby/yoyo.dis" ::
		"danby-yoyo" :: nil);
}

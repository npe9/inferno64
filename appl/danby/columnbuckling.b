implement Mechanism;

# danby/columnbuckling - Dynamic buckling of a column
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
	return ref Model(array[] of {1.0,1.3,1.0,0.12,0.08});
}

title(): string
{
	return "Dynamic buckling of a column";
}

parameterlabels(): array of string
{
	return array[] of {"mass", "compressive load", "post-buckling", "damping", "initial offset"};
}

parameterminima(): array of real
{
	return array[] of {0.1,-2.0,0.05,0.0,-1.0};
}

parametermaxima(): array of real
{
	return array[] of {5.0,5.0,5.0,2.0,1.0};
}

initialstate(model: ref Model): array of real
{
	return array[] of {model.parameter[4],0.0};
}

maxtime(nil: ref Model): real
{
	return 30.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	derivative[0] = state[1];
	derivative[1] = (p[1]*state[0]-p[2]*state[0]*state[0]*state[0]-
		p[3]*state[1])/p[0];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(nil: ref Model, state: array of real): array of real
{
	x := state[0];
	return array[] of {0.0,-1.5,0.65*x,-0.5,x,0.5,0.0,1.5,-0.5,-1.5,0.5,-1.5};
}

links(): array of int
{
	return array[] of {0,1,1,2,2,3,4,5};
}

observablelabels(): array of string
{
	return array[] of {"lateral deflection", "velocity"};
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
		raise "fail:columnbuckling: cannot load the mechanism viewer";
	viewer->init(ctxt, "columnbuckling" :: "/dis/danby/columnbuckling.dis" ::
		"danby-columnbuckling" :: nil);
}

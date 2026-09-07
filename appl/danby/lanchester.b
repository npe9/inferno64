implement Populationmodel;

# danby/lanchester - Lanchester square-law combat
#
# The equations, the parameters and everything else model-specific are
# in this file.  The window, the integrator and the controls are the
# shared populations viewer's; init() at the foot of the file starts it and
# hands it this module back.

include "sys.m";
include "draw.m";
include "danby/populationmodel.m";

new(): ref Model
{
	return ref Model(array[] of {0.35,0.5},array[] of {1.0,0.8});
}

title(): string
{
	return "Lanchester square-law combat";
}

statelabels(): array of string
{
	return array[] of {"force A", "force B"};
}

parameterlabels(): array of string
{
	return array[] of {"B effectiveness", "A effectiveness"};
}

parameterranges(): array of real
{
	return array[] of {2.0,2.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	derivative[0] = -p[0]*state[1];
	derivative[1] = -p[1]*state[0];
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	viewer := load Command "/dis/temple/populations.dis";
	if(viewer == nil)
		raise "fail:lanchester: cannot load the populations viewer";
	viewer->init(ctxt, "lanchester" :: "/dis/danby/lanchester.dis" ::
		"danby-lanchester" :: nil);
}

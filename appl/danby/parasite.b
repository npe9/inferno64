implement Populationmodel;

# danby/parasite - Population growth of a parasite
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
	parameters := array[] of {1.1, 1.5, 1.4, 0.75, 0.45};
	initial := array[] of {0.8, 0.12};
	return ref Model(parameters,initial);
}

title(): string
{
	return "Population growth of a parasite";
}

statelabels(): array of string
{
	return array[] of {"hosts", "parasites"};
}

parameterlabels(): array of string
{
	return array[] of {
		"host growth", "host capacity", "infection",
		"conversion", "parasite death"
	};
}

parameterranges(): array of real
{
	return array[] of {3.0, 3.0, 3.0, 2.0, 2.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	hosts := state[0];
	parasites := state[1];
	infections := p[2]*hosts*parasites;
	derivative[0] = p[0]*hosts*(1.0-hosts/p[1])-infections;
	derivative[1] = p[3]*infections-p[4]*parasites;
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
		raise "fail:parasite: cannot load the populations viewer";
	viewer->init(ctxt, "parasite" :: "/dis/danby/parasite.dis" ::
		"danby-parasite" :: nil);
}

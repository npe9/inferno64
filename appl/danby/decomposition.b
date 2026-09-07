implement Populationmodel;

# danby/decomposition - Decomposition of a molecule
#
# The equations, the parameters and everything else model-specific are
# in this file.  The window, the integrator and the controls are the
# shared populations viewer's; init() at the foot of the file starts it and
# hands it this module back.

include "sys.m";
include "draw.m";
include "danby/reaction.m";
	reaction: Reaction;
include "danby/populationmodel.m";

new(): ref Model
{
	reaction = load Reaction Reaction->PATH;
	return ref Model(array[] of {0.35,0.08},array[] of {1.0,0.0,0.0});
}

title(): string
{
	return "Decomposition of a molecule";
}

statelabels(): array of string
{
	return array[] of {"parent", "intermediate", "product"};
}

parameterlabels(): array of string
{
	return array[] of {"first reaction", "second reaction"};
}

parameterranges(): array of real
{
	return array[] of {2.0,2.0};
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	reaction->clear(derivative);
	f1 := reaction->flux(state,array[] of {1.0,0.0,0.0},model.parameter[0]);
	f2 := reaction->flux(state,array[] of {0.0,1.0,0.0},model.parameter[1]);
	reaction->apply(derivative,array[] of {-1.0,1.0,0.0},f1);
	reaction->apply(derivative,array[] of {0.0,-1.0,1.0},f2);
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
		raise "fail:decomposition: cannot load the populations viewer";
	viewer->init(ctxt, "decomposition" :: "/dis/danby/decomposition.dis" ::
		"danby-decomposition" :: nil);
}

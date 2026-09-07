implement Populationmodel;

# danby/moreenzyme - Reversible enzyme kinetics
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
	return ref Model(array[] of {2.0,0.5,0.8,0.35},array[] of {1.4,0.4,0.0,0.0});
}

title(): string
{
	return "Reversible enzyme kinetics";
}

statelabels(): array of string
{
	return array[] of {"substrate", "enzyme", "complex", "product"};
}

parameterlabels(): array of string
{
	return array[] of {"binding", "unbinding", "forward catalysis", "reverse catalysis"};
}

parameterranges(): array of real
{
	return array[] of {8.0,4.0,4.0,4.0};
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	reaction->clear(derivative);
	bind := reaction->flux(state,array[] of {1.0,1.0,0.0,0.0},model.parameter[0]);
	unbind := reaction->flux(state,array[] of {0.0,0.0,1.0,0.0},model.parameter[1]);
	forward := reaction->flux(state,array[] of {0.0,0.0,1.0,0.0},model.parameter[2]);
	reverse := reaction->flux(state,array[] of {0.0,1.0,0.0,1.0},model.parameter[3]);
	reaction->apply(derivative,array[] of {-1.0,-1.0,1.0,0.0},bind);
	reaction->apply(derivative,array[] of {1.0,1.0,-1.0,0.0},unbind);
	reaction->apply(derivative,array[] of {0.0,1.0,-1.0,1.0},forward);
	reaction->apply(derivative,array[] of {0.0,-1.0,1.0,-1.0},reverse);
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
		raise "fail:moreenzyme: cannot load the populations viewer";
	viewer->init(ctxt, "moreenzyme" :: "/dis/danby/moreenzyme.dis" ::
		"danby-moreenzyme" :: nil);
}

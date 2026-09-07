implement Populationmodel;

# danby/enzymekinetics - Enzyme kinetics
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
	return ref Model(array[] of {2.0,0.6,0.8},array[] of {1.5,0.4,0.0,0.0});
}

title(): string
{
	return "Enzyme kinetics";
}

statelabels(): array of string
{
	return array[] of {"substrate", "enzyme", "complex", "product"};
}

parameterlabels(): array of string
{
	return array[] of {"binding", "unbinding", "catalysis"};
}

parameterranges(): array of real
{
	return array[] of {8.0,4.0,4.0};
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	reaction->clear(derivative);
	bind := reaction->flux(state,array[] of {1.0,1.0,0.0,0.0},model.parameter[0]);
	unbind := reaction->flux(state,array[] of {0.0,0.0,1.0,0.0},model.parameter[1]);
	catalyse := reaction->flux(state,array[] of {0.0,0.0,1.0,0.0},model.parameter[2]);
	reaction->apply(derivative,array[] of {-1.0,-1.0,1.0,0.0},bind);
	reaction->apply(derivative,array[] of {1.0,1.0,-1.0,0.0},unbind);
	reaction->apply(derivative,array[] of {0.0,1.0,-1.0,1.0},catalyse);
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
		raise "fail:enzymekinetics: cannot load the populations viewer";
	viewer->init(ctxt, "enzymekinetics" :: "/dis/danby/enzymekinetics.dis" ::
		"danby-enzymekinetics" :: nil);
}

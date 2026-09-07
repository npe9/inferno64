implement Populationmodel;

# danby/violetsantsrodents - Violets, ants, and rodents
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
	parameters := array[] of {0.8, 1.5, 0.35, 0.5, 0.8, 0.3, 1.2, 0.35};
	initial := array[] of {0.7, 0.3, 0.18};
	return ref Model(parameters,initial);
}

title(): string
{
	return "Violets, ants, and rodents";
}

statelabels(): array of string
{
	return array[] of {"violets", "ants", "rodents"};
}

parameterlabels(): array of string
{
	return array[] of {
		"violet growth", "capacity", "ant benefit", "rodent grazing",
		"ant conversion", "ant death", "ant deterrence", "rodent death"
	};
}

parameterranges(): array of real
{
	return array[] of {2.0, 3.0, 1.5, 2.0, 2.0, 1.5, 3.0, 1.5};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	violets := state[0];
	ants := state[1];
	rodents := state[2];
	seedservice := ants*violets/(1.0+violets);
	rodentfood := violets*rodents/(1.0+p[6]*ants);
	derivative[0] = p[0]*violets*(1.0-violets/p[1])
		+p[2]*seedservice-p[3]*rodentfood;
	derivative[1] = p[4]*seedservice-p[5]*ants;
	derivative[2] = rodentfood-p[7]*rodents;
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
		raise "fail:violetsantsrodents: cannot load the populations viewer";
	viewer->init(ctxt, "violetsantsrodents" :: "/dis/danby/violetsantsrodents.dis" ::
		"danby-violetsantsrodents" :: nil);
}

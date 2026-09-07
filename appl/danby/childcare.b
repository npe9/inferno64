implement Populationmodel;

# danby/childcare - Predator-prey with child care
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
	parameters := array[] of {1.4, 1.8, 0.9, 0.7, 0.5, 0.35, 0.45};
	initial := array[] of {0.8, 0.12, 0.15};
	return ref Model(parameters,initial);
}

title(): string
{
	return "Predator-prey with child care";
}

statelabels(): array of string
{
	return array[] of {"prey", "young", "adults"};
}

parameterlabels(): array of string
{
	return array[] of {
		"prey birth", "attack", "conversion", "maturation",
		"young death", "adult death", "care"
	};
}

parameterranges(): array of real
{
	return array[] of {3.0, 4.0, 2.0, 2.0, 2.0, 2.0, 1.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	prey := state[0];
	young := state[1];
	adults := state[2];
	care := p[6];
	effectiveattack := p[1]*(1.0-0.6*care);
	effectiveyoungdeath := p[4]*(1.0-0.8*care);
	kills := effectiveattack*prey*adults;
	derivative[0] = p[0]*prey-kills;
	derivative[1] = p[2]*kills-p[3]*young-effectiveyoungdeath*young;
	derivative[2] = p[3]*young-p[5]*adults;
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
		raise "fail:childcare: cannot load the populations viewer";
	viewer->init(ctxt, "childcare" :: "/dis/danby/childcare.dis" ::
		"danby-childcare" :: nil);
}

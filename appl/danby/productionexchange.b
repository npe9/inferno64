implement Populationmodel;

# danby/productionexchange - Production and exchange of two goods
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
	return ref Model(array[] of {0.8,0.5,0.55,0.7,0.45},
		array[] of {0.7,0.35});
}

title(): string
{
	return "Production and exchange of two goods";
}

statelabels(): array of string
{
	return array[] of {"good A inventory", "good B inventory"};
}

parameterlabels(): array of string
{
	return array[] of {"production A", "use A", "production B", "use B", "exchange"};
}

parameterranges(): array of real
{
	return array[] of {2.0,2.0,2.0,2.0,2.0};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	flow := p[4]*(state[0]-state[1]);
	derivative[0] = p[0]-p[1]*state[0]-flow;
	derivative[1] = p[2]-p[3]*state[1]+flow;
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
		raise "fail:productionexchange: cannot load the populations viewer";
	viewer->init(ctxt, "productionexchange" :: "/dis/danby/productionexchange.dis" ::
		"danby-productionexchange" :: nil);
}

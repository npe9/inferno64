implement Twospecies;

# danby/predatorfishing - Predator-prey model with fishing
#
# The equations, the parameters and everything else model-specific are
# in this file.  The window, the integrator and the controls are the
# shared ecology viewer's; init() at the foot of the file starts it and
# hands it this module back.

include "sys.m";
include "draw.m";
include "danby/twospecies.m";

new(): ref Model
{
	return ref Model(array[] of {1.5, 2.0, 1.0, 0.75, 0.2});
}

title(): string
{
	return "Predator-prey model with fishing";
}

parameterlabels(): array of string
{
	return array[] of {
		"prey birth", "predation", "conversion",
		"predator death", "fishing effort"
	};
}

parameterranges(): array of real
{
	return array[] of {3.0, 4.0, 3.0, 3.0, 1.4};
}

Model.rhs(model: self ref Model, nil: real,
		state, derivative: array of real)
{
	p := model.parameter;
	effort := p[4];
	derivative[0] = state[0]*(p[0]-effort-p[1]*state[1]);
	derivative[1] = state[1]*(p[2]*state[0]-p[3]-effort);
}

Model.equilibrium(model: self ref Model): (real, real)
{
	p := model.parameter;
	return ((p[3]+p[4])/p[2],(p[0]-p[4])/p[1]);
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

fixedpoint(model: ref Model): (real, real)
{
	return model.equilibrium();
}

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	viewer := load Command "/dis/danby/ecology.dis";
	if(viewer == nil)
		raise "fail:predatorfishing: cannot load the ecology viewer";
	viewer->init(ctxt, "predatorfishing" :: "/dis/danby/predatorfishing.dis" ::
		"danby-predatorfishing" :: nil);
}

implement Trajectory;

# danby/flyball - Flight of a fly ball
#
# The equations, the parameters and everything else model-specific are
# in this file.  The window, the integrator and the controls are the
# shared trajectory viewer's; init() at the foot of the file starts it and
# hands it this module back.

include "sys.m";
include "draw.m";
include "math.m";
	math: Math;
include "danby/ballistics.m";
	ballistics: Ballistics;
include "danby/trajectory.m";

new(): ref Model
{
	math = load Math Math->PATH;
	ballistics = load Ballistics Ballistics->PATH;
	return ref Model(array[] of {45.0,0.8,0.005,0.00045,130.0,9.81});
}

title(): string
{
	return "Flight of a fly ball";
}

parameterlabels(): array of string
{
	return array[] of {"exit speed", "angle", "drag", "lift", "backspin", "gravity"};
}

parameterranges(): array of real
{
	return array[] of {70.0,1.4,0.02,0.003,350.0,20.0};
}

initialstate(model: ref Model): array of real
{
	p := model.parameter;
	return array[] of {0.0,1.0,p[0]*math->cos(p[1]),p[0]*math->sin(p[1])};
}

maxtime(nil: ref Model): real
{
	return 12.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	derivative[0] = state[2];
	derivative[1] = state[3];
	(derivative[2],derivative[3]) = ballistics->acceleration(
		state[2],state[3],p[2],p[3],p[4],p[5],0.0);
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
	viewer := load Command "/dis/temple/trajectory.dis";
	if(viewer == nil)
		raise "fail:flyball: cannot load the trajectory viewer";
	viewer->init(ctxt, "flyball" :: "/dis/danby/flyball.dis" ::
		"danby-flyball" :: nil);
}
